#!/bin/bash
# Signs Burnish.app with a Developer ID and the hardened runtime, inside out, the way
# Sparkle's documentation describes for apps that embed it.
#
#   scripts/sign.sh build/Burnish.app "Developer ID Application: Your Name (TEAMID)"
set -euo pipefail
APP="$1"
IDENTITY="$2"
ENTITLEMENTS="$(dirname "$0")/../App/Burnish.entitlements"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }

if [ -d "$SPARKLE" ]; then
    sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Versions/B/Autoupdate"
    sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
fi
WIDGET="$APP/Contents/PlugIns/BurnishWidget.appex"
[ -d "$WIDGET" ] && sign --entitlements "$(dirname "$0")/../App/Widget.entitlements" "$WIDGET"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed $APP as $IDENTITY"
