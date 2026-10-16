#!/bin/sh
# Copies build/Chirp.app to ~/Applications/Chirp.app (run bundle.sh first). Does not launch it
# and does not register a login item; use the app's "Launch at Login" for that.
set -eu
cd "$(dirname "$0")/.."
[ -d build/Chirp.app ] || { echo "build/Chirp.app missing: run scripts/bundle.sh first" >&2; exit 1; }
mkdir -p "$HOME/Applications"
# Quit a running copy so the files can be replaced.
pkill -x ChirpMac 2>/dev/null || true
rm -rf "$HOME/Applications/Chirp.app"
ditto build/Chirp.app "$HOME/Applications/Chirp.app"
echo "Installed ~/Applications/Chirp.app. Start it with: open ~/Applications/Chirp.app"
