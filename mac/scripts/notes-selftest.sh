#!/bin/bash
# Live Notes smoke test: a `say` recording through `ChirpMac --notes-selftest` against a throwaway chirp-server
# (temporary HOME and token, port 7899), once clean and once with a dropped socket. Never the running app, its
# preferences or port 7821. Usage: mac/scripts/notes-selftest.sh [--real-time] [--fault PLAN]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PORT=${CHIRP_NOTES_SELFTEST_PORT:-7899}
MODEL_DIR=${CHIRP_MODEL_DIR:-$HOME/.koi/voice-models/parakeet-mlx}
PACE=--fast; FAULT=drop@14
while [ $# -gt 0 ]; do
  case $1 in --real-time) PACE= ;; --fault) FAULT=$2; shift ;; *) echo "unknown arg $1" >&2; exit 64 ;; esac
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

swift build --package-path "$ROOT/mac" 2>&1 | grep -E "error|Build complete" | tail -1
MAC=$(swift build --package-path "$ROOT/mac" --show-bin-path)/ChirpMac
fail=0
echo "== notes-selftest"
"$MAC" --notes-selftest "$WORK/a.wav" --url "http://127.0.0.1:$PORT" --token-file "$TOKEN" $PACE --expect budget --expect thursday || fail=1
echo "== notes-selftest --fault $FAULT"
"$MAC" --notes-selftest "$WORK/a.wav" --url "http://127.0.0.1:$PORT" --token-file "$TOKEN" $PACE --fault "$FAULT" || fail=1

echo "== privacy: transcript words in server log (expect 0)"
hits=$(grep -c -i -E "budget|vendor|thursday" "$WORK/server.log" || true)
echo "$hits"; [ "$hits" = 0 ] || fail=1
[ $fail = 0 ] && echo "NOTES SELFTEST: PASS" || { echo "NOTES SELFTEST: FAIL"; exit 1; }
