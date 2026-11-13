#!/usr/bin/env bash
# Собирает движок OpenXRay под iOS arm64: все статические библиотеки и исполняемый xr_3da.
# Нужны: scripts/build_deps_ios.sh (зависимости) и scripts/fetch_openxray.sh (исходники с патчами).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XRAY="${XRAY:-$ROOT/build/xray-16}"
PREFIX="${PREFIX:-$ROOT/build/ios-prefix}"
BUILD="${ENGINE_BUILD:-$ROOT/build/engine}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"
export XR_IOS_PREFIX="$PREFIX"

cmake -S "$XRAY" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/ios.toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$PREFIX" -DXR_IOS_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF \
    -DOPENAL_INCLUDE_DIR="$PREFIX/include/AL" -DOPENAL_LIBRARY="$PREFIX/lib/libopenal.a"

set +e
cmake --build "$BUILD" -j "$JOBS" -- -k 0 2>&1 | tee "$BUILD/build.log" | grep -E "^\[[0-9]+/|error:|FAILED" | grep -vE "^\[" 
STATUS=${PIPESTATUS[0]}
set -e

echo "== Итог"
echo "ошибок компиляции: $(grep -c '^FAILED' "$BUILD/build.log" || true)"
find "$BUILD" -name '*.a' | sort | while read -r a; do printf '  %-40s %s\n' "$(basename "$a")" "$(du -h "$a" | cut -f1)"; done
EXE="$(find "$XRAY/bin" -path '*xr_3da.app/xr_3da' | head -1)"
[[ -n "$EXE" ]] && echo "исполняемый файл: $EXE ($(du -h "$EXE" | cut -f1))"
exit "$STATUS"
