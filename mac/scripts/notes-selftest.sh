#!/bin/bash
# Live Notes smoke test: a `say` recording through `ChirpMac --notes-selftest` against a throwaway chirp-server
# (temporary HOME and token, port 7899), once clean and once with a dropped socket. Never the running app, its
# preferences or port 7821. Usage: mac/scripts/notes-selftest.sh [--real-time] [--fault PLAN] [--speakers]
#
# --speakers adds a third run: a ~60 s two-voice meeting (macOS `say` voices Samantha and Daniel taking turns) with
# Label speakers left at its default (on, which proves the default), through the notes library, which must come back
# as exactly two people, with a rename of Person 2 reaching every turn, the export and the structuring transcript.
# It needs the on-device speaker model already on this Mac (record once with Label speakers on); it never downloads it.
# CHIRP_MAC_SCRATCH builds outside the checkout (a checkout under ~/Documents can hang on TCC).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PORT=${CHIRP_NOTES_SELFTEST_PORT:-7899}
MODEL_DIR=${CHIRP_MODEL_DIR:-$HOME/.koi/voice-models/parakeet-mlx}
PACE=--fast; FAULT=drop@14; SPEAKERS=
while [ $# -gt 0 ]; do
  case $1 in --real-time) PACE= ;; --fault) FAULT=$2; shift ;; --speakers) SPEAKERS=1 ;; *) echo "unknown arg $1" >&2; exit 64 ;; esac
  shift
done
[ "$PORT" = 7821 ] && { echo "refusing port 7821 (the app's server)" >&2; exit 64; }
if curl -s -m 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1; then
  echo "port $PORT is in use; set CHIRP_NOTES_SELFTEST_PORT" >&2; exit 1
fi

WORK=$(mktemp -d /tmp/chirp-notes-selftest.XXXX)
echo "work dir (synthetic audio, throwaway token, server log): $WORK"
# About 25 s: two segments, cut at a pause after 12 s.
say -o "$WORK/a.aiff" "We reviewed the budget for the next quarter and agreed it stays as it is. [[slnc 1500]] \
  The vendor contract needs a second review before anyone signs it, and Priya will draft the migration plan by Thursday. [[slnc 1500]] \
  We will not move the launch date unless the load test fails again. [[slnc 1500]] \
  The question of hiring for support stays open until the next meeting, and the design notes go into the shared folder today."
ffmpeg -loglevel error -i "$WORK/a.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/a.wav"
if [ -n "$SPEAKERS" ]; then
  # Twelve alternating turns, 0.7 s apart: some segments hold one voice, some both.
  i=0
  while IFS='|' read -r voice line; do
    say -v "$voice" -r 170 -o "$WORK/turn$i.aiff" "$line"
    ffmpeg -loglevel error -i "$WORK/turn$i.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/turn$i.wav"
    i=$((i + 1))
  done <<'TURNS'
Samantha|Good morning everyone. Let's start with the budget for the next quarter.
Daniel|Thanks. The budget stays as it is, but marketing wants a little more for the launch.
Samantha|Okay. Can you send me the numbers by Thursday so I can review them?
Daniel|Sure, I will send the spreadsheet tomorrow morning.
Samantha|Great. Next item is the vendor contract. It still needs a second review.
Daniel|I read it last night. The payment terms look fine, but the support clause is weak.
Samantha|Then let's ask legal to look at the support clause before anyone signs.
Daniel|Agreed. I will open a ticket with legal this afternoon.
Samantha|Last thing, the launch date. Are we still on track for the end of the month?
Daniel|Yes, unless the load test fails again. We run it on Monday.
Samantha|Perfect. Let's meet again on Tuesday to check the results.
Daniel|Sounds good. See you on Tuesday.
TURNS
  args=()
  for j in $(seq 0 $((i - 1))); do args+=(-i "$WORK/turn$j.wav"); done
  ffmpeg -loglevel error "${args[@]}" -filter_complex \
    "$(for j in $(seq 0 $((i - 1))); do printf '[%d:a]apad=pad_dur=0.7[p%d];' "$j" "$j"; done; \
       for j in $(seq 0 $((i - 1))); do printf '[p%d]' "$j"; done; printf 'concat=n=%d:v=0:a=1' "$i")" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/two.wav"
fi

cd "$ROOT/server"
uv sync --locked -q
HOME="$WORK" UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}" \
  uv run chirp-server --port "$PORT" --model-dir "$MODEL_DIR" > "$WORK/server.log" 2>&1 &
SERVER=$!
stop_server() { kill "$SERVER" 2>/dev/null || true; pkill -P "$SERVER" 2>/dev/null || true; }
trap stop_server EXIT
for _ in $(seq 1 120); do curl -s -m 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 && break; sleep 1; done
TOKEN="$WORK/.config/chirp/token"
[ -s "$TOKEN" ] || { echo "server did not start; see $WORK/server.log" >&2; exit 1; }

BUILD=(swift build --package-path "$ROOT/mac")
[ -n "${CHIRP_MAC_SCRATCH:-}" ] && BUILD+=(--scratch-path "$CHIRP_MAC_SCRATCH")
"${BUILD[@]}" 2>&1 | grep -E "error|Build complete" | tail -1
MAC=$("${BUILD[@]}" --show-bin-path)/ChirpMac
fail=0
echo "== notes-selftest"
"$MAC" --notes-selftest "$WORK/a.wav" --url "http://127.0.0.1:$PORT" --token-file "$TOKEN" $PACE --expect budget --expect thursday || fail=1
echo "== notes-selftest --fault $FAULT"
"$MAC" --notes-selftest "$WORK/a.wav" --url "http://127.0.0.1:$PORT" --token-file "$TOKEN" $PACE --fault "$FAULT" || fail=1

if [ -n "$SPEAKERS" ]; then
  echo "== notes-selftest --speakers 2 (two voices, the library, a rename)"
  "$MAC" --notes-selftest "$WORK/two.wav" --url "http://127.0.0.1:$PORT" --token-file "$TOKEN" $PACE \
    --speakers 2 --library --snapshot "$WORK/snapshots" --expect spreadsheet || fail=1
fi

echo "== privacy: transcript words in server log (expect 0)"
hits=$(grep -c -i -E "budget|vendor|thursday|spreadsheet" "$WORK/server.log" || true)
echo "$hits"; [ "$hits" = 0 ] || fail=1
[ $fail = 0 ] && echo "NOTES SELFTEST: PASS" || { echo "NOTES SELFTEST: FAIL"; exit 1; }
