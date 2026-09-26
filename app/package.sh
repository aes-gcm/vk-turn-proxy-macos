#!/bin/zsh
# Versioned PKG + DMG + checksums; never installs on the build Mac.
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# -ne 0 ]]; then
  echo 'Usage: zsh app/package.sh (builds installers only)' >&2
  exit 2
fi
./build.sh
APP="VK Turn Proxy.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
DIST="$PWD/../dist"
NAME="VK-Turn-Proxy-${VERSION}-macOS-universal"
mkdir -p "$DIST"
WORK=$(mktemp -d "$PWD/build/package.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" "$WORK/dmg"
ditto "build/$APP" "$WORK/root/Applications/$APP"
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist"
python3 - "$WORK/components.plist" <<'PY'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: components=plistlib.load(f)
for c in components:
    c['BundleIsRelocatable']=False
    c['BundleIsVersionChecked']=True
    c['BundleOverwriteAction']='upgrade'
with open(p,'wb') as f: plistlib.dump(components,f)
PY
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
  --identifier com.vkturn.macos.installer --version "$VERSION" \
  --install-location / --ownership recommended "$WORK/component.pkg"
python3 - "$WORK/Distribution.xml" "$VERSION" <<'PY'
import sys
from xml.sax.saxutils import escape
version=escape(sys.argv[2])
text=f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
<title>VK Turn Proxy {version}</title>
<welcome file="Welcome.html" mime-type="text/html"/>
<readme file="ReadMe.html" mime-type="text/html"/>
<license file="LICENSE.txt" mime-type="text/plain"/>
<options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
<domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
<allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
<choices-outline><line choice="app"/></choices-outline>
<choice id="app" visible="false" title="VK Turn Proxy"><pkg-ref id="com.vkturn.macos.installer"/></choice>
<pkg-ref id="com.vkturn.macos.installer" version="{version}" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
'''
open(sys.argv[1],'w').write(text)
PY
mkdir "$WORK/resources"
cp installer/Welcome.html installer/ReadMe.html "$WORK/resources/"
cp ../LICENSE "$WORK/resources/LICENSE.txt"
productbuild --distribution "$WORK/Distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$WORK/$NAME.pkg"
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  productsign --sign "$INSTALLER_SIGN_IDENTITY" "$WORK/$NAME.pkg" "$DIST/$NAME.pkg"
else
  cp "$WORK/$NAME.pkg" "$DIST/$NAME.pkg"
fi
ditto "build/$APP" "$WORK/dmg/$APP"
ln -s /Applications "$WORK/dmg/Applications"
cp installer/INSTALL-RU.txt "$WORK/dmg/Установка.txt"
cp ../LICENSE "$WORK/dmg/LICENSE.txt"
cp "$DIST/$NAME.pkg" "$WORK/dmg/$NAME.pkg"
hdiutil create -volname "VK Turn Proxy $VERSION" -srcfolder "$WORK/dmg" -ov -format UDZO "$DIST/$NAME.dmg"
(cd "$DIST" && shasum -a 256 "$NAME.pkg" "$NAME.dmg" > "$NAME-SHA256SUMS.txt")
echo "==> Installers: $DIST/$NAME.{pkg,dmg}"
