#!/bin/bash
# Live Notes call audio (#211) end to end: a synthetic meeting through `ChirpMac --call-selftest` against a throwaway
# chirp-server (temporary HOME and token, port 7898). Two `say` voices (Samantha and Daniel) are the "remote" side of
# a call; a third (Karen) is the microphone. Both sides must be transcribed, the microphone labelled "You" and at
# least two remote speakers told apart, each side's words under its own label. Never the running app, its
# preferences or port 7821.
#
# By default the remote track reaches the app through a file-backed tap (no Screen & System Audio Recording
# permission needed, so it runs anywhere). --live plays it through the speakers with afplay and records it with the
# real Core Audio process tap instead: run that on a Mac where Chirp's binary is allowed to record system audio.
#
# It needs the on-device speaker model already on this Mac (turn on Label speakers once); it never downloads it.
# CHIRP_MAC_SCRATCH builds outside the checkout (a checkout under ~/Documents can hang on TCC).
# Usage: mac/scripts/call-audio-selftest.sh [--real-time] [--live] [--keep]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PORT=${CHIRP_CALL_SELFTEST_PORT:-7898}
MODEL_DIR=${CHIRP_MODEL_DIR:-$HOME/.koi/voice-models/parakeet-mlx}
PACE=--fast; LIVE=; KEEP=
while [ $# -gt 0 ]; do
  case $1 in --real-time) PACE= ;; --live) LIVE=--live; PACE= ;; --keep) KEEP=1 ;; *) echo "unknown arg $1" >&2; exit 64 ;; esac
  shift
done
[ "$PORT" = 7821 ] && { echo "refusing port 7821 (the app's server)" >&2; exit 64; }
if curl -s -m 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
  echo "port $PORT is in use; set CHIRP_CALL_SELFTEST_PORT" >&2; exit 1
fi

WORK=$(mktemp -d /tmp/chirp-call-selftest.XXXX)
echo "work dir (synthetic audio, throwaway token, server log): $WORK"
# Nine turns, 0.8 s apart: R = the call (two voices), M = the microphone. Each track is silent while the other talks.
i=0
while IFS='|' read -r side voice line; do
  say -v "$voice" -r 170 -o "$WORK/turn$i.aiff" "$line"
  ffmpeg -loglevel error -i "$WORK/turn$i.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/turn$i.wav"
  echo "$side" > "$WORK/turn$i.side"
  i=$((i + 1))
done <<'TURNS'
R|Samantha|Good morning everyone. Let's start with the budget for the next quarter.
R|Daniel|Thanks. The budget stays as it is, but marketing wants a little more for the launch.
M|Karen|I can draft the marketing proposal and share the spreadsheet on Friday.
R|Samantha|Great. Next item is the vendor contract. It still needs a second review.
R|Daniel|I read the contract last night. The payment terms look fine, but the support clause is weak.
M|Karen|Then I will ask legal about the warranty before anyone signs.
R|Samantha|Last thing, the launch date. Are we still on track for the end of the month?
R|Daniel|Yes, unless the load test fails again. We run it on Monday.
M|Karen|Perfect. Let's meet again on Tuesday to check the results.
TURNS
python3 -I - "$WORK" "$i" <<'PY'
import sys, wave
work, n = sys.argv[1], int(sys.argv[2])
gap = b"\0\0" * int(16000 * 0.8)
tracks = {"R": [], "M": []}
for k in range(n):
    side = open(f"{work}/turn{k}.side").read().strip()
    with wave.open(f"{work}/turn{k}.wav") as w:
        pcm = w.readframes(w.getnframes())
    for name, parts in tracks.items():
        parts.append((pcm if name == side else b"\0" * len(pcm)) + gap)
for name, out in (("R", "remote.wav"), ("M", "mic.wav")):
    with wave.open(f"{work}/{out}", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(b"".join(tracks[name]))
PY

cd "$ROOT/server"
uv sync --locked -q
HOME="$WORK" UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}" \
  uv run chirp-server --port "$PORT" --model-dir "$MODEL_DIR" > "$WORK/server.log" 2>&1 &
SERVER=$!
cleanup() { kill "$SERVER" 2>/dev/null || true; pkill -P "$SERVER" 2>/dev/null || true; [ -n "$KEEP" ] || rm -rf "$WORK"; }
trap cleanup EXIT
for _ in $(seq 1 120); do curl -s -m 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 && break; sleep 1; done
TOKEN="$WORK/.config/chirp/token"
[ -s "$TOKEN" ] || { echo "server did not start; see $WORK/server.log" >&2; KEEP=1; exit 1; }

BUILD=(swift build --package-path "$ROOT/mac")
[ -n "${CHIRP_MAC_SCRATCH:-}" ] && BUILD+=(--scratch-path "$CHIRP_MAC_SCRATCH")
"${BUILD[@]}" 2>&1 | grep -E "error|Build complete" | tail -1
MAC=$("${BUILD[@]}" --show-bin-path)/ChirpMac
fail=0
echo "== call-selftest ${LIVE:-(file tap)} ${PACE:-(real time)}"
"$MAC" --call-selftest --mic "$WORK/mic.wav" --remote "$WORK/remote.wav" --url "http://127.0.0.1:$PORT" --token-file "$TOKEN" \
  $PACE $LIVE --remote-speakers 2 --expect-mic spreadsheet --expect-mic warranty --expect-remote budget --expect-remote vendor \
  --snapshot "$WORK/snapshots" || fail=1

echo "== privacy: transcript words in server log (expect 0)"
hits=$(grep -c -i -E "budget|vendor|spreadsheet|warranty" "$WORK/server.log" || true)
echo "$hits"; [ "$hits" = 0 ] || fail=1
[ $fail = 0 ] && echo "CALL AUDIO SELFTEST: PASS" || { echo "CALL AUDIO SELFTEST: FAIL (work dir kept: $WORK)"; KEEP=1; exit 1; }
