#!/bin/bash
# Sestaví „PoGo Inventory Manager.app“ do složky dist/.
#   bash app/build_app.sh            # sestavit
#   bash app/build_app.sh --install  # sestavit a zkopírovat do ~/Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PoGo Inventory Manager"
OUT="$ROOT/dist/$APP_NAME.app"

echo "▶ Překládám aplikaci (Swift, release)..."
swift build -c release --package-path "$ROOT/app"
BIN_DIR="$(swift build -c release --package-path "$ROOT/app" --show-bin-path)"

echo "▶ Skládám $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/PoGoInventoryManager" "$OUT/Contents/MacOS/PoGoInventoryManager"
cp "$ROOT/app/Info.plist" "$OUT/Contents/Info.plist"
if [ ! -f "$ROOT/app/AppIcon.icns" ]; then
  echo "▶ Kreslím ikonu..."
  bash "$ROOT/app/make_icon.sh"
fi
cp "$ROOT/app/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
# jádro (Python) a spouštěč jedou uvnitř aplikace
rsync -a --exclude "__pycache__" "$ROOT/core" "$ROOT/scripts" "$OUT/Contents/Resources/"

echo "▶ Podepisuji (lokálně, ad-hoc)..."
xattr -cr "$OUT"   # Finder metadata v bundlu podpis odmítne
codesign --force --deep --sign - "$OUT"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$OUT" "$HOME/Applications/"
  echo "✔ Nainstalováno: ~/Applications/$APP_NAME.app"
fi
echo "✔ Hotovo: $OUT"
