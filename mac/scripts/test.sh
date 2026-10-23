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
run() {
    if [ "$DEV" = "/Library/Developer/CommandLineTools" ] && [ -d "$PLUGINS" ]; then
        swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
    else
        swift test "$@"
    fi
}
# With no arguments the 2-hour Live Notes soak runs on its own after the rest: its 2-minute limit must not include
# minutes where the snapshot renderer holds the main actor.
if [ $# -eq 0 ]; then
    run --skip NotesSoakTests
    exec "$0" --skip-build --filter NotesSoakTests
fi
run "$@"
