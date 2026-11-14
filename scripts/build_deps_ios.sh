#!/usr/bin/env bash
# Собирает зависимости OpenXRay статическими библиотеками для iOS arm64 (iOS 15+).
# Результат: $PREFIX/{include,lib}.  По умолчанию PREFIX=build/ios-prefix.
#
# macOS: всё из Xcode.  Linux (только проверка): SDKROOT=/путь/iPhoneOS.sdk
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$ROOT/build/ios-prefix}"
SRC="${DEPS_SRC:-$ROOT/build/deps-src}"
TOOLCHAIN="$ROOT/cmake/ios.toolchain.cmake"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"
mkdir -p "$PREFIX" "$SRC"
export XR_IOS_PREFIX="$PREFIX"

fetch() { # имя репозиторий тег
    local dir="$SRC/$1"
    [[ -d "$dir" ]] || git -c advice.detachedHead=false clone -q --depth 1 -b "$3" "$2" "$dir"
}

cmake_build() { # каталог-исходников имя [аргументы cmake...]
    local src="$1" name="$2"; shift 2
    echo "== $name"
    cmake -S "$src" -B "$SRC/build-$name" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@" > "$SRC/$name.configure.log"
    cmake --build "$SRC/build-$name" -j "$JOBS" > "$SRC/$name.build.log"
    cmake --install "$SRC/build-$name" > /dev/null
}

fetch ogg    https://github.com/xiph/ogg.git          v1.3.5
fetch vorbis https://github.com/xiph/vorbis.git       v1.3.7
fetch theora https://github.com/xiph/theora.git       v1.2.0
fetch lzo    https://github.com/nemequ/lzo.git        master
fetch sdl2   https://github.com/libsdl-org/SDL.git    release-2.30.9
fetch openal https://github.com/kcat/openal-soft.git  1.24.1
fetch astcenc https://github.com/ARM-software/astc-encoder.git 5.2.0
LUAJIT_REV=5a5cd82e435a7b08d61b4e0af887493d24d9eca1   # подмодуль OpenXRay/LuaJIT в xray-16
if [[ ! -d "$SRC/luajit" ]]; then
    git init -q "$SRC/luajit"
    git -C "$SRC/luajit" fetch -q --depth 1 https://github.com/OpenXRay/LuaJIT.git "$LUAJIT_REV"
    git -C "$SRC/luajit" checkout -q FETCH_HEAD
fi

cmake_build "$SRC/ogg"    ogg    -DINSTALL_DOCS=OFF
cmake_build "$SRC/vorbis" vorbis
cmake_build "$ROOT/deps/theora" theora -DTHEORA_SOURCE_DIR="$SRC/theora"
cmake_build "$SRC/lzo"    lzo    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON
cmake_build "$SRC/sdl2"   sdl2   -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
cmake_build "$SRC/openal" openal -DLIBTYPE=STATIC -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF \
    -DALSOFT_INSTALL_EXAMPLES=OFF -DALSOFT_INSTALL_UTILS=OFF -DALSOFT_BACKEND_COREAUDIO=ON

# ARM astcenc: пересжатие текстур DXT → ASTC 4x4 прямо на телефоне (кэшируется на диск).
cmake_build "$SRC/astcenc" astcenc -DASTCENC_ISA_NEON=ON -DASTCENC_CLI=OFF \
    -DASTCENC_UNIVERSAL_BUILD=OFF -DASTCENC_SHAREDLIB=OFF -DASTCENC_INVARIANCE=OFF
cp "$(find "$SRC/build-astcenc" -name 'libastcenc-neon-static.a' | head -1)" "$PREFIX/lib/libastcenc.a"
cp "$SRC/astcenc/Source/astcenc.h" "$PREFIX/include/astcenc.h"

# LuaJIT: штатная кросс-сборка Makefile'ом. JIT на iOS запрещён — только интерпретатор.
echo "== luajit"
SDK_PATH="${SDKROOT:-$(xcrun --sdk iphoneos --show-sdk-path)}"
if command -v llvm-ar-18 >/dev/null; then LJ_AR="llvm-ar-18 rcus"; else LJ_AR="ar rcus"; fi
HOST_CC_BIN="$(command -v gcc || command -v clang)"
# Makefile LuaJIT на macOS-хосте требует MACOSX_DEPLOYMENT_TARGET (в том числе для clean).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
make -C "$SRC/luajit/src" clean > /dev/null
make -C "$SRC/luajit/src" -j "$JOBS" libluajit.a HOST_CC="$HOST_CC_BIN" CC=clang CROSS="" \
    TARGET_SYS=iOS TARGET_FLAGS="-target arm64-apple-ios15.0 -isysroot $SDK_PATH" \
    TARGET_AR="$LJ_AR" XCFLAGS="-DLUAJIT_DISABLE_JIT" BUILDMODE=static > "$SRC/luajit.build.log"
cp "$SRC/luajit/src/libluajit.a" "$PREFIX/lib/libluajit.a"

echo "Готово: $PREFIX"
ls "$PREFIX/lib"/*.a
