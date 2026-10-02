#!/bin/bash
# =====================================================================
#  PoGo Inventory Manager – spouštěč
#  Zkontroluje nástroje, připraví Python prostředí (jen poprvé), spustí
#  Appium server a bota. Používá ho aplikace i Terminál.
#
#    bash scripts/run.sh                 # obě části (duplicity + IV tagy)
#    bash scripts/run.sh --no-iv         # jen duplicity
#    bash scripts/run.sh --only-iv       # jen celý box do IV tagů
#    bash scripts/run.sh --fresh         # IV z paměti nepoužívat
# =====================================================================
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PYTHONWARNINGS=ignore
export PYTHONUNBUFFERED=1

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../core" && pwd)"
WORK="$HOME/.pogo"
VENV="$WORK/venv"
PORT=4723
mkdir -p "$WORK"

say() { printf '\n▶ %s\n' "$*"; }
die() { printf '\n✖ %s\n' "$*"; exit 1; }

# --- 1) nástroje ------------------------------------------------------
command -v xcodebuild >/dev/null 2>&1 || die "Chybí Xcode (App Store)."
command -v npm >/dev/null 2>&1 || die "Chybí Node.js. V Terminálu spusť: brew install node"
if ! command -v appium >/dev/null 2>&1; then
  say "Instaluji Appium (jen poprvé)..."
  npm install -g appium || die "Instalace Appium selhala."
fi
if ! appium driver list --installed 2>&1 | grep -qi xcuitest; then
  say "Instaluji XCUITest driver (jen poprvé)..."
  appium driver install xcuitest || die "Instalace XCUITest driveru selhala."
fi

# --- 2) Python prostředí ---------------------------------------------
if [ ! -x "$VENV/bin/python" ]; then
  say "Vytvářím Python prostředí (jen poprvé)..."
  python3 -m venv "$VENV" || die "Nepodařilo se vytvořit Python prostředí."
fi
if ! "$VENV/bin/python" -c "import appium, cv2, numpy, PIL, Vision" >/dev/null 2>&1; then
  say "Instaluji Python knihovny (jen poprvé, pár minut)..."
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r "$CORE/requirements.txt" || die "Instalace Python knihoven selhala."
fi

# --- 3) Appium server --------------------------------------------------
APPIUM_PID=""
cleanup() { [ -n "$APPIUM_PID" ] && kill "$APPIUM_PID" 2>/dev/null; }
trap cleanup EXIT
if curl -s "http://127.0.0.1:$PORT/status" >/dev/null 2>&1; then
  say "Appium už běží, použiji ho."
else
  say "Spouštím Appium server..."
  appium --port "$PORT" > "$WORK/appium.log" 2>&1 &
  APPIUM_PID=$!
  for i in $(seq 1 40); do
    curl -s "http://127.0.0.1:$PORT/status" >/dev/null 2>&1 && break
    sleep 1
    if [ "$i" = 40 ]; then die "Appium se nespustil. Log: $WORK/appium.log"; fi
  done
fi

# --- 4) bot --------------------------------------------------------------
say "Spouštím PoGo Inventory Manager (Stop / Ctrl+C běh ukončí a uloží výsledky)."
"$VENV/bin/python" "$CORE/pogo_bot.py" "$@" &
PY_PID=$!
trap 'kill -INT "$PY_PID" 2>/dev/null' INT TERM
wait "$PY_PID"; RC=$?
# po Stop se wait vrátí dřív – počkat, až bot uloží výsledky
while kill -0 "$PY_PID" 2>/dev/null; do wait "$PY_PID"; RC=$?; done
exit $RC
