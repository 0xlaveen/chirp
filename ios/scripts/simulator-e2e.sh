#!/bin/sh
# The full UI scheme, including the live end-to-end suite, on one simulator against a throwaway local chirp-server: temporary HOME (its own
# token), port 7899 (CHIRP_E2E_PORT), cached model, no LaunchAgent, a deterministic local clean-up stand-in and a
# synthetic `say` sentence. Debug simulator builds pair with http://127.0.0.1:PORT; nothing else changes.
# Usage: ios/scripts/simulator-e2e.sh SIMULATOR-UUID [extra xcodebuild args, e.g. -only-testing:…]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
device="${1:-}"; [ -n "$device" ] || { echo 'Usage: simulator-e2e.sh SIMULATOR-UUID [xcodebuild args]' >&2; exit 2; }
shift
PORT=${CHIRP_E2E_PORT:-7899}; CLEANUP_PORT=$((PORT - 1))
MODEL_DIR=${CHIRP_MODEL_DIR:-$HOME/.koi/voice-models/parakeet-mlx}
for p in "$PORT" "$CLEANUP_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is in use; set CHIRP_E2E_PORT" >&2; exit 1; fi
done
WORK=$(mktemp -d /tmp/chirp-ios-e2e.XXXX)
echo "work dir (synthetic audio, throwaway token, server log): $WORK"
say -o "$WORK/s.aiff" "So, um, schedule the team review for Tuesday morning and invite the whole design group."
ffmpeg -loglevel error -i "$WORK/s.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/s.wav"
mkdir -p "$WORK/.config/chirp"
printf '[correction]\nmode = "endpoint"\nbase_url = "http://127.0.0.1:%s/v1"\nmodel = "stand-in"\n' "$CLEANUP_PORT" > "$WORK/.config/chirp/server.toml"
python3 -I "$ROOT/ios/scripts/fake-cleanup.py" "$CLEANUP_PORT" & CLEANUP=$!
cd "$ROOT/server"
uv sync --locked -q
HOME="$WORK" UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}" \
  uv run chirp-server --port "$PORT" --model-dir "$MODEL_DIR" > "$WORK/server.log" 2>&1 & SERVER=$!
stop() { kill "$SERVER" "$CLEANUP" 2>/dev/null || true; pkill -P "$SERVER" 2>/dev/null || true; }
trap stop EXIT
for _ in $(seq 1 120); do curl -s -m 1 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 && break; sleep 1; done
[ -s "$WORK/.config/chirp/token" ] || { echo "server did not start; see $WORK/server.log" >&2; exit 1; }
LINK=$(HOME="$WORK" uv run chirp-server pair --url "http://127.0.0.1:$PORT" | head -1)
cd "$ROOT/ios"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl privacy "$device" grant microphone "${CHIRP_BUNDLE_ID:-dev.chirp.ios}" 2>/dev/null || true
status=0
TEST_RUNNER_CHIRP_LIVE_LINK="$LINK" TEST_RUNNER_CHIRP_LIVE_AUDIO="$WORK/s.wav" \
  ./scripts/simulator.sh ui "$device" "$@" || status=$?
echo "== privacy: transcript words in server log (expect 0)"
hits=$(grep -c -i -E "tuesday|schedule|design group" "$WORK/server.log" || true)
echo "$hits"; [ "$hits" = 0 ] || status=1
[ $status = 0 ] && echo "iOS E2E: PASS" || { echo "iOS E2E: FAIL"; exit 1; }
