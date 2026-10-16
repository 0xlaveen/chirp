#!/bin/sh
# Builds mac/build/Chirp.app (LSUIElement menu-bar app) with SwiftPM and signs it.
# Needs only the Command Line Tools, no Xcode.
set -eu
cd "$(dirname "$0")/.."

IDENTITY="Chirp Local Dev"
APP="build/Chirp.app"

swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ChirpMac" "$APP/Contents/MacOS/ChirpMac"
# Copy any SwiftPM resource bundles; they are looked up in Contents/Resources.
for b in "$BIN"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.chirp.mac</string>
    <key>CFBundleName</key><string>Chirp</string>
    <key>CFBundleDisplayName</key><string>Chirp</string>
    <key>CFBundleExecutable</key><string>ChirpMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Chirp streams your voice to your own speech server to type what you say. Audio is not stored.</string>
</dict>
</plist>
PLIST

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --options runtime --entitlements scripts/Chirp.entitlements --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\"."
else
    codesign --force --options runtime --entitlements scripts/Chirp.entitlements --sign - "$APP"
    echo "WARNING: identity \"$IDENTITY\" not found, signed ad-hoc." >&2
    echo "         macOS will forget the Microphone/Accessibility grants on every rebuild." >&2
    echo "         Run scripts/make-cert.sh once to fix that." >&2
fi
codesign --verify --strict "$APP" && echo "Built $APP"
