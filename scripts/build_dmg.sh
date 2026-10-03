#!/bin/bash
# =====================================================================
#  Builds the installer disk dist/IVory.dmg (fixed name, so the link
#  …/releases/latest/download/IVory.dmg in the README always gets the newest one):
#  IVory.app + an Applications folder shortcut on a background with an arrow and instructions.
#  The app in the DMG bundles nothing: it downloads Node.js, Appium and Python
#  by itself on the first start (scripts/run.sh).
#
#    bash scripts/build_dmg.sh
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/app/Info.plist")"
DMG="$ROOT/dist/IVory.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# build the app elsewhere: a run may be sorting from dist/IVory.app right now
DIST="$WORK" bash "$ROOT/app/build_app.sh"

echo "▶ Kreslím pozadí DMG..."
swift "$ROOT/app/dmg/background.swift" "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

# dmgbuild sets the background and the window layout without scripting Finder
TOOLS="$ROOT/build/dmg-tools"
if [ ! -x "$TOOLS/bin/dmgbuild" ]; then
  echo "▶ Instaluji dmgbuild (jen poprvé)..."
  python3 -m venv "$TOOLS"
  "$TOOLS/bin/python" -m pip install -q --disable-pip-version-check dmgbuild
fi

echo "▶ Skládám $(basename "$DMG") (verze $VERSION)"
mkdir -p "$ROOT/dist"
rm -f "$DMG"
"$TOOLS/bin/dmgbuild" -s "$ROOT/app/dmg/settings.py" \
  -D app="$WORK/IVory.app" -D background="$WORK/background.tiff" \
  "IVory" "$DMG"
codesign --force --sign - "$DMG"
hdiutil verify "$DMG" >/dev/null
echo "✔ Hotovo: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
