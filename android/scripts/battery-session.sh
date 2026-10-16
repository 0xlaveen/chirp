#!/bin/bash
# Operator-driven run. Captures system counters only, never microphone data or text.
set -euo pipefail
N="${1:-10}"
UTTERANCE_SECONDS="${UTTERANCE_SECONDS:-10}"
NETWORK="${NETWORK:-wifi}"
CHIRP_BATTERY_OUTPUT="${CHIRP_BATTERY_OUTPUT:-$HOME/Library/Caches/Chirp/battery/$(date +%Y%m%d-%H%M%S)-$NETWORK}"
[[ "$N" =~ ^[1-9][0-9]*$ ]] || { echo 'Usage: battery-session.sh [utterance-count]'; exit 2; }
[[ "$UTTERANCE_SECONDS" =~ ^[1-9][0-9]*$ ]] || exit 2
command -v adb >/dev/null
adb get-state >/dev/null
mkdir -p "$CHIRP_BATTERY_OUTPUT"
chmod 700 "$CHIRP_BATTERY_OUTPUT"
printf 'Network: %s. Use an unplugged phone at a consistent charge and brightness.\n' "$NETWORK"
printf 'Show Chirp in a synthetic test field. Press Enter to reset counters. '
read -r _
adb shell dumpsys batterystats --reset >/dev/null
STARTED=$(date +%s)
for ((i=1;i<=N;i++)); do
    printf 'Utterance %s/%s: dictate synthetic speech for %s seconds, stop, then press Enter. ' "$i" "$N" "$UTTERANCE_SECONDS"
    read -r _
done
ELAPSED=$(( $(date +%s) - STARTED ))
adb shell dumpsys batterystats --charged dev.chirp.android > "$CHIRP_BATTERY_OUTPUT/dictation.txt"
printf 'Leave Chirp visible without recording for at least 5 minutes. Press Enter when finished. '
IDLE_STARTED=$(date +%s)
read -r _
IDLE_ELAPSED=$(( $(date +%s) - IDLE_STARTED ))
adb shell dumpsys batterystats --charged dev.chirp.android > "$CHIRP_BATTERY_OUTPUT/after-idle.txt"
if [[ "${PERFETTO:-0}" == 1 ]]; then
    printf 'Capturing a separate 120s Perfetto sample. Repeat dictation now.\n'
    adb shell perfetto -o /data/misc/perfetto-traces/chirp-battery.perfetto-trace -t 120s sched freq idle power >/dev/null
    adb pull /data/misc/perfetto-traces/chirp-battery.perfetto-trace "$CHIRP_BATTERY_OUTPUT/" >/dev/null
    adb shell rm /data/misc/perfetto-traces/chirp-battery.perfetto-trace
fi
printf '\nFor docs/bench.md (measured counters require operator review):\n'
printf '| Android %s | %s × %ss | elapsed %ss | idle %ss | mAh/min TBM |\n' "$NETWORK" "$N" "$UTTERANCE_SECONDS" "$ELAPSED" "$IDLE_ELAPSED"
printf 'Counter files: %s\n' "$CHIRP_BATTERY_OUTPUT"
printf 'Read UID dev.chirp.android estimated mAh; divide dictation mAh by %s/60 minutes.\n' "$(( N * UTTERANCE_SECONDS ))"
printf 'Idle delta = after-idle minus dictation; phone-wide radio/display cost must be reported separately.\n'
