#!/usr/bin/env bash
# Офлайн-компиляция всех MSL-шейдеров в один .metallib (только macOS: нужен xcrun metal).
# Движку на Metal не придётся компилировать шейдеры на телефоне — быстрее старт, меньше нагрев.
#   build_metallib.sh <каталог с .metal> <выходной .metallib>
set -euo pipefail
SRC="$1"; OUT="$2"
TMP="$(mktemp -d)"
ok=0; fail=0
for f in "$SRC"/*.metal; do
  n="$(basename "$f" .metal)"
  # У каждого шейдера точка входа main0 — переименовываем, чтобы они ужились в одной библиотеке.
  sed "s/\bmain0\b/${n}/" "$f" > "$TMP/$n.metal"
  if xcrun -sdk iphoneos metal -std=ios-metal2.1 -mios-version-min=15.0 -c "$TMP/$n.metal" -o "$TMP/$n.air" 2> "$TMP/$n.log"; then
    ok=$((ok+1))
  else
    fail=$((fail+1)); echo "  ✗ $n: $(grep -m1 error "$TMP/$n.log" || head -1 "$TMP/$n.log")"
    rm -f "$TMP/$n.air"
  fi
done
xcrun -sdk iphoneos metallib "$TMP"/*.air -o "$OUT"
echo "metallib: $ok шейдеров собрано, $fail с ошибками → $OUT ($(du -h "$OUT" | cut -f1))"
rm -rf "$TMP"
