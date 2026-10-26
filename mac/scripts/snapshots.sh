#!/bin/sh
# Render the curated light/dark screenshots offscreen, with the same AccentColor asset as the app.
# `scripts/snapshots.sh all` renders every scenario into a temporary directory for review.
set -eu
cd "$(dirname "$0")/.."
SCRATCH=${CHIRP_MAC_SCRATCH:-.build}
swift build --scratch-path "$SCRATCH"
BIN=$(swift build --scratch-path "$SCRATCH" --show-bin-path)/ChirpMac
WORK=$(mktemp -d "${TMPDIR:-/tmp}/chirp-snapshot-app.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
APP="$WORK/Chirp Snapshots.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ChirpMac"
# Loading Assets.car from the main bundle is what makes native AppKit checkboxes koi.
ACTOOL=$(xcrun --find actool)
"$ACTOOL" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
    --accent-color AccentColor --output-partial-info-plist "$WORK/assets.plist" "$PWD/Assets.xcassets" >/dev/null
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.chirp.mac.snapshots</string>
<key>CFBundleExecutable</key><string>ChirpMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSAccentColorName</key><string>AccentColor</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
if [ "${1:-}" = "all" ]; then
    DIR=$(mktemp -d "${TMPDIR:-/tmp}/chirp-snapshots.XXXXXX")
    "$APP/Contents/MacOS/ChirpMac" --render-snapshots "$DIR"
    echo "$DIR"
    exit 0
fi
OUT="$(cd .. && pwd)/docs/screenshots/mac"
mkdir -p "$OUT"
mkdir -p "$WORK/captures"
"$APP/Contents/MacOS/ChirpMac" --render-snapshots "$WORK/captures" --curated
# Only replace the committed set after every render succeeded.
find "$OUT" -maxdepth 1 -name '*.png' -delete
cp "$WORK/captures/"*.png "$OUT/"
du -sh "$OUT"
