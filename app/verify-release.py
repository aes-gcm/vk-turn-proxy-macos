"""Inspect installers without installing anything or changing live networking."""
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
APP = 'VK Turn Proxy.app'
VERSION = plistlib.loads((ROOT/'app/Info.plist').read_bytes())['CFBundleShortVersionString']
NAME = f'VK-Turn-Proxy-{VERSION}-macOS-universal'
DIST = ROOT/'dist'


def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle(path):
    info = plistlib.loads((path/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'com.vkturn.macos'
    assert info['CFBundleShortVersionString'] == VERSION
    assert info['LSMinimumSystemVersion'] == '13.0'
    run('codesign', '--verify', '--deep', '--strict', path)
    signatures = {}
    for item in ['MacOS/VKTurnProxy', 'Resources/vkturn-macos']:
        file = path/'Contents'/item
        assert set(run('lipo', '-archs', file).decode().split()) == {'arm64', 'x86_64'}
        signatures[item] = digest(file)
    # This helper flag exits before reading config, installing or touching networking.
    assert run(path/'Contents/Resources/vkturn-macos', '-check').strip() == b'ok'
    assert (path/'Contents/Resources/AppIcon.icns').is_file()
    for file in path.rglob('*'):
        assert file.name not in {'config.json', 'core.log', '.env', '.DS_Store'}
        assert file.suffix not in {'.key', '.pem', '.conf', '.p12'}
    return signatures


expected = bundle(ROOT/'app/build'/APP)
checksums = {}
for line in (DIST/f'{NAME}-SHA256SUMS.txt').read_text().splitlines():
    sha, name = line.split(maxsplit=1)
    name = name.strip()
    assert name in {f'{NAME}.pkg', f'{NAME}.dmg'}
    assert digest(DIST/name) == sha
    checksums[name] = sha
assert len(checksums) == 2

with tempfile.TemporaryDirectory(prefix='vkturn-release-check-') as tmp:
    tmp = Path(tmp)
    expanded = tmp/'pkg'
    run('pkgutil', '--expand-full', DIST/f'{NAME}.pkg', expanded)
    distribution = ET.parse(expanded/'Distribution').getroot()
    assert distribution.find('allowed-os-versions/os-version').get('min') == '13.0'
    options = distribution.find('options')
    assert options.get('hostArchitectures') == 'arm64,x86_64'
    assert distribution.find('domains').get('enable_currentUserHome') == 'false'
    info = ET.parse(expanded/'component.pkg/PackageInfo').getroot()
    assert info.get('install-location') == '/'
    assert info.get('relocatable') == 'false'
    assert info.get('version') == VERSION
    payload = expanded/'component.pkg/Payload'
    assert {p.name for p in payload.iterdir()} == {'Applications'}
    assert {p.name for p in (payload/'Applications').iterdir()} == {APP}
    assert not (expanded/'component.pkg/Scripts').exists()
    assert bundle(payload/'Applications'/APP) == expected
    instructions = (expanded/'Resources/ReadMe.html').read_text()
    assert 'https://github.com/cacggghp/vk-turn-proxy' in instructions
    assert 'https://github.com/anton48/vk-turn-proxy-ios' in instructions
    # Installer can evaluate the package on this OS without running an install.
    run('/usr/sbin/installer', '-showChoicesXML', '-pkg', DIST/f'{NAME}.pkg', '-target', '/')
    mount = tmp/'mounted'
    mounted = False
    try:
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount,
            DIST/f'{NAME}.dmg')
        mounted = True
        assert bundle(mount/APP) == expected
        assert os.readlink(mount/'Applications') == '/Applications'
        assert digest(mount/f'{NAME}.pkg') == checksums[f'{NAME}.pkg']
        assert (mount/'Установка.txt').is_file()
        assert (mount/'LICENSE.txt').is_file()
    finally:
        if mounted:
            run('hdiutil', 'detach', mount)

print('PASS: PKG/DMG payloads, universal architectures, signatures, helper startup, '
      'Installer evaluation, minimum OS, checksums and credits')
