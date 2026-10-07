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
swift build -c release --package-path "$ROOT/app" "${ARCHS[@]}" -Xlinker -dead_strip
BIN_DIR="$(swift build -c release --package-path "$ROOT/app" "${ARCHS[@]}" -Xlinker -dead_strip --show-bin-path)"

echo "▶ Skládám $APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/PoGoInventoryManager" "$STAGE/Contents/MacOS/PoGoInventoryManager"
# the debug and local symbols are two thirds of the binary and nothing at runtime reads them
# (Swift reflection lives in __TEXT and survives); strip before signing, it invalidates the signature
strip -x -S "$STAGE/Contents/MacOS/PoGoInventoryManager"
cp "$ROOT/app/Info.plist" "$STAGE/Contents/Info.plist"
echo "▶ Kreslím ikonu..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN_DIR/PoGoInventoryManager" --export-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/app/AppIcon.icns"
python3 "$ROOT/app/shrink_icns.py" "$ROOT/app/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
cp "$ROOT/app/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
# the core (Python) and the launcher run inside the app
# runtime/ carries the prebuilt WebDriverAgent and altsign-cli: without them the app would need the
# user's Xcode again, so a missing runtime/ is a broken build, not a smaller one.
[ -x "$ROOT/runtime/altsign-cli" ] && [ -d "$ROOT/runtime/WebDriverAgentRunner.app" ] || {
  echo "✖ Chybí runtime/. Spusť nejdřív: bash scripts/build_wda_runtime.sh" >&2; exit 1; }
rsync -a --exclude "__pycache__" "$ROOT/core" "$ROOT/scripts" "$ROOT/runtime" "$STAGE/Contents/Resources/"
# the setup guide's iPhone screenshots (setup/<name>.png, setup/cs/<name>.png); missing ones are drawn
[ -d "$ROOT/app/Resources/setup" ] && rsync -a --exclude ".*" --exclude "README.md" "$ROOT/app/Resources/setup" "$STAGE/Contents/Resources/"

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
