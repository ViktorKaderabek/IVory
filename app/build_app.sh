#!/bin/bash
# Sestaví „IVory.app“ (Apple Silicon i Intel) do složky dist/.
#   bash app/build_app.sh            # sestavit
#   bash app/build_app.sh --install  # sestavit a zkopírovat do ~/Applications
#   DIST=/jinam bash app/build_app.sh  # sestavit jinam (třeba když z dist/ zrovna běží třídění)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="IVory"
OUT="${DIST:-$ROOT/dist}/$APP_NAME.app"
# skládá a podepisuje se mimo Plochu: iCloud tam bundlu přidává atributy (FinderInfo), které podpis odmítne
STAGE_DIR="$(mktemp -d)"
STAGE="$STAGE_DIR/$APP_NAME.app"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "▶ Překládám aplikaci (Swift, release, arm64 + x86_64)..."
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --package-path "$ROOT/app" "${ARCHS[@]}"
BIN_DIR="$(swift build -c release --package-path "$ROOT/app" "${ARCHS[@]}" --show-bin-path)"

echo "▶ Skládám $APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/PoGoInventoryManager" "$STAGE/Contents/MacOS/PoGoInventoryManager"
cp "$ROOT/app/Info.plist" "$STAGE/Contents/Info.plist"
echo "▶ Kreslím ikonu..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN_DIR/PoGoInventoryManager" --export-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/app/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
cp "$ROOT/app/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
# jádro (Python) a spouštěč jedou uvnitř aplikace
rsync -a --exclude "__pycache__" "$ROOT/core" "$ROOT/scripts" "$STAGE/Contents/Resources/"

echo "▶ Podepisuji (lokálně, ad-hoc)..."
xattr -cr "$STAGE"   # Finder metadata v bundlu podpis odmítne
codesign --force --deep --sign - "$STAGE"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
ditto "$STAGE" "$OUT"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  ditto "$STAGE" "$HOME/Applications/$APP_NAME.app"
  codesign --verify --deep "$HOME/Applications/$APP_NAME.app"
  echo "✔ Nainstalováno: ~/Applications/$APP_NAME.app"
fi
echo "✔ Hotovo: $OUT"
