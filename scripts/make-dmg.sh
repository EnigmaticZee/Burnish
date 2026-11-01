#!/bin/bash
# Builds the universal Burnish.app and packs it into dist/Burnish.dmg: a drag-to-Applications
# window with background art and Burnish's icon as the disk icon.
# Needs dmgbuild (pip install dmgbuild); it writes the Finder layout directly, so no Finder or GUI.
#
# With SIGN_IDENTITY set ("Developer ID Application: …"), the app is signed with it and the
# hardened runtime (scripts/sign.sh) and so is the DMG. When Apple's notary credentials are there
# too (Keys/app-store-connect.*, or the APP_STORE_CONNECT_* variables), both are notarised and
# stapled; NOTARIZE=0 skips that, NOTARIZE=1 insists on it.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=1 scripts/build-app.sh "$@"

NOTARIZE="${NOTARIZE:-auto}"
if [ "$NOTARIZE" = auto ]; then
    if [ -n "${SIGN_IDENTITY:-}" ] && { [ -f Keys/app-store-connect.p8 ] || [ -n "${APP_STORE_CONNECT_KEY:-}" ]; }; then
        NOTARIZE=1
    else
        NOTARIZE=0
    fi
fi
[ "$NOTARIZE" = 1 ] && scripts/notarize.sh build/Burnish.app

DMGBUILD=${DMGBUILD:-dmgbuild}
command -v "$DMGBUILD" >/dev/null || { echo "dmgbuild not found: pip install dmgbuild" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BACKGROUND=""
if [ -f App/dmg-background.png ] && [ -f App/dmg-background@2x.png ]; then
    # Retina background: one TIFF holding the 1x and 2x art.
    tiffutil -cathidpicheck App/dmg-background.png App/dmg-background@2x.png -out "$WORK/background.tiff" >/dev/null
    BACKGROUND="$WORK/background.tiff"
fi

mkdir -p dist
rm -f dist/Burnish.dmg dist/notarised
"$DMGBUILD" -s scripts/dmg-settings.py \
    -D app=build/Burnish.app -D background="$BACKGROUND" -D volume_icon=App/AppIcon.icns \
    "Burnish" dist/Burnish.dmg >/dev/null
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" dist/Burnish.dmg
fi
if [ "$NOTARIZE" = 1 ]; then
    scripts/notarize.sh dist/Burnish.dmg
    # The release notes read this to drop the "Open Anyway" paragraph.
    touch dist/notarised
fi
echo "Packed dist/Burnish.dmg$([ "$NOTARIZE" = 1 ] && echo ', notarised')"
