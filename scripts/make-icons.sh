#!/bin/bash
# Rebuilds every icon from the Icon Composer document App/AppIcon.icon (open it in Icon Composer to
# change the design):
#   App/Assets.car       the Liquid Glass icon macOS renders itself (light, dark, clear and tinted)
#   App/AppIcon.icns     the flat fallback for older systems, also the DMG's disk icon
#   docs/images/icon.png the icon for the README banner (scripts/make-showcase.sh)
# Needs Xcode 26 or later, which ships actool and Icon Composer.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/xcode-env.sh
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$ICTOOL" ] || { echo "Icon Composer not found; install Xcode 26 or later." >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

xcrun actool App/AppIcon.icon --compile "$TMP" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$TMP/partial.plist" >/dev/null
cp "$TMP/Assets.car" App/Assets.car

# actool's own fallback stops at 256 px, so draw the full set from Apple's renderer instead.
"$ICTOOL" App/AppIcon.icon --export-image --output-file "$TMP/render.png" --platform macOS \
    --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
swift scripts/frame-icon.swift "$TMP/render.png" "$TMP/icon-1024.png"
mkdir -p "$TMP/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o App/AppIcon.icns

mkdir -p docs/images
sips -Z 512 "$TMP/icon-1024.png" --out docs/images/icon.png >/dev/null
echo "Icons written to App/Assets.car, App/AppIcon.icns and docs/images/icon.png"
