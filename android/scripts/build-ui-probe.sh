#!/bin/sh
set -eu
SCRIPT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROBE_SERIAL=$(python3 "$SCRIPT_ROOT/emulator_serial.py" "$@")
export ANDROID_SERIAL="$PROBE_SERIAL"
PROBE_WORK=$(mktemp -d)
trap 'rm -rf "$PROBE_WORK"' EXIT
mkdir "$PROBE_WORK/classes" "$PROBE_WORK/dex"
javac -source 17 -target 17 -cp "$ANDROID_HOME/platforms/android-37.2/android.jar" -d "$PROBE_WORK/classes" "$SCRIPT_ROOT/UiHierarchy.java"
"$ANDROID_HOME/build-tools/37.0.0/d8" --lib "$ANDROID_HOME/platforms/android-37.2/android.jar" --output "$PROBE_WORK/dex" "$PROBE_WORK/classes/dev/chirp/smoke/UiHierarchy.class"
jar cf "$PROBE_WORK/probe.jar" -C "$PROBE_WORK/dex" classes.dex
adb -s "$PROBE_SERIAL" push "$PROBE_WORK/probe.jar" /data/local/tmp/chirp-ui-probe.jar >/dev/null
