#!/bin/bash
# Refreshes App/Localizable.xcstrings from the source: every Text, Button, Label and
# String(localized:) the app shows. Run it after changing user-visible text, and commit the
# catalog with the change. Translations live in the same file (Xcode opens it); the build
# compiles it into the app. The `burnish` command-line tool stays in English.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/xcode-env.sh
CATALOG=App/Localizable.xcstrings
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A separate build folder, so the extra compiler flag doesn't invalidate the normal build.
if ! swift build --product BurnishApp --scratch-path .build/strings \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$TMP" >"$TMP/build.log" 2>&1; then
    cat "$TMP/build.log" >&2
    exit 1
fi
[ -f "$CATALOG" ] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$TMP"/*.stringsdata
echo "$(xcrun xcstringstool print "$CATALOG" | grep -c .) strings in $CATALOG"
