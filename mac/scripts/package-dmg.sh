#!/bin/bash
# Builds the app and wraps it in a drag-to-Applications disk image: build/ScreenLocalizer-mac.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
VERSION="$(plutil -extract CFBundleShortVersionString raw build/ScreenLocalizer.app/Contents/Info.plist)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R build/ScreenLocalizer.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Assets/Read Me First.txt" "$STAGE/"
cp ../LICENSE "$STAGE/LICENSE.txt"
# Drop macOS extended attributes (provenance/quarantine tags) so nothing local ships in the image.
xattr -cr "$STAGE"
hdiutil create -volname "ScreenLocalizer $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  "build/ScreenLocalizer-mac.dmg" >/dev/null
echo "✓ build/ScreenLocalizer-mac.dmg ($VERSION)"
