#!/bin/zsh
# Builds the app and produces a distributable DMG in ../dist, and (with
# `install`) also copies it into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="VK Turn Proxy.app"
DIST="../dist"
DMG="$DIST/VK-Turn-Proxy.dmg"
STAGE="$DIST/stage"

echo "==> build"
./build.sh >/dev/null
echo "    built build/$APP"

echo "==> stage DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

echo "==> create DMG"
hdiutil create -volname "VK Turn Proxy" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "    -> $DMG"

if [[ "${1:-}" == "install" ]]; then
  echo "==> install to /Applications"
  pkill -f "$APP/Contents/MacOS/VKTurnProxy" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP"
  cp -R "build/$APP" "/Applications/$APP"
  codesign --force --deep --sign - "/Applications/$APP" 2>/dev/null || true
  xattr -dr com.apple.quarantine "/Applications/$APP" 2>/dev/null || true
  echo "    installed /Applications/$APP"
fi
echo "==> done"
