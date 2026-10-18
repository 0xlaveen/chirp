#!/bin/sh
set -eu
dev="$(xcode-select -p)"
case "$dev" in
  */CommandLineTools) echo 'BLOCKED: select a full Xcode installation with an iOS Simulator SDK.' >&2; exit 2 ;;
esac
xcrun --sdk iphonesimulator --show-sdk-path
xcodebuild -version
xcrun simctl list devices available
