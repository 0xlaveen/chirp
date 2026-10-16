#!/bin/sh
# Runs the unit tests. Under the Command Line Tools SwiftPM does not find the Swift Testing macro
# plugin by itself, so point the compiler at it; with a full Xcode toolchain plain `swift test` works.
set -eu
cd "$(dirname "$0")/.."
DEV=$(xcode-select -p)
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
if [ "$DEV" = "/Library/Developer/CommandLineTools" ] && [ -d "$PLUGINS" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
