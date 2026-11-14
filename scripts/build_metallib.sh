#!/usr/bin/env bash
# Офлайн-компиляция всех MSL-шейдеров в один .metallib (только macOS: нужен xcrun metal).
# Движку на Metal не придётся компилировать шейдеры на телефоне — быстрее старт, меньше нагрев.
#   build_metallib.sh <каталог с .metal> <выходной .metallib>
set -euo pipefail
SRC="$1"; OUT="$2"
TMP="$(mktemp -d)"
ok=0; fail=0
for f in "$SRC"/*.metal; do
  # Имя функции = имя файла, где всё, кроме [A-Za-z0-9_], заменено на «_»
  # (у OpenXRay есть файлы с «-» и даже пробелом в имени).
  n="$(basename "$f" .metal | LC_ALL=C sed 's/[^A-Za-z0-9_]/_/g')"
  # У каждого шейдера точка входа main0 — переименовываем, чтобы они ужились в одной библиотеке.
  # (BSD sed на macOS не знает \b — берём perl)
  perl -pe "s/\bmain0\b/${n}/g" "$f" > "$TMP/$n.metal"
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
