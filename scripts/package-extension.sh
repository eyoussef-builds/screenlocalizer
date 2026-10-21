#!/bin/bash
# Zips the browser extension for "Load unpacked" users and the Chrome Web Store:
#   dist/ScreenLocalizer-extension.zip  (manifest.json at the root of the zip)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 -c "import json; print(json.load(open('extension/manifest.json'))['version'])")"
OUT="dist/ScreenLocalizer-extension.zip"
mkdir -p dist
rm -f "$OUT"
(cd extension && zip -qrX "../$OUT" manifest.json background.js content.js options.html options.js popup.html popup.js icons -x "*.DS_Store")
zip -qjX "$OUT" LICENSE
echo "✓ $OUT ($VERSION)"
