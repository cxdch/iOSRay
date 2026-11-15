#!/usr/bin/env bash
# iOSRay: Rust-часть (rust/texcodec) → статическая библиотека для iOS arm64.
# Кладёт libxr_texcodec.a и xr_texcodec.h в префикс зависимостей, где их найдёт CMake.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$ROOT/build/ios-prefix}"
CRATE="$ROOT/rust/texcodec"

rustup target add aarch64-apple-ios
cd "$CRATE"
cargo test --release           # проверки на машине сборки (декодер, заголовки .xra)
IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --release --target aarch64-apple-ios

mkdir -p "$PREFIX/lib" "$PREFIX/include"
cp "target/aarch64-apple-ios/release/libxr_texcodec.a" "$PREFIX/lib/"
cp include/xr_texcodec.h "$PREFIX/include/"
echo "texcodec: $(du -h "$PREFIX/lib/libxr_texcodec.a" | cut -f1) → $PREFIX/lib"
