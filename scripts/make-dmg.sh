#!/bin/bash
# Builds the universal Burnish.app and packs it into dist/Burnish.dmg: a drag-to-Applications
# window with background art and Burnish's icon as the disk icon.
# Needs dmgbuild (pip install dmgbuild); it writes the Finder layout directly, so no Finder or GUI.
set -euo pipefail
cd "$(dirname "$0")/.."

RELEASE=1 scripts/build-app.sh "$@"

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
rm -f dist/Burnish.dmg
"$DMGBUILD" -s scripts/dmg-settings.py \
    -D app=build/Burnish.app -D background="$BACKGROUND" -D volume_icon=App/AppIcon.icns \
    "Burnish" dist/Burnish.dmg >/dev/null
echo "Packed dist/Burnish.dmg"
