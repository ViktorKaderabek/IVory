#!/bin/bash
# =====================================================================
#  Puts the two pieces that replace Xcode into runtime/:
#    WebDriverAgentRunner.app   the runner, built in advance by the Appium project
#    altsign-cli                signs it with the user's own Apple ID
#
#  Run this once before building the app; build_app.sh copies runtime/ into the bundle.
#  Until IVory 1.3 the user's own Xcode built and signed WebDriverAgent on every machine,
#  which is the only reason Xcode was required at all.
#
#    bash scripts/build_wda_runtime.sh          # build (skips what is already there)
#    bash scripts/build_wda_runtime.sh --force  # build again
# =====================================================================
set -euo pipefail

WDA_VERSION=v16.14.0
WDA_SHA=6f7758f72d348d2c35c3fd134fa76a941bba0c447de04b2e9d065682f31fc47f
OPENSSL_VERSION=3.5.4
OPENSSL_SHA=967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99
MACOS_MIN=14.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/runtime"
DL="$ROOT/build/downloads"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
mkdir -p "$OUT" "$DL"

die() { printf '\n✖ %s\n' "$*" >&2; exit 1; }

# --- WebDriverAgent ------------------------------------------------------
# The "-Runner" asset is the real-device build and is the only one that works on iOS 17+: it ships
# without the embedded XCTest frameworks, so the phone lends the runner its own copies instead.
if [ "$FORCE" = 1 ] || [ ! -d "$OUT/WebDriverAgentRunner.app" ]; then
  echo "▶ WebDriverAgent $WDA_VERSION"
  ZIP="$DL/WebDriverAgentRunner-Runner-$WDA_VERSION.zip"
  if [ ! -f "$ZIP" ] || [ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" != "$WDA_SHA" ]; then
    curl -fL --retry 3 -sS -o "$ZIP.part" \
      "https://github.com/appium/WebDriverAgent/releases/download/$WDA_VERSION/WebDriverAgentRunner-Runner.zip" \
      || die "Stažení WebDriverAgentu selhalo."
    [ "$(shasum -a 256 "$ZIP.part" | cut -d' ' -f1)" = "$WDA_SHA" ] || { rm -f "$ZIP.part"; die "Kontrolní součet WebDriverAgentu nesedí."; }
    mv "$ZIP.part" "$ZIP"
  fi
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  unzip -q "$ZIP" -d "$TMP"
  APP="$TMP/WebDriverAgentRunner-Runner.app"
  [ -d "$APP" ] || die "V archivu není WebDriverAgentRunner-Runner.app."
  # Debug symbols are a third of the bundle and the phone never reads them.
  rm -rf "$APP/PlugIns/WebDriverAgentRunner.xctest.dSYM"
  # Belt and braces: a future release that does embed the XCTest frameworks would fail on iOS 17+.
  rm -rf "$APP/Frameworks/XC"*.framework "$APP/Frameworks/Testing.framework" \
         "$APP/Frameworks/libXCTestSwiftSupport.dylib"
  rm -rf "$OUT/WebDriverAgentRunner.app"
  mv "$APP" "$OUT/WebDriverAgentRunner.app"
  echo "  ✔ $(du -sh "$OUT/WebDriverAgentRunner.app" | cut -f1)"
fi

# --- altsign-cli ---------------------------------------------------------
# Signs with a free Apple ID. A development profile only covers the UDIDs it names, so the signature
# has to be made on the user's machine with the user's account – ours would be refused by their phone.
# OpenSSL is linked in statically and the binary is universal: the user's Mac has no Homebrew, and may
# be an Intel one.

# Static OpenSSL for one architecture, into build/openssl-<arch>.
build_openssl() {
  local arch="$1" prefix="$ROOT/build/openssl-$1"
  [ -f "$prefix/lib/libcrypto.a" ] && return
  local tgz="$DL/openssl-$OPENSSL_VERSION.tar.gz"
  if [ ! -f "$tgz" ] || [ "$(shasum -a 256 "$tgz" | cut -d' ' -f1)" != "$OPENSSL_SHA" ]; then
    curl -fL --retry 3 -sS -o "$tgz.part" \
      "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
      || die "Stažení OpenSSL selhalo."
    [ "$(shasum -a 256 "$tgz.part" | cut -d' ' -f1)" = "$OPENSSL_SHA" ] || { rm -f "$tgz.part"; die "Kontrolní součet OpenSSL nesedí."; }
    mv "$tgz.part" "$tgz"
  fi
  local src; src="$(mktemp -d)"
  tar -xzf "$tgz" -C "$src"
  echo "  ▶ OpenSSL $OPENSSL_VERSION ($arch)"
  ( cd "$src/openssl-$OPENSSL_VERSION" \
    && ./Configure "darwin64-$arch-cc" no-shared no-tests no-docs --prefix="$prefix" --openssldir=/dev/null \
         -mmacosx-version-min="$MACOS_MIN" >/dev/null 2>&1 \
    && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install_sw >/dev/null ) || die "Build OpenSSL ($arch) selhal."
  rm -rf "$src"
}

# altsign-cli for one architecture, the same compile as its own build.sh but against the static OpenSSL.
# ivory_log.h (from the patch) is included into every file: it keeps the log out of the system log.
build_altsign() {
  local arch="$1" ssl="$ROOT/build/openssl-$1" sdk; sdk="$(xcrun --show-sdk-path)"
  local flags=(-arch "$arch" -mmacosx-version-min="$MACOS_MIN" -isysroot "$sdk" -DCORECRYPTO_DONOT_USE_TRANSPARENT_UNION
               -IDependencies -include ivory_log.h)
  ( cd "$SRC" \
    && clang -ObjC -fobjc-arc "${flags[@]}" -c Dependencies/corecrypto/ccsrp.m -o "$WORK/ccsrp-$arch.o" \
    && clang++ -std=c++17 -ObjC++ -fobjc-arc -w "${flags[@]}" -I"$ssl/include" \
         -framework Foundation -framework Security -framework CoreFoundation \
         -L"$sdk/usr/lib/system" -lcorecrypto "$ssl/lib/libssl.a" "$ssl/lib/libcrypto.a" \
         main.mm diagnostics.mm anisette.mm srp_auth.mm apple_api.mm certificate_request.mm signer.mm \
         "$WORK/ccsrp-$arch.o" -o "$WORK/altsign-cli-$arch" ) || die "Build altsign-cli ($arch) selhal."
}

if [ "$FORCE" = 1 ] || [ ! -x "$OUT/altsign-cli" ]; then
  echo "▶ altsign-cli (vendor/altsign-cli + vendor/altsign-cli.patch)"
  WORK="$(mktemp -d)"
  SRC="$WORK/src"
  cp -R "$ROOT/vendor/altsign-cli" "$SRC"
  ( cd "$SRC" && patch -s -p1 < "$ROOT/vendor/altsign-cli.patch" ) || die "Patch altsign-cli nejde použít."
  for arch in arm64 x86_64; do
    build_openssl "$arch"
    build_altsign "$arch"
  done
  lipo -create "$WORK/altsign-cli-arm64" "$WORK/altsign-cli-x86_64" -output "$OUT/altsign-cli"
  chmod +x "$OUT/altsign-cli"
  ! otool -L "$OUT/altsign-cli" | grep -q -e /opt/ -e /usr/local/ || die "altsign-cli odkazuje na knihovnu mimo systém."
  # AGPL-3.0: shipping the binary obliges us to offer its source – it's vendor/ in IVory's repository.
  cp "$SRC/LICENSE" "$OUT/altsign-cli.LICENSE"
  printf 'altsign-cli (AGPL-3.0)\nSource: https://github.com/ViktorKaderabek/IVory/tree/main/vendor (upstream https://github.com/xhzq233/altsign-cli)\n' \
    > "$OUT/altsign-cli.SOURCE"
  rm -rf "$WORK"
  echo "  ✔ $(lipo -archs "$OUT/altsign-cli"), $(du -sh "$OUT/altsign-cli" | cut -f1)"
fi

echo "✔ runtime/ hotové: $(du -sh "$OUT" | cut -f1)"
