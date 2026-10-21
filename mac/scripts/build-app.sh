#!/bin/bash
# Builds build/ScreenLocalizer.app (Apple Silicon, release) without Xcode or SwiftPM.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  build, copy to /Applications and relaunch
#   CONFIG=debug scripts/build-app.sh   unoptimised build with debug info
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ScreenLocalizer.app"
CONFIG="${CONFIG:-release}"
SDK="$(xcrun --show-sdk-path)"
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find Sources -name '*.swift' -print0)

if [[ "$CONFIG" == "debug" ]]; then OPT=(-Onone -g); else OPT=(-O -wmo); fi

echo "→ Compiling ${#SOURCES[@]} files ($CONFIG)…"
mkdir -p build
swiftc "${OPT[@]}" -swift-version 5 -target arm64-apple-macos14.0 -sdk "$SDK" \
  -module-name ScreenLocalizer "${SOURCES[@]}" -o build/ScreenLocalizer

echo "→ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/ScreenLocalizer "$APP/Contents/MacOS/ScreenLocalizer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
for strings in "$APP"/Contents/Resources/*.lproj/*.strings; do
  plutil -lint -s "$strings"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signs with a stable local identity if the user created one (scripts/setup-signing.sh) so macOS
# keeps Accessibility / Screen Recording approvals across updates; otherwise ad-hoc.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ScreenLocalizer Local Signing"; then
  IDENTITY="ScreenLocalizer Local Signing"
fi
codesign --force --sign "$IDENTITY" --identifier me.eyoussef.screenlocalizer --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "→ Signed ($( [[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "$IDENTITY" ))"

if [[ "${1:-}" == "--install" ]]; then
  echo "→ Installing to /Applications…"
  osascript -e 'if application id "me.eyoussef.screenlocalizer" is running then tell application id "me.eyoussef.screenlocalizer" to quit' >/dev/null 2>&1 || true
  pkill -x ScreenLocalizer >/dev/null 2>&1 || true
  sleep 0.5
  rm -rf /Applications/ScreenLocalizer.app
  cp -R "$APP" /Applications/ScreenLocalizer.app
  open /Applications/ScreenLocalizer.app
  echo "✓ Installed and launched /Applications/ScreenLocalizer.app"
else
  echo "✓ Built $APP"
fi
