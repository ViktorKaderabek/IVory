#!/bin/bash
# =====================================================================
#  IVory – launcher
#  Checks Xcode, downloads and sets up everything else on the first run
#  (Node.js, Appium + XCUITest driver, Python with libraries), starts the
#  Appium server and the bot. Used by both the app and Terminal.
#
#    bash scripts/run.sh                                   # duplicates + IV tags
#    bash scripts/run.sh --steps duplicates,iv,pvp,rename,battle,weak  # any steps
#    bash scripts/run.sh --fresh                           # don't use IVs from memory
#
#  Whatever the system lacks is downloaded into ~/.pogo/runtime (no Homebrew, no password).
#  Node.js / Appium installed from Homebrew are used when they are already there.
# =====================================================================
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONWARNINGS=ignore
export PYTHONUNBUFFERED=1
export npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../core" && pwd)"
WORK="$HOME/.pogo"
RT="$WORK/runtime"
VENV="$WORK/venv"
PORT=4723
mkdir -p "$WORK"

# Versions downloaded on the first run (the same as in scripts/build_runtime.sh)
NODE_VERSION=24.21.0
PY_RELEASE=20261001
PY_VERSION=3.12.15
APPIUM_VERSION=3.8.0
XCUITEST_VERSION=12.13.3
case "$(uname -m)" in
  arm64)
    NODE_PKG="node-v$NODE_VERSION-darwin-arm64"
    NODE_SHA=bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057
    PY_PKG="cpython-$PY_VERSION+$PY_RELEASE-aarch64-apple-darwin-install_only_stripped"
    PY_SHA=10cab8f6ed6202fdd81637aa6eda4af8d5b7eaa8fc42f9df3c6bea4923de0d93 ;;
  *)
    NODE_PKG="node-v$NODE_VERSION-darwin-x64"
    NODE_SHA=1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097
    PY_PKG="cpython-$PY_VERSION+$PY_RELEASE-x86_64-apple-darwin-install_only_stripped"
    PY_SHA=d101ac54bc34afff54741406261325dc896b7b646a36a58fff4845ef0a00b2ce ;;
esac

# Message language from the app settings (config.json "language");
# without that setting, the system language, just like the app
UI_LANG=en
if grep -Eq '"language"[[:space:]]*:' "$WORK/config.json" 2>/dev/null; then
  grep -Eq '"language"[[:space:]]*:[[:space:]]*"cs"' "$WORK/config.json" && UI_LANG=cs
else
  defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q '"*cs' && UI_LANG=cs
