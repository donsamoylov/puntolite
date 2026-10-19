#!/bin/bash
# Иконки из SVG: Resources/AppIcon.icns и Resources/MenuIcon.pdf (нужен rsvg-convert: brew install librsvg)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f Resources/AppIcon.icns ] && [ -f Resources/MenuIcon.pdf ] && exit 0
command -v rsvg-convert >/dev/null || brew install librsvg
SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s Resources/icon.svg -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) Resources/icon.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rsvg-convert -f pdf Resources/menu.svg -o Resources/MenuIcon.pdf
echo "Иконки готовы"
