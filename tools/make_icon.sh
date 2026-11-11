#!/bin/zsh
# Renders design/icon/make_icon.py into Resources/AppIcon.icns (needs Inkscape).
# 16 and 32 px use the simplified drawing so the macaron still reads at that size.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
python3 design/icon/make_icon.py "$TMP/full.svg"
python3 design/icon/make_icon.py "$TMP/small.svg" --small
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET" Resources
render() { nice -n 19 inkscape "$1" --export-type=png --export-filename="$2" -w "$3" 2>/dev/null; }
render "$TMP/small.svg" "$SET/icon_16x16.png" 16
render "$TMP/small.svg" "$SET/icon_16x16@2x.png" 32
render "$TMP/small.svg" "$SET/icon_32x32.png" 32
render "$TMP/full.svg" "$SET/icon_32x32@2x.png" 64
for size in 128 256 512; do
  render "$TMP/full.svg" "$SET/icon_${size}x${size}.png" $size
  render "$TMP/full.svg" "$SET/icon_${size}x${size}@2x.png" $((size * 2))
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$SET/icon_512x512@2x.png" design/icon/AppIcon-1024.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
