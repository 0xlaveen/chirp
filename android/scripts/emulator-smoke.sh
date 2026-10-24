#!/bin/sh
# Release validation is deliberately separate from debug synthetic speech E2E.
set -eu
ANDROID_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ANDROID_SERIAL=$(python3 "$ANDROID_ROOT/scripts/emulator_serial.py" "$@")
export ANDROID_SERIAL
cd "$ANDROID_ROOT"
./gradlew assembleRelease
scripts/build-ui-probe.sh
python3 scripts/emulator-smoke.py
