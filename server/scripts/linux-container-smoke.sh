#!/bin/sh
# Run from macOS: synthetic say audio, temporary source, no Docker bind mounts.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d /tmp/chirp-linux-server-smoke.XXXXXX)
echo "Linux server evidence: $work"
mkdir -p "$work/server"
rsync -a --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude .ruff_cache --exclude fixtures "$root/server/" "$work/server/"
mkdir -p "$work/server/tests/fixtures"
rsync -a "$root/scripts/" "$work/server/repository-scripts/"
say -v Samantha -o "$work/speech.aiff" "The quick brown fox jumped over the lazy dog. Schedule the team review for Tuesday morning."
ffmpeg -loglevel error -i "$work/speech.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$work/server/tests/fixtures/synthetic-fox.wav"
docker build -t chirp-linux-server:test -f "$work/server/scripts/Dockerfile.linux-test" "$work/server"
model=${CHIRP_ONNX_MODEL_DIR:-$HOME/.koi/voice-models/parakeet-onnx}
[ -f "$model/encoder-model.int8.onnx" ] || { echo "Set CHIRP_ONNX_MODEL_DIR to explicitly fetched ONNX weights" >&2; exit 1; }
container=$(docker create -e CHIRP_ONNX_MODEL_DIR=/models/parakeet-onnx chirp-linux-server:test sh -c '
  result=0
  uv run --no-sync ruff check . && uv run --no-sync ruff format --check . || result=1
  uv run --no-sync pytest -q || result=1
  uv run --no-sync pytest -q -m onnx || result=1
  uv run --no-sync python scripts/systemd_unit_smoke.py || result=1
  uv run --no-sync python scripts/portable_cleanup_smoke.py || result=1
  exit "$result"
')
printf '%s\n' "$container" > "$work/container-id"
docker cp "$model" "$container:/models"
status=0
docker start -a "$container" || status=$?
echo "Linux server evidence container: $container"
exit "$status"
