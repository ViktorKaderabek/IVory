#!/bin/bash
# =====================================================================
#  Sestaví instalační disk dist/IVory.dmg (stálý název – odkaz
#  …/releases/latest/download/IVory.dmg v README tak vede vždy na nejnovější):
#  IVory.app + zástupce složky Aplikace na pozadí s šipkou a návodem.
#  Aplikace v DMG nic nepřibaluje – Node.js, Appium a Python si stáhne
#  sama při prvním spuštění (scripts/run.sh).
#
#    bash scripts/build_dmg.sh
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/app/Info.plist")"
DMG="$ROOT/dist/IVory.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# aplikace se sestaví bokem – z dist/IVory.app může zrovna běžet třídění
DIST="$WORK" bash "$ROOT/app/build_app.sh"

echo "▶ Kreslím pozadí DMG..."
swift "$ROOT/app/dmg/background.swift" "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

# dmgbuild nastaví pozadí a rozložení okna bez ovládání Finderu
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
