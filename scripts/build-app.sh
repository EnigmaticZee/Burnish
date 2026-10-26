#!/bin/bash
# Builds build/Burnish.app from the Swift package.
#
#   scripts/build-app.sh               debug build for this Mac (uses the version in VERSION)
#   scripts/build-app.sh 0.2.0         sets VERSION to 0.2.0, then builds
#   RELEASE=1 scripts/build-app.sh     optimised universal build (Apple silicon + Intel), used for releases
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   once there's a Developer ID (see scripts/sign.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftUI's macros ship with Xcode, not the Command Line Tools, so use Xcode when it's installed.
. scripts/xcode-env.sh

if [ $# -ge 1 ]; then echo "$1" > VERSION; fi
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

CONFIG=debug
ARCH_ARGS=()
if [ "${RELEASE:-0}" = 1 ]; then
    CONFIG=release
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

echo "Building Burnish $VERSION ($BUILD), $CONFIG"
swift build -c "$CONFIG" --product BurnishApp "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}"
swift build -c "$CONFIG" --product BurnishWidget "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}"
swift build -c "$CONFIG" --product burnish "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}"
BIN_DIR="$(swift build -c "$CONFIG" --product BurnishApp "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}" --show-bin-path)"

APP=build/Burnish.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_DIR/BurnishApp" "$APP/Contents/MacOS/Burnish"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" App/Info.plist > "$APP/Contents/Info.plist"
# Assets.car is the Liquid Glass icon; AppIcon.icns is the fallback for older systems (scripts/make-icons.sh).
cp App/Assets.car App/AppIcon.icns "$APP/Contents/Resources/"
# UI text: the string catalog compiles to one .lproj per language (scripts/update-strings.sh).
xcrun xcstringstool compile App/Localizable.xcstrings --output-directory "$APP/Contents/Resources" >/dev/null
# Burnish's own release notes, for the What's New window.
cp docs/HISTORY.md "$APP/Contents/Resources/"

# The command-line tool, for Shortcuts, scripts and IT admins. Not next to the app's own
# executable: on a case-insensitive disk "burnish" and "Burnish" are the same file.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/burnish" "$APP/Contents/Helpers/burnish"

# The desktop widget, a sandboxed extension with the same text.
WIDGET="$APP/Contents/PlugIns/BurnishWidget.appex"
mkdir -p "$WIDGET/Contents/MacOS" "$WIDGET/Contents/Resources"
cp "$BIN_DIR/BurnishWidget" "$WIDGET/Contents/MacOS/BurnishWidget"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" App/Widget-Info.plist > "$WIDGET/Contents/Info.plist"
xcrun xcstringstool compile App/Localizable.xcstrings --output-directory "$WIDGET/Contents/Resources" >/dev/null

# Sparkle (Burnish's own updates), from the Swift package.
SPARKLE_FRAMEWORK="$(find .build -path '*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -maxdepth 8 -type d | head -1)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "Sparkle.framework not found under .build" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    scripts/sign.sh "$APP" "$SIGN_IDENTITY"
else
    # Ad-hoc signature with a stable requirement: macOS ties the App Management grant to the
    # designated requirement, and the default ad-hoc one (cdhash) changes on every build, which
    # would also break Sparkle's update check. Sign Sparkle's helpers inside-out, then the app.
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    for part in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app" "$APP/Contents/Frameworks/Sparkle.framework"; do
        codesign --force --sign - "$part"
    done
    codesign --force --sign - --entitlements App/Widget.entitlements "$WIDGET"
    codesign --force --sign - "$APP/Contents/Helpers/burnish"
    codesign --force --sign - --entitlements App/Burnish.entitlements \
        -r='designated => identifier "io.github.enigmaticzee.Burnish"' "$APP"
fi

echo "Built $APP $VERSION ($BUILD)"
