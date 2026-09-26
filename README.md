# VK Turn Proxy for macOS

Native SwiftUI macOS application with a Go helper for a WireGuard tunnel carried through TURN relays. This project is separate from AES128.

## Download and install

Download the `.pkg` installer or `.dmg` from [GitHub Releases](https://github.com/aes-gcm/vk-turn-proxy-macos/releases/latest). Both include the app and its Go helper for Apple Silicon and Intel, and require macOS 13 or newer. No developer tools are needed to use the app.

1. Disconnect and quit any previous VK Turn Proxy before updating.
2. Run the `.pkg` installer, or open the `.dmg` and drag the app to Applications.
3. Open **VK Turn Proxy** from Applications. Use its menu-bar icon → **Открыть окно…** to open the main window.
4. Import your own server profile, sign in to VK and provide a call link. The first connection requests administrator authorization to install the network helper.

The installers do not include server access, personal profiles, keys or VK sessions. Existing settings are preserved when updating. The installer does not connect automatically.

The current release is ad-hoc signed and **not notarized by Apple**; the PKG has no Developer ID Installer signature. If macOS blocks it, follow [Apple's per-app Open Anyway instructions](https://support.apple.com/en-us/102445) in System Settings → Privacy & Security after attempting to open the installer/app. Do not disable Gatekeeper globally.

The release includes `SHA256SUMS.txt` (with the versioned filename prefix) for checking downloaded assets. Architecture inclusion is verified during packaging; testing on a physical Intel Mac is separate from cross-compilation.

## Layout

- `app/Sources/` — macOS interface, VK authentication, connection settings and helper management.
- `app/Info.plist` — bundle metadata (`com.vkturn.macos`).
- `app/build.sh` — builds and ad-hoc signs `VK Turn Proxy.app`.
- `app/package.sh` — builds a DMG, with an optional explicit installation step.
- `core/cmd/vkturn-macos/` — macOS command-line helper.
- `core/pkg/` — proxy, TURN binding and related Go packages.
- `core/third_party/` — local dependency fork required by `core/go.mod`.
- `core/VKTurnProxy/` and `core/WireGuardBridge/` — retained iOS application and bridge sources from the underlying project.
- `core/docs/` and `core/README.md` — inherited documentation, primarily for iOS.

## Build from source

Requirements: macOS 13 or later, Xcode Command Line Tools with the macOS SDK and Swift compiler, Python 3 for packaging, and a Go toolchain compatible with `core/go.mod` (Go 1.25.5).

From the repository root:

```sh
zsh app/build.sh
```

The app is written to `app/build/VK Turn Proxy.app`. The script rebuilds both GUI and helper for `arm64` and `x86_64`, combines them into universal executables, adds the project icon, signs the bundle and verifies it. A missing helper or failed architecture build stops packaging.

To rebuild and create versioned PKG, DMG and SHA-256 checksums under `dist/`:

```sh
zsh app/package.sh
```

Packaging does not replace the app installed on the build Mac. The optional `SIGN_IDENTITY` and `INSTALLER_SIGN_IDENTITY` environment variables select existing application/installer signing identities; notarization is a separate release step when Developer ID credentials are available.

Validation commands:

```sh
zsh app/test.sh
bash core/tools/test.sh
python3 app/verify-release.py
```

## Runtime data

The application obtains connection settings and VK authentication locally. Do not commit personal WireGuard configurations, private keys, VK cookies or generated connection files.

The helper is installed under the root-owned `/Library/PrivilegedHelperTools/com.vkturn.macos.helper`. The application uses local Application Support directories and installs `/etc/sudoers.d/vkturn` for the current user's helper operation, after validating the rule with `visudo`. The old helper path was `/usr/local/bin/vkturn-helper`; updating the rule removes the old path's authorization. Installation and connection setup can require administrator access; merely building the source does not install the helper or change system networking.

## Import provenance

Imported from the existing local `vkturn-macos` project on 2026-09-26. Before import, both the GUI executable and bundled Go helper in its local build matched the corresponding files in the installed `/Applications/VK Turn Proxy.app` by SHA-256. This comparison identifies the local build; it does not prove a fresh rebuild will be byte-for-byte identical.

An independently installed application named `vk-turn-proxy.app` has a different bundle identifier and is not part of this import. Existing build artifacts, DMGs and user runtime data are excluded from Git. No end-to-end network connection test was performed as part of the source import.

## Acknowledgements

Thank you to the authors and contributors of these projects, whose work helped make this macOS application possible:

- [cacggghp/vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy)
- [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios)

Both repositories helped with the development of VK Turn Proxy for macOS. Thank you for sharing your work with the community!

## License and upstream

The underlying project identifies itself as a GPL-3.0 derivative of [cacggghp/vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy), with iOS work documented in [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios). Existing notices, the [GPL license](LICENSE), source headers and dependency licenses are retained. See [core/README.md](core/README.md) for inherited attribution and licensing details.
