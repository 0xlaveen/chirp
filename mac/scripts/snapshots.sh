#!/bin/sh
# Refreshes the committed screenshots in docs/screenshots/mac: renders the curated set (Snapshots.committedNames:
# key HUD states, the menu, one per Settings tab, setup) and deletes every other PNG there. Drawing is offscreen only;
# it never starts the app, asks for a permission or touches the installed one.
#
#   scripts/snapshots.sh        curated set -> docs/screenshots/mac
#   scripts/snapshots.sh all    everything (~150 PNGs) -> a new temporary directory, for review
set -eu
cd "$(dirname "$0")/.."
swift build -q 2>&1 | grep -E 'error' || true
BIN=$(swift build --show-bin-path)/ChirpMac
if [ "${1:-}" = "all" ]; then
    DIR=$(mktemp -d "${TMPDIR:-/tmp}/chirp-snapshots.XXXXXX")
    "$BIN" --render-snapshots "$DIR"
    echo "$DIR"
    exit 0
fi
OUT="$(cd .. && pwd)/docs/screenshots/mac"
mkdir -p "$OUT"
find "$OUT" -maxdepth 1 -name '*.png' -delete
"$BIN" --render-snapshots "$OUT" --curated
du -sh "$OUT"
