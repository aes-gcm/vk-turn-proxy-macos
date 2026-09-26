#!/bin/zsh
# Builds VK Turn Proxy.app from Sources/*.swift into ./build, ad-hoc signed.
# No Xcode project — hand-assembled bundle. macOS 13+ deployment.
set -euo pipefail
cd "$(dirname "$0")"

APP="VK Turn Proxy.app"
OUT="build/$APP"
EXE="VKTurnProxy"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"

echo "==> clean"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "==> Info.plist"
cp Info.plist "$OUT/Contents/Info.plist"

echo "==> bundle helper binary (if built)"
if [[ -f "../bin/vkturn-macos-arm64" ]]; then
  cp "../bin/vkturn-macos-arm64" "$OUT/Contents/Resources/vkturn-macos"
  chmod +x "$OUT/Contents/Resources/vkturn-macos"
  echo "    embedded core helper"
else
  echo "    (helper ../bin/vkturn-macos-arm64 not found — skipping embed)"
fi

echo "==> compile Swift ($TARGET)"
swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -framework SwiftUI -framework AppKit -framework WebKit -framework Foundation \
  -o "$OUT/Contents/MacOS/$EXE" \
  Sources/*.swift

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$OUT" 2>&1 | sed 's/^/    /'

echo "==> done: $OUT"
