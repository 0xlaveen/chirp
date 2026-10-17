#!/bin/sh
# Release validation is deliberately separate from debug synthetic speech E2E.
set -eu
if [ "${ANDROID_SERIAL:-emulator-5580}" != emulator-5580 ]; then
    echo 'Only emulator-5580 is authorized' >&2
    exit 1
fi
export ANDROID_SERIAL=emulator-5580
ANDROID_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ANDROID_ROOT"
./gradlew assembleRelease
scripts/build-ui-probe.sh
python3 scripts/emulator-smoke.py
