#!/bin/sh
# Runs the unit tests. Under the Command Line Tools SwiftPM does not find the Swift Testing macro
# plugin by itself, so point the compiler at it; with a full Xcode toolchain plain `swift test` works.
set -eu
cd "$(dirname "$0")/.."
# The app must build with the Command Line Tools, which ship no SwiftUI macro plugins: keep view state in
# @Observable models instead of these property wrappers.
if grep -rnE '^[[:space:]]*@(State|FocusState|Entry|Previewable)\b' Sources; then
    echo "error: SwiftUI macro property wrappers break the Command Line Tools build" >&2
    exit 1
fi
DEV=$(xcode-select -p)
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
if [ "$DEV" = "/Library/Developer/CommandLineTools" ] && [ -d "$PLUGINS" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
