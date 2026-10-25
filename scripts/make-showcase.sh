#!/bin/bash
# Redraws the README banner (docs/images/showcase.png and showcase-dark.png) from the app's own
# screens, filled with sample apps so no real app list ends up in the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ] && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
scripts/build-app.sh >/dev/null
build/Burnish.app/Contents/MacOS/Burnish --render-previews "$TMP/screens" --demo
swift scripts/make-showcase.swift "$TMP/screens" docs/images/icon.png docs/images
echo "Banner written to docs/images/showcase.png and showcase-dark.png"
