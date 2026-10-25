#!/bin/bash
# Runs the test suite. Prefers Xcode's toolchain when it's installed but not selected;
# with only the Command Line Tools, points SwiftPM at the Swift Testing macro plugin.
set -euo pipefail
cd "$(dirname "$0")/.."

args=()
if ! xcodebuild -version >/dev/null 2>&1; then
    if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        plugin_dir="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
        [ -d "$plugin_dir" ] && args+=(-Xswiftc -plugin-path -Xswiftc "$plugin_dir")
    fi
fi

swift test "${args[@]+"${args[@]}"}" "$@"
