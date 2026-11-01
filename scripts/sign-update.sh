#!/bin/bash
# Signs an update (DMG) with Burnish's Sparkle key and prints the enclosure attributes for the
# appcast. The key is read from Keys/sparkle-burnish.key when the folder travels with the project,
# or from this Mac's Keychain (account "burnish") otherwise. Keys/ is ignored by git.
#
#   scripts/sign-update.sh dist/Burnish.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

FILE="${1:?usage: scripts/sign-update.sh <file>}"
KEY=Keys/sparkle-burnish.key
if [ -f "$KEY" ]; then
    Vendor/Sparkle/bin/sign_update --ed-key-file "$KEY" "$FILE"
else
    Vendor/Sparkle/bin/sign_update --account burnish "$FILE"
fi
