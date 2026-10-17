#!/bin/sh
# Regenerates the built-in sound packs into a temporary folder and checks they match the committed Assets/Sounds
# (the generator is deterministic), then prints each cue's duration, peak and loudness.
set -eu
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift scripts/make-sounds.swift --out "$TMP" --report
for f in "$TMP"/*.wav; do
    cmp "$f" "Assets/Sounds/$(basename "$f")" || { echo "Assets/Sounds/$(basename "$f") is stale: run swift scripts/make-sounds.swift" >&2; exit 1; }
done
echo "Assets/Sounds matches the generator."
