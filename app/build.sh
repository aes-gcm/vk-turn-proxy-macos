#!/bin/zsh
# Build both GUI and helper from source; never reuse a stale helper binary.
set -euo pipefail
cd "$(dirname "$0")"
APP="VK Turn Proxy.app"
OUT="build/$APP"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
mkdir -p build
WORK=$(mktemp -d "$PWD/build/compile.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$APP/Contents/MacOS" "$WORK/$APP/Contents/Resources"
cp Info.plist "$WORK/$APP/Contents/Info.plist"
for arch in arm64 x86_64; do
  goarch=$arch
  [[ "$arch" == x86_64 ]] && goarch=amd64
  echo "==> Go helper: $arch"
  (cd ../core && CGO_ENABLED=0 GOOS=darwin GOARCH=$goarch go build -mod=readonly -trimpath -o "$WORK/helper-$arch" ./cmd/vkturn-macos)
  echo "==> Swift UI: $arch"
  swiftc -sdk "$SDK" -target "$arch-apple-macos13.0" -swift-version 5 -parse-as-library -O \
    -framework SwiftUI -framework AppKit -framework WebKit -framework Foundation \
    -o "$WORK/gui-$arch" Sources/*.swift
 done
lipo -create "$WORK/gui-arm64" "$WORK/gui-x86_64" -output "$WORK/$APP/Contents/MacOS/VKTurnProxy"
lipo -create "$WORK/helper-arm64" "$WORK/helper-x86_64" -output "$WORK/$APP/Contents/Resources/vkturn-macos"
ICON_SOURCE="../core/VKTurnProxy/VKTurnProxy/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
mkdir "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_SOURCE" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$ICON_SOURCE" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
 done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$WORK/$APP/Contents/Resources/vkturn-macos"
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$WORK/$APP"
codesign --verify --deep --strict "$WORK/$APP"
"$WORK/$APP/Contents/Resources/vkturn-macos" -check
# Replace the generated bundle only after a complete, verified build.
rm -rf "$OUT"
mv "$WORK/$APP" "$OUT"
echo "==> Built universal app: $OUT"
