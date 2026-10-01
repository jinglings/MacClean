#!/bin/zsh
# Convert app screenshots (PNG) into the web images the site loads.
# Usage: dev/make-screens.sh <dir with {light|dark}-{zh|en}-{tab}.png>
# Writes assets/img/screens/{name}.webp (1600w) and {name}-900.webp (900w).
set -e
SRC=${1:?usage: make-screens.sh <png dir>}
OUT=${0:A:h}/../assets/img/screens
mkdir -p "$OUT"
for f in "$SRC"/*.png; do
  name=${f:t:r}
  cwebp -quiet -q 80 -m 6 -resize 1600 0 "$f" -o "$OUT/$name.webp"
  cwebp -quiet -q 78 -m 6 -resize 900 0 "$f" -o "$OUT/$name-900.webp"
  echo "$name"
done
