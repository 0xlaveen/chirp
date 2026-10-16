#!/bin/bash
# Local end-to-end check of all three Chirp components against one real chirp-server.
# Code paths only: no microphone, no Accessibility, no phone, no Tailscale. The server runs with a
# throwaway HOME (its own token) on a non-default port and is stopped at the end.
# Usage: scripts/e2e-local.sh [--skip-mac] [--skip-android]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT=${CHIRP_E2E_PORT:-7899}
MODEL_DIR=${CHIRP_MODEL_DIR:-$HOME/.koi/voice-models/parakeet-mlx}
SKIP_MAC=0; SKIP_ANDROID=0
for arg in "$@"; do
  case $arg in --skip-mac) SKIP_MAC=1 ;; --skip-android) SKIP_ANDROID=1 ;; *) echo "unknown arg $arg" >&2; exit 64 ;; esac
done

WORK=$(mktemp -d /tmp/chirp-e2e-local.XXXX)
echo "work dir (synthetic audio, throwaway token, server log): $WORK"
SENTENCE="Schedule the team review for Tuesday morning and invite the whole design group."
say -o "$WORK/s.aiff" "$SENTENCE"
ffmpeg -loglevel error -i "$WORK/s.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/s.wav"

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
URL="http://127.0.0.1:$PORT"
fail=0

echo "== health"
curl -s "$URL/v1/health"; echo
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wrong" "$URL/v1/health")
echo "authenticated health with wrong token -> HTTP $code (unauth body is minimal)"
curl -s -H "Authorization: Bearer $(cat "$TOKEN")" "$URL/v1/health"; echo

echo "== server client_sim"
uv run python tests/client_sim.py "$WORK/s.wav" --url "$URL" --token-file "$TOKEN" | tail -3 || fail=1

if [ $SKIP_MAC = 0 ]; then
  echo "== mac --selftest"
  swift build --package-path "$ROOT/mac" 2>&1 | grep -E "error|Build complete" | tail -1
  MAC=$(swift build --package-path "$ROOT/mac" --show-bin-path)/ChirpMac
  "$MAC" --selftest "$WORK/s.wav" --url "$URL" --token-file "$TOKEN" --expect tuesday | tail -3 || fail=1
  echo bogus > "$WORK/bad-token"
  if "$MAC" --selftest "$WORK/s.wav" --url "$URL" --token-file "$WORK/bad-token" >/dev/null 2>&1; then
    echo "FAIL: wrong token accepted"; fail=1
  else echo "wrong token refused: OK"; fi
fi

if [ $SKIP_ANDROID = 0 ]; then
  echo "== android transport (JVM LiveServerTest)"
  # shellcheck disable=SC1091
  source "$HOME/.local/share/chirp-android/env.sh"
  (cd "$ROOT/android" && ./gradlew --console=plain testDebugUnitTest --tests '*LiveServerTest*' -i \
    -Pchirp.live.url="$URL/" -Pchirp.live.tokenFile="$TOKEN" -Pchirp.live.wav="$WORK/s.wav" \
    -Pchirp.live.expect=tuesday 2>&1 | grep -E "live utterance|FAILED|BUILD") || fail=1
fi

echo "== privacy: transcript words in server log (expect 0)"
hits=$(grep -c -i -E "tuesday|schedule|design group" "$WORK/server.log" || true)
echo "$hits"; [ "$hits" = 0 ] || fail=1
echo "== files written under throwaway HOME besides token/cache (expect none)"
find "$WORK" -type f -newer "$WORK/s.wav" ! -path "*/.cache/*" ! -name token ! -name server.log ! -name bad-token -print

[ $fail = 0 ] && echo "E2E: PASS" || { echo "E2E: FAIL"; exit 1; }