fi
t() { if [ "$UI_LANG" = cs ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
say() { printf '\n▶ %s\n' "$*"; }
die() { printf '\n✖ %s\n' "$*"; exit 1; }

fetch() {  # fetch URL FILE SHA256 – downloads into ~/.pogo/runtime/downloads and verifies the checksum
  local url="$1" file="$RT/downloads/$2" sha="$3"
  mkdir -p "$RT/downloads"
  if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then return 0; fi
  curl -fL --retry 3 -sS -o "$file.part" "$url" || die "$(t "Stažení $2 selhalo. Zkontroluj připojení k internetu." "Downloading $2 failed. Check your internet connection.")"
  if [ "$(shasum -a 256 "$file.part" | cut -d' ' -f1)" != "$sha" ]; then
    rm -f "$file.part"
    die "$(t "Kontrolní součet $2 nesedí." "Checksum of $2 doesn't match.")"
  fi
  mv "$file.part" "$file"
}

unpack() {  # unpack ARCHIVE TARGET DIR_IN_ARCHIVE – extracts into ~/.pogo/runtime/TARGET
  local tmp="$RT/$2.tmp"
  rm -rf "$tmp" "$RT/$2" && mkdir -p "$tmp"
  tar -xzf "$RT/downloads/$1" -C "$tmp" || die "$(t "Rozbalení $1 selhalo." "Unpacking $1 failed.")"
  mv "$tmp/$3" "$RT/$2" && rm -rf "$tmp" "$RT/downloads/$1"
}

# --- 1) Xcode (the only thing that can't be downloaded) -------------------
if ! xcodebuild -version >/dev/null 2>&1; then
  # Xcode is installed but only the Command Line Tools are selected: use it without sudo
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    [ -d "$x/Contents/Developer" ] && export DEVELOPER_DIR="$x/Contents/Developer" && break
  done
fi
xcodebuild -version >/dev/null 2>&1 || die "$(t \
  "Chybí Xcode. Nainstaluj ho z App Store (https://apps.apple.com/app/xcode/id497799835), jednou ho otevři a pak spusť IVory znovu." \
  "Xcode is missing. Install it from the App Store (https://apps.apple.com/app/xcode/id497799835), open it once, then start IVory again.")"
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || die "$(t \
  "Xcode ještě není připravený: otevři ho jednou, nech doinstalovat součásti a pak spusť IVory znovu." \
  "Xcode isn't set up yet: open it once, let it install its components, then start IVory again.")"

# --- 1b) Consent to the risk notice (shared with the window in the app) ---
CONSENT_VERSION=1   # same number as Consent.version in app/Sources/PoGoInventoryManager/Consent.swift
CFG="$WORK/config.json"
HAVE="$(xcrun python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1])).get("consent_version") or 0))' "$CFG" 2>/dev/null || echo 0)"
if [ "$HAVE" -lt "$CONSENT_VERSION" ]; then
  [ -t 0 ] || die "$(t "Nejdřív otevři aplikaci IVory a potvrď upozornění na rizika." \
                       "Open the IVory app first and confirm the risk notice.")"
  if [ "$UI_LANG" = cs ]; then
    cat <<'TXT'

  ⚠  Než spustíš IVory

  IVory ovládá Pokémon GO za tebe. Hra to nepovoluje.
   • Můžeš přijít o účet: Niantic ho může dočasně nebo natrvalo zablokovat.
   • Porušuješ podmínky hry: automatizace je v podmínkách Pokémon GO zakázaná.
   • Bot nic nepřevádí, jen taguje a přejmenovává. I tak se může splést.

  Napsáním „souhlasím“ potvrzuješ, že:
   – rozumíš, že účet může být zablokován, i natrvalo,
   – aplikaci používáš na vlastní riziko a za svůj účet odpovídáš sám,
   – IVory nemá nic společného s Niantic ani The Pokémon Company.

TXT
    read -r -p "  Napiš „souhlasím“ (cokoliv jiného skript ukončí): " ANSWER
  else
    cat <<'TXT'

  ⚠  Before you start IVory

  IVory plays Pokémon GO for you. The game doesn't allow that.
   • You can lose your account: Niantic can suspend or permanently ban it.
   • You break the game's terms: automation is forbidden by the Pokémon GO Terms of Service.
   • The bot never transfers anything, it only tags and renames. It can still make mistakes.

  By typing "I agree" you confirm that:
   – you understand your account can be banned, even permanently,
   – you use the app at your own risk and you alone are responsible for your account,
   – IVory has nothing to do with Niantic or The Pokémon Company.

TXT
    read -r -p "  Type \"I agree\" (anything else quits): " ANSWER
  fi
  case "$ANSWER" in
    souhlasím|Souhlasím|SOUHLASÍM|souhlasim|Souhlasim|SOUHLASIM|"I agree"|"i agree"|"I AGREE") ;;
    *) die "$(t "Bez souhlasu IVory nespustím." "IVory won't start without your consent.")" ;;
  esac
  PLIST="$HERE/../../Info.plist"; [ -f "$PLIST" ] || PLIST="$HERE/../app/Info.plist"
  APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo dev)"
  xcrun python3 - "$CFG" "$CONSENT_VERSION" "$APP_VERSION" <<'PY' || die "$(t "Souhlas se nepodařilo uložit." "Couldn't save the consent.")"
import json, sys, datetime, os
path, version, app = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    cfg = json.load(open(path))
except (OSError, ValueError):
    cfg = {}
