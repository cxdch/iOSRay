#!/usr/bin/env bash
# Сборка XRProbe в два IPA:
#   build/XRProbe-sidestore.ipa  — без особых прав, ставится через SideStore/AltStore/Sideloadly;
#   build/XRProbe-trollstore.tipa — фейковая подпись ldid с расширенными правами для TrollStore.
#
# На macOS (в том числе в GitHub Actions) всё берётся из Xcode через xcrun.
# На Linux можно собрать тем же скриптом, если задать:
#   SDKROOT=/путь/к/iPhoneOS.sdk  CXX=clang++  LDFLAGS="-fuse-ld=lld"   (нужны ldid и zip)
#
# Использование: scripts/build_ipa.sh [каталог с .metal-шейдерами OpenXRay]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHADERS="${1:-}"
OUT="$ROOT/build"
APP_NAME=XRProbe
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date -u +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-local.stalkerios.xrprobe}"

if [[ -z "${SDKROOT:-}" ]]; then
    SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
fi
CXX="${CXX:-$(xcrun --sdk iphoneos -f clang++ 2>/dev/null || echo clang++)}"
LDFLAGS="${LDFLAGS:-}"

rm -rf "$OUT"
mkdir -p "$OUT"

build_variant() {
    local variant="$1" ext="$2"
    local stage="$OUT/$variant"
    local app="$stage/Payload/$APP_NAME.app"
    mkdir -p "$app"

    echo "== Компиляция ($variant)"
    # shellcheck disable=SC2086
    "$CXX" -target arm64-apple-ios15.0 -isysroot "$SDKROOT" \
        -fobjc-arc -std=c++17 -O2 -g -Wall -Werror=objc-method-access \
        "$ROOT/app/main.mm" \
        -framework UIKit -framework Metal -framework QuartzCore -framework Foundation \
        $LDFLAGS -o "$app/$APP_NAME"

    sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/" -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" \
        "$ROOT/app/Info.plist" > "$app/Info.plist"
    printf 'APPL????' > "$app/PkgInfo"

    if [[ -n "$SHADERS" && -d "$SHADERS" ]]; then
        mkdir -p "$app/xrshaders"
        cp "$SHADERS"/*.metal "$app/xrshaders/"
        echo "   шейдеров OpenXRay в пакете: $(ls "$app/xrshaders" | wc -l)"
    fi

    echo "== Подпись ($variant)"
    if [[ "$variant" == trollstore ]]; then
        local ent="$stage/entitlements.plist"
        sed "s/@BUNDLE_ID@/$BUNDLE_ID/" "$ROOT/app/entitlements/trollstore.plist" > "$ent"
        if command -v ldid >/dev/null; then
            ldid -S"$ent" "$app/$APP_NAME"
        else
            codesign -f -s - --entitlements "$ent" "$app/$APP_NAME"
        fi
    else
        # SideStore переподпишет приложение своим сертификатом; здесь — только ad-hoc подпись.
        if command -v codesign >/dev/null; then
            codesign -f -s - "$app"
        elif command -v ldid >/dev/null; then
            ldid -S "$app/$APP_NAME"
        fi
    fi

    (cd "$stage" && zip -qry "$OUT/$APP_NAME-$variant.$ext" Payload)
    echo "   готово: build/$APP_NAME-$variant.$ext ($(du -h "$OUT/$APP_NAME-$variant.$ext" | cut -f1))"
}

build_variant sidestore ipa
build_variant trollstore tipa
