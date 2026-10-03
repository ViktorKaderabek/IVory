#!/bin/bash
# =====================================================================
#  IVory – spouštěč
#  Zkontroluje Xcode, při prvním spuštění stáhne a připraví vše ostatní
#  (Node.js, Appium + XCUITest driver, Python s knihovnami), spustí Appium
#  server a bota. Používá ho aplikace i Terminál.
#
#    bash scripts/run.sh                                   # duplicity + IV tagy
#    bash scripts/run.sh --steps duplicates,iv,pvp,rename  # libovolné kroky
#    bash scripts/run.sh --fresh                           # IV z paměti nepoužívat
#
#  Co v systému chybí, stáhne do ~/.pogo/runtime (bez Homebrew, bez hesla).
#  Nainstalovaný Node.js / Appium z Homebrew použije, když už je.
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

# Verze stahované při prvním spuštění (stejné jako ve scripts/build_runtime.sh)
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

# Jazyk hlášek podle nastavení aplikace (config.json „language“)
UI_LANG=en
grep -Eq '"language"[[:space:]]*:[[:space:]]*"cs"' "$WORK/config.json" 2>/dev/null && UI_LANG=cs
t() { if [ "$UI_LANG" = cs ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
say() { printf '\n▶ %s\n' "$*"; }
die() { printf '\n✖ %s\n' "$*"; exit 1; }

fetch() {  # fetch URL SOUBOR SHA256 – stáhne do ~/.pogo/runtime/downloads a ověří otisk
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

unpack() {  # unpack ARCHIV CÍL SLOŽKA_V_ARCHIVU – rozbalí do ~/.pogo/runtime/CÍL
  local tmp="$RT/$2.tmp"
  rm -rf "$tmp" "$RT/$2" && mkdir -p "$tmp"
  tar -xzf "$RT/downloads/$1" -C "$tmp" || die "$(t "Rozbalení $1 selhalo." "Unpacking $1 failed.")"
  mv "$tmp/$3" "$RT/$2" && rm -rf "$tmp" "$RT/downloads/$1"
}

# --- 1) Xcode (jediné, co stáhnout nejde) --------------------------------
if ! xcodebuild -version >/dev/null 2>&1; then
  # Xcode je nainstalovaný, ale vybrané jsou jen Command Line Tools – použít ho bez sudo
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

# --- 2) Node.js a Appium -------------------------------------------------
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
  # Appium 3 chce Node 20+ a globální instalaci do složky, kam smí zapisovat
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

# --- 3) Python prostředí ---------------------------------------------
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

# --- 4) Appium server --------------------------------------------------
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

# --- 5) bot --------------------------------------------------------------
say "$(t "Spouštím IVory (Stop / Ctrl+C běh ukončí a uloží výsledky)." "Starting IVory (Stop / Ctrl+C ends the run and saves the results).")"
"$VENV/bin/python" "$CORE/pogo_bot.py" "$@" &
PY_PID=$!
trap 'kill -INT "$PY_PID" 2>/dev/null' INT TERM
wait "$PY_PID"; RC=$?
# po Stop se wait vrátí dřív – počkat, až bot uloží výsledky
while kill -0 "$PY_PID" 2>/dev/null; do wait "$PY_PID"; RC=$?; done
exit $RC