cfg.update(consent_version=version, app_version=app,
           consent_at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    json.dump(cfg, f, indent=2, sort_keys=True, ensure_ascii=False)
os.replace(path + ".tmp", path)
PY
  say "$(t "Souhlas uložen." "Consent saved.")"
fi

# --- 2) Node.js and Appium -----------------------------------------------
[ -x "$RT/node/bin/node" ] && export PATH="$RT/node/bin:$PATH"
own_node() {
  if [ ! -x "$RT/node/bin/node" ]; then
    say "$(t "Stahuji Node.js $NODE_VERSION (jen poprvé)..." "Downloading Node.js $NODE_VERSION (first run only)...")"
    fetch "https://nodejs.org/dist/v$NODE_VERSION/$NODE_PKG.tar.gz" "$NODE_PKG.tar.gz" "$NODE_SHA"
    unpack "$NODE_PKG.tar.gz" node "$NODE_PKG"
  fi
  export PATH="$RT/node/bin:$PATH"
}
if ! command -v appium >/dev/null 2>&1; then
  # Appium 3 needs Node 20+ and a global install into a folder it may write to
  if ! command -v npm >/dev/null 2>&1 \
     || ! node -e 'process.exit(+process.versions.node.split(".")[0] >= 20 ? 0 : 1)' 2>/dev/null \
     || [ ! -w "$(npm prefix -g 2>/dev/null)/lib" ]; then
    own_node
  fi
  say "$(t "Instaluji Appium $APPIUM_VERSION (jen poprvé)..." "Installing Appium $APPIUM_VERSION (first run only)...")"
  npm install -g --loglevel=error "appium@$APPIUM_VERSION" || die "$(t "Instalace Appium selhala." "Installing Appium failed.")"
fi
if ! appium driver list --installed 2>&1 | grep -qi xcuitest; then
  say "$(t "Instaluji XCUITest driver (jen poprvé)..." "Installing the XCUITest driver (first run only)...")"
  appium driver install --source=npm "appium-xcuitest-driver@$XCUITEST_VERSION" \
    || die "$(t "Instalace XCUITest driveru selhala." "Installing the XCUITest driver failed.")"
fi

# --- 3) Python environment -----------------------------------------------
if [ ! -x "$VENV/bin/python" ]; then
  if [ ! -x "$RT/python/bin/python3" ]; then
    say "$(t "Stahuji Python $PY_VERSION (jen poprvé)..." "Downloading Python $PY_VERSION (first run only)...")"
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/${PY_PKG/+/%2B}.tar.gz" \
      "$PY_PKG.tar.gz" "$PY_SHA"
    unpack "$PY_PKG.tar.gz" python python
  fi
  say "$(t "Vytvářím Python prostředí (jen poprvé)..." "Creating the Python environment (first run only)...")"
  "$RT/python/bin/python3" -m venv "$VENV" || die "$(t "Nepodařilo se vytvořit Python prostředí." "Couldn't create the Python environment.")"
fi
if ! "$VENV/bin/python" -c "import appium, cv2, numpy, PIL, Vision, Foundation" >/dev/null 2>&1; then
  say "$(t "Instaluji Python knihovny (jen poprvé, pár minut)..." "Installing Python libraries (first run only, a few minutes)...")"
  "$VENV/bin/python" -m pip install -q --disable-pip-version-check --upgrade pip
  "$VENV/bin/python" -m pip install -q --disable-pip-version-check --prefer-binary -r "$CORE/requirements.txt" \
    || die "$(t "Instalace Python knihoven selhala." "Installing the Python libraries failed.")"
fi

# --- 3b) Game data (PvPoke + PokeMiners) ----------------------------------
# Not part of IVory: downloaded into ~/.pogo/pokedata.json and refreshed once a week (new Pokémon),
# or right away when a copy from an older IVory lacks the Battle data. An old copy is enough when the refresh fails.
DATA="$WORK/pokedata.json"
if [ ! -f "$DATA" ] || [ -n "$(find "$DATA" -mtime +6)" ] || ! grep -q '"battle"' "$DATA"; then
  say "$(t "Stahuji herní data (PvPoke, PokeMiners)..." "Downloading the game data (PvPoke, PokeMiners)...")"
  if ! "$VENV/bin/python" "$CORE/pokedata.py"; then
    [ -f "$DATA" ] || die "$(t "Herní data se nepodařilo stáhnout. Zkontroluj připojení k internetu." \
                               "Couldn't download the game data. Check your internet connection.")"
    say "$(t "Herní data se nepodařilo obnovit, použiji uložená." "Couldn't refresh the game data, using the saved copy.")"
  fi
fi

# --- 4) Appium server ----------------------------------------------------
APPIUM_PID=""
cleanup() { [ -n "$APPIUM_PID" ] && kill "$APPIUM_PID" 2>/dev/null; }
trap cleanup EXIT
if curl -s "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
  say "$(t "Appium už běží, použiji ho." "Appium is already running, using it.")"
else
  say "$(t "Spouštím Appium server..." "Starting the Appium server...")"
  appium --port "$PORT" > "$WORK/appium.log" 2>&1 &
  APPIUM_PID=$!
  for i in $(seq 1 40); do
    curl -s "http://127.0.0.1:$PORT/status" >/dev/null 2>&1 && break
    sleep 1
    if [ "$i" = 40 ]; then die "$(t "Appium se nespustil. Log: $WORK/appium.log" "Appium didn't start. Log: $WORK/appium.log")"; fi
  done
fi

# --- 5) Bot --------------------------------------------------------------
say "$(t "Spouštím IVory (Stop / Ctrl+C běh ukončí a uloží výsledky)." "Starting IVory (Stop / Ctrl+C ends the run and saves the results).")"
"$VENV/bin/python" "$CORE/pogo_bot.py" "$@" &
PY_PID=$!
trap 'kill -INT "$PY_PID" 2>/dev/null' INT TERM
wait "$PY_PID"; RC=$?
# after Stop, wait returns early: keep waiting until the bot has saved the results
while kill -0 "$PY_PID" 2>/dev/null; do wait "$PY_PID"; RC=$?; done
exit $RC
