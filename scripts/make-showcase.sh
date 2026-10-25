#!/bin/bash
# Redraws the README banner (docs/images/showcase*.png) and the website's images (site/assets) from
# the app's own screens, filled with sample apps so no real app list ends up in the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/xcode-env.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
scripts/build-app.sh >/dev/null
build/Burnish.app/Contents/MacOS/Burnish --render-previews "$TMP/screens" --demo
mkdir -p "$TMP/out"
swift scripts/make-showcase.swift "$TMP/screens" docs/images/icon.png "$TMP/out"
cp "$TMP/out/showcase.png" "$TMP/out/showcase-dark.png" docs/images/
# The website gets a lighter JPEG of the windows alone, the social preview, and the icon.
for v in "" "-dark"; do
    sips -s format jpeg -s formatOptions 82 --resampleWidth 1600 "$TMP/out/site-showcase$v.png" --out "site/assets/showcase$v.jpg" >/dev/null
done
cp "$TMP/out/social-preview.png" site/assets/
sips -z 64 64 docs/images/icon.png --out site/assets/icon-64.png >/dev/null
sips -z 256 256 docs/images/icon.png --out site/assets/icon-256.png >/dev/null
echo "Images written to docs/images and site/assets"
