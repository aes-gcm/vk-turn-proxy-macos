#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc Sources/InstallerCommands.swift tests/main.swift -o "$WORK/installer-tests"
"$WORK/installer-tests"
