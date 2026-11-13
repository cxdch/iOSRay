#!/usr/bin/env bash
# Скачивает OpenXRay на зафиксированном коммите (только нужные подмодули) и накладывает патчи iOSRay.
# Использование: scripts/fetch_openxray.sh [каталог]   (по умолчанию build/xray-16)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/build/xray-16}"
OPENXRAY_REV="${OPENXRAY_REV:-ddb78a5cfbe6719f4b5abe371e3fdeed0f3481fc}"

if [[ ! -d "$DEST/.git" ]]; then
    git init -q "$DEST"
    git -C "$DEST" remote add origin https://github.com/OpenXRay/xray-16.git
fi
git -C "$DEST" fetch -q --depth 1 origin "$OPENXRAY_REV"
git -C "$DEST" checkout -q -f FETCH_HEAD
git -C "$DEST" submodule update --init --depth 1 \
    Externals/LuaJIT Externals/luabind Externals/xrLuaFix Externals/gli \
    Externals/sse2neon Externals/imgui Externals/GameSpy
git -C "$DEST/Externals/xrLuaFix" submodule update --init --depth 1

for p in "$ROOT"/patches/openxray/*.patch; do
    echo "патч: $(basename "$p")"
    git -C "$DEST" apply --whitespace=nowarn "$p"
done
echo "OpenXRay $OPENXRAY_REV → $DEST"
