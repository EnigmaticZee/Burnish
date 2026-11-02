#!/bin/bash
# Sends an app or disk image to Apple's notary service, waits for the verdict and staples the
# ticket, so Gatekeeper opens it without a prompt even offline.
#
#   scripts/notarize.sh build/Burnish.app     (zips it for the upload, staples the app)
#   scripts/notarize.sh dist/Burnish.dmg
#
# Credentials, in this order: an App Store Connect API key in Keys/ (app-store-connect.p8 next to
# app-store-connect.env holding KEY_ID and ISSUER_ID), or the environment variables
# APP_STORE_CONNECT_KEY (path to the .p8), APP_STORE_CONNECT_KEY_ID and APP_STORE_CONNECT_ISSUER_ID.
# Keys/ is ignored by git; nothing here prints a secret.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/xcode-env.sh

TARGET="${1:?usage: scripts/notarize.sh <Burnish.app or Burnish.dmg>}"
if [ -f Keys/app-store-connect.p8 ] && [ -f Keys/app-store-connect.env ]; then
    . Keys/app-store-connect.env
    KEY=Keys/app-store-connect.p8
else
    KEY="${APP_STORE_CONNECT_KEY:?no App Store Connect key: put app-store-connect.p8 and .env in Keys/, or set APP_STORE_CONNECT_KEY}"
    KEY_ID="${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID is not set}"
    ISSUER_ID="${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is not set}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
UPLOAD="$TARGET"
case "$TARGET" in
    *.app)
        UPLOAD="$WORK/$(basename "$TARGET" .app).zip"
        ditto -c -k --keepParent "$TARGET" "$UPLOAD"
        ;;
esac

echo "Notarising $(basename "$TARGET")…"
xcrun notarytool submit "$UPLOAD" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER_ID" --wait --timeout 30m \
    --output-format json > "$WORK/notary.json"
read -r STATUS ID < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("status", ""), d.get("id", ""))' "$WORK/notary.json")
if [ "$STATUS" != "Accepted" ]; then
    echo "Apple answered: ${STATUS:-no answer} (submission $ID). The log:" >&2
    xcrun notarytool log "$ID" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER_ID" >&2 || true
    exit 1
fi
xcrun stapler staple "$TARGET" >/dev/null
echo "Notarised and stapled $(basename "$TARGET") (submission $ID)"
