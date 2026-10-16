#!/bin/bash
# Builds build/PencilPad.app (release binary + web/ page + Info.plist) and signs it.
# Safe to rerun: the bundle is rebuilt from scratch every time.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD_NUMBER="1"
APP="build/PencilPad.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PencilPad"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/PencilPad"

if [ -d web ] && [ -n "$(ls -A web)" ]; then
  cp -R web/. "$APP/Contents/Resources/web/"
else
  echo "warning: web/ is missing or empty; the app will serve 404s until web/ is filled and this script reruns" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.dhrlabs.pencilpad</string>
  <key>CFBundleName</key><string>PencilPad</string>
  <key>CFBundleDisplayName</key><string>PencilPad</string>
  <key>CFBundleExecutable</key><string>PencilPad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>PencilPad serves its drawing page to your iPad and receives Apple Pencil input over your local network.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  echo "warning: no Apple Development identity found; signing ad hoc (Accessibility permission will not survive rebuilds)" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "$PWD/$APP"
