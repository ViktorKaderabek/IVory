#!/bin/bash
# Builds "IVory.app" (Apple Silicon and Intel) into dist/.
#   bash app/build_app.sh            # build
#   bash app/build_app.sh --install  # build and copy into ~/Applications
#   DIST=/elsewhere bash app/build_app.sh  # build elsewhere (e.g. while a run is sorting from dist/)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="IVory"
OUT="${DIST:-$ROOT/dist}/$APP_NAME.app"
# assemble and sign outside the Desktop: iCloud adds attributes (FinderInfo) to the bundle there, which codesign rejects
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
# the core (Python) and the launcher run inside the app
rsync -a --exclude "__pycache__" "$ROOT/core" "$ROOT/scripts" "$STAGE/Contents/Resources/"

echo "▶ Podepisuji (lokálně, ad-hoc)..."
xattr -cr "$STAGE"   # codesign rejects Finder metadata in the bundle
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
