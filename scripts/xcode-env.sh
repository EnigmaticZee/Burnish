# Sourced by the build scripts: use Xcode's toolchain when it's installed but not selected.
# SwiftUI's macros, actool, xcstringstool and Icon Composer ship with Xcode, not the Command
# Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ] && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
