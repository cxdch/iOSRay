#!/usr/bin/env bash
# Упаковывает собранный движок (xr_3da) в iOSRay-*.ipa / *.tipa.
# В бандл кладутся ресурсы OpenXRay (res/fsgame.ltx, res/gamedata); ios_bootstrap.mm
# при запуске связывает их с папкой игры в Documents.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XRAY="${XRAY:-$ROOT/build/xray-16}"
OUT="${OUT:-$ROOT/build}"
EXE="${1:-$(find "$XRAY/bin" -path '*xr_3da.app/xr_3da' | head -1)}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date -u +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-local.stalkerios.iosray}"
[[ -f "$EXE" ]] || { echo "нет xr_3da: $EXE" >&2; exit 1; }

package() {
    local variant="$1" ext="$2"
    local stage="$OUT/engine-$variant"
    local app="$stage/Payload/iOSRay.app"
    rm -rf "$stage"
    mkdir -p "$app/res"
    cp "$EXE" "$app/xr_3da"
    sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/" -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" \
        -e "s/@VARIANT@/engine-$variant/" "$ROOT/app/engine-Info.plist" > "$app/Info.plist"
    printf 'APPL????' > "$app/PkgInfo"
    cp "$XRAY/res/fsgame.ltx" "$app/res/"
    cp "$ROOT/res/iosray.ltx" "$app/res/"
    cp -R "$ROOT/app/Settings.bundle" "$app/"   # «Настройки» iOS → iOSRay
    cp -R "$XRAY/res/gamedata" "$app/res/"

    if [[ "$variant" == trollstore ]]; then
        local ent="$stage/entitlements.plist"
        sed "s/@BUNDLE_ID@/$BUNDLE_ID/" "$ROOT/app/entitlements/trollstore.plist" > "$ent"
        if command -v ldid >/dev/null; then ldid -S"$ent" "$app/xr_3da"
        else codesign -f -s - --entitlements "$ent" "$app/xr_3da"; fi
    else
        if command -v codesign >/dev/null; then codesign -f -s - "$app"
        elif command -v ldid >/dev/null; then ldid -S "$app/xr_3da"; fi
    fi
    if find "$app" -name '*.dSYM' | grep -q .; then echo "ОШИБКА: dSYM в пакете" >&2; exit 1; fi
    (cd "$stage" && rm -f "$OUT/iOSRay-$variant.$ext" && zip -qry "$OUT/iOSRay-$variant.$ext" Payload)
    echo "готово: $OUT/iOSRay-$variant.$ext ($(du -h "$OUT/iOSRay-$variant.$ext" | cut -f1))"
}

package sidestore ipa
package trollstore tipa
