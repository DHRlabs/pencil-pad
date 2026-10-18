#!/bin/bash
# Builds build/PencilPad.app (release binary + web/ page + Info.plist) and signs it.
# Safe to rerun: the bundle is rebuilt from scratch every time.
#   --install   then put this build in /Applications/PencilPad.app and open it there. The new bundle is copied next to
#               the old one under a temporary name and its signature checked first; then the PencilPad running from the
#               destination or from this repo's own build/PencilPad.app (and no other) is stopped with SIGTERM, which
#               lets the app release any held button; then the old bundle is swapped out. If anything fails the old
#               app stays as it was. The app opens at login from /Applications (see its Open at Login menu item).
# PENCILPAD_INSTALL_DIR=<folder> installs into that folder instead of /Applications, to try the steps without
# touching the real install. PENCILPAD_PORT, if set, is passed on to the app that gets opened.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
for arg in "$@"; do
  if [ "$arg" = "--install" ]; then INSTALL=1; fi
done

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
  <key>NSBonjourServices</key><array><string>_pencilpad._tcp</string></array>
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

if [ "$INSTALL" = 1 ]; then
  DEST_DIR="${PENCILPAD_INSTALL_DIR:-/Applications}"
  DEST="$DEST_DIR/PencilPad.app"
  APP_ABS="$PWD/$APP"
  TMP="$DEST_DIR/.PencilPad.app.new.$$"
  BAK="$DEST_DIR/.PencilPad.app.old.$$"
  trap 'rm -rf "$TMP"' EXIT

  # Same bundle id and signing identity as the copy being replaced, so its Accessibility and Screen Recording grants carry over.
  OLD_REQ=""
  if [ -d "$DEST" ]; then OLD_REQ="$(codesign -d -r- "$DEST" 2>&1 | grep '^designated' || true)"; fi

  # 1. The new bundle next to the old one, signature checked there. Nothing running has been touched yet.
  mkdir -p "$DEST_DIR"
  rm -rf "$TMP"
  ditto "$APP" "$TMP"
  codesign --verify --strict "$TMP"
  NEW_REQ="$(codesign -d -r- "$TMP" 2>&1 | grep '^designated' || true)"
  if [ -n "$OLD_REQ" ] && [ "$OLD_REQ" != "$NEW_REQ" ]; then
    echo "warning: the signing requirement changed from the copy it replaces; Accessibility and Screen Recording will need to be allowed again" >&2
  fi

  # 2. Stop PencilPad, but only a copy whose executable is in the destination's PencilPad.app or this repo's own
  #    build/PencilPad.app. Any other PencilPad on the Mac (another folder, another checkout) is left running.
  mine() {
    local pid cmd
    for pid in $(pgrep -f -- "/PencilPad.app/Contents/MacOS/PencilPad" || true); do
      cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
      case "$cmd" in
        "$DEST/Contents/MacOS/PencilPad"|"$DEST/Contents/MacOS/PencilPad "*) echo "$pid" ;;
        "$APP_ABS/Contents/MacOS/PencilPad"|"$APP_ABS/Contents/MacOS/PencilPad "*) echo "$pid" ;;
      esac
    done
  }
  PIDS="$(mine)"
  if [ -n "$PIDS" ]; then
    echo "stopping the running PencilPad: $(echo $PIDS)"
    kill $PIDS 2>/dev/null || true   # SIGTERM: the app lets go of any held button and quits
    for _ in $(seq 1 50); do [ -z "$(mine)" ] && break; sleep 0.2; done
    if [ -n "$(mine)" ]; then
      echo "error: PencilPad did not exit within 10 seconds; the installed app was not changed" >&2
      exit 1
    fi
  fi

  # 3. Swap: the old bundle steps aside, the new one takes its name; if that fails the old one goes back.
  if [ -d "$DEST" ]; then mv "$DEST" "$BAK"; fi
  if ! mv "$TMP" "$DEST"; then
    if [ -d "$BAK" ]; then mv "$BAK" "$DEST"; fi
    echo "error: could not put the new PencilPad in place; the old one is back" >&2
    exit 1
  fi
  rm -rf "$BAK"

  # -n: a new instance of this exact bundle, even if another PencilPad (another path, same bundle id) is running.
  open -n ${PENCILPAD_PORT:+--env "PENCILPAD_PORT=$PENCILPAD_PORT"} "$DEST"
  echo "installed and opened: $DEST"
fi
