#!/bin/bash
# Renders Assets/AppIcon.html with headless Chrome and packs it into Resources/AppIcon.icns.
# Only needed when the icon design changes; the generated .icns is kept in the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=00000000 --window-size=1024,1024 \
  --screenshot="$WORK/icon1024.png" "file://$PWD/Assets/AppIcon.html" >/dev/null 2>&1

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$WORK/icon1024.png" Assets/AppIcon-1024.png
echo "Wrote Resources/AppIcon.icns"
