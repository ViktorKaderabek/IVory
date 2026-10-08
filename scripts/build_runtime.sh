#!/bin/bash
# =====================================================================
#  Puts everything the bot needs into build/runtime:
#    node/         Node.js (official build from nodejs.org)
#    appium/       Appium server
#    appium-home/  XCUITest driver (WebDriverAgent is part of it)
#    python/       Python with libraries (OpenCV, Apple Vision, Appium client…)
#  Downloads happen only here, at build time; the finished runtime needs nothing more.
#  The app doesn't bundle it: scripts/run.sh sets up its own copy in ~/.pogo/runtime.
#
#    bash scripts/build_runtime.sh          # build (does nothing if already built)
#    bash scripts/build_runtime.sh --force  # build again
# =====================================================================
set -euo pipefail

NODE_VERSION=24.21.0
PY_RELEASE=20261001
PY_VERSION=3.12.15
APPIUM_VERSION=3.8.0
XCUITEST_VERSION=12.13.3

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/runtime"
DL="$ROOT/build/downloads"
REQ="$ROOT/core/requirements.lock"   # scripts/lock_python.sh, every package pinned with its SHA-256

case "$(uname -m)" in
  arm64)
    NODE_PKG="node-v$NODE_VERSION-darwin-arm64"
    NODE_SHA=bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057
    PY_PKG="cpython-$PY_VERSION+$PY_RELEASE-aarch64-apple-darwin-install_only_stripped"
    PY_SHA=10cab8f6ed6202fdd81637aa6eda4af8d5b7eaa8fc42f9df3c6bea4923de0d93 ;;
  x86_64)
    NODE_PKG="node-v$NODE_VERSION-darwin-x64"
    NODE_SHA=1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097
    PY_PKG="cpython-$PY_VERSION+$PY_RELEASE-x86_64-apple-darwin-install_only_stripped"
    PY_SHA=d101ac54bc34afff54741406261325dc896b7b646a36a58fff4845ef0a00b2ce ;;
  *) echo "✖ Nepodporovaná architektura $(uname -m)"; exit 1 ;;
esac

# What the bot doesn't need: PyObjC tests, Selenium's browser managers, Tk/IDLE (~35 MB)
prune_python() {
  local py="$1" site
  site="$("$py/bin/python3" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  rm -rf "$site/PyObjCTest" "$site/selenium/webdriver/common/"{linux,windows,macos} \
    "$py/lib/python3."*/{idlelib,tkinter,turtledemo,ensurepip} "$py/lib/"{tcl,tk,itcl}* "$py/lib/libtcl"*
}
if [ "${1:-}" = "--prune" ]; then   # only trim a runtime that is already built
  prune_python "$OUT/python"; echo "✔ Ořezáno ($(du -sh "$OUT" | cut -f1))"; exit 0
fi

# Content stamp: if neither the versions nor requirements.lock changed, the runtime isn't rebuilt.
STAMP="node $NODE_VERSION | python $PY_VERSION+$PY_RELEASE | appium $APPIUM_VERSION | xcuitest $XCUITEST_VERSION | $(uname -m) | req $(shasum -a 256 "$REQ" | cut -c1-12)"
if [ "${1:-}" != "--force" ] && [ -f "$OUT/VERSION" ] && [ "$(head -1 "$OUT/VERSION")" = "$STAMP" ]; then
  echo "✔ Runtime je hotový ($OUT)"
  exit 0
fi

fetch() {  # fetch URL FILE SHA256
  local url="$1" file="$DL/$2" sha="$3"
  if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
    return 0
  fi
  echo "  ↓ $2"
  curl -fL --retry 3 -sS -o "$file.part" "$url"
  if [ "$(shasum -a 256 "$file.part" | cut -d' ' -f1)" != "$sha" ]; then
    rm -f "$file.part"
    echo "✖ Kontrolní součet $2 nesedí"; exit 1
  fi
  mv "$file.part" "$file"
}

mkdir -p "$DL"
TMP="$ROOT/build/runtime.tmp"
rm -rf "$TMP"
mkdir -p "$TMP"

echo "▶ Node.js $NODE_VERSION"
fetch "https://nodejs.org/dist/v$NODE_VERSION/$NODE_PKG.tar.gz" "$NODE_PKG.tar.gz" "$NODE_SHA"
tar -xzf "$DL/$NODE_PKG.tar.gz" -C "$TMP"
mv "$TMP/$NODE_PKG" "$TMP/node"
rm -rf "$TMP/node/include" "$TMP/node/share" "$TMP/node/lib/node_modules/corepack" "$TMP/node/bin/corepack"
export PATH="$TMP/node/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export npm_config_cache="$DL/npm-cache" npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false

echo "▶ Appium $APPIUM_VERSION"
mkdir -p "$TMP/appium"
echo '{"private": true}' > "$TMP/appium/package.json"
npm install --prefix "$TMP/appium" --omit=dev --loglevel=error "appium@$APPIUM_VERSION"

echo "▶ XCUITest driver $XCUITEST_VERSION"
mkdir -p "$TMP/appium-home"
APPIUM_HOME="$TMP/appium-home" node "$TMP/appium/node_modules/appium/index.js" \
  driver install --source=npm "appium-xcuitest-driver@$XCUITEST_VERSION"
# WebDriverAgent creates this folder on its own; create it now so it doesn't have to write into it
mkdir -p "$TMP/appium-home/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/Resources/WebDriverAgent.bundle" 2>/dev/null || true

echo "▶ Python $PY_VERSION a knihovny"
fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/${PY_PKG/+/%2B}.tar.gz" "$PY_PKG.tar.gz" "$PY_SHA"
tar -xzf "$DL/$PY_PKG.tar.gz" -C "$TMP"   # extracts into python/
PIP_CACHE_DIR="$DL/pip-cache" "$TMP/python/bin/python3" -m pip install --disable-pip-version-check -q \
  --require-hashes --only-binary=:all: -r "$ROOT/core/requirements-build.lock"
PIP_CACHE_DIR="$DL/pip-cache" "$TMP/python/bin/python3" -m pip install --disable-pip-version-check -q \
  --require-hashes --only-binary=:all: --no-binary=hexdump --no-build-isolation -r "$REQ"
prune_python "$TMP/python"
"$TMP/python/bin/python3" -c "import appium, selenium, cv2, numpy, PIL, Vision, Foundation; print('  knihovny OK: OpenCV', cv2.__version__, '| NumPy', numpy.__version__)"
"$TMP/python/bin/python3" -m compileall -q "$SITE" >/dev/null 2>&1 || true

{
  echo "$STAMP"
  echo "built $(date '+%Y-%m-%d %H:%M:%S')"
} > "$TMP/VERSION"

rm -rf "$OUT"
mv "$TMP" "$OUT"
echo "✔ Runtime hotový: $OUT ($(du -sh "$OUT" | cut -f1))"
