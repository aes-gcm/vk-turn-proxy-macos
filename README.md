# VK Turn Proxy for macOS

Native SwiftUI macOS application with a Go helper for a WireGuard tunnel carried through TURN relays. This project is separate from AES128.

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

## Build on Apple Silicon

The current packaging script embeds an ARM64 helper. Requirements: macOS 13 or later, Xcode Command Line Tools with the macOS SDK and Swift compiler, and a Go toolchain compatible with `core/go.mod` (Go 1.25.5).

From the repository root:

```sh
mkdir -p bin
(
  cd core
  GOOS=darwin GOARCH=arm64 go build -o ../bin/vkturn-macos-arm64 ./cmd/vkturn-macos
)
zsh app/build.sh
```

The app is written to `app/build/VK Turn Proxy.app`. Build the Go helper first: the existing Swift build script allows a bundle without a helper if the binary is absent.

To create `dist/VK-Turn-Proxy.dmg`:

```sh
zsh app/package.sh
```

`zsh app/package.sh install` additionally replaces `/Applications/VK Turn Proxy.app`. The packaged app is ad-hoc signed, not notarized.

## Runtime data

The application obtains connection settings and VK authentication locally. Do not commit personal WireGuard configurations, private keys, VK cookies or generated connection files.

The helper is installed at `/usr/local/bin/vkturn-helper`. The application uses local Application Support directories and may install `/etc/sudoers.d/vkturn` for helper operation. Installation and connection setup can require administrator access; merely building the source does not install the helper or change system networking.

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
