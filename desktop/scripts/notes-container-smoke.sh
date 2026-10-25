#!/bin/sh
# Explicit synthetic real-model test. No host mounts, live service or normal library.
# First build examples/notes-smoke with linux-container.sh; pass that container ID.
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d /tmp/chirp-desktop-notes-proof.XXXXXX)
echo "Notes proof evidence: $work"
: "${CHIRP_DESKTOP_EVIDENCE_CONTAINER:?Set the container from linux-container.sh}"
: "${CHIRP_GGUF_FILE:?Set the explicitly fetched pinned Qwen GGUF path}"
model=${CHIRP_ONNX_MODEL_DIR:-$HOME/.koi/voice-models/parakeet-onnx}
[ -f "$model/encoder-model.int8.onnx" ]
[ -f "$CHIRP_GGUF_FILE" ]
say -v Samantha -o "$work/speech.aiff" "We decided to keep the current budget. We will not delay the review. I will send the schedule on Tuesday."
ffmpeg -loglevel error -i "$work/speech.aiff" -ar 16000 -ac 1 -f s16le "$work/speech.pcm"
server=$(docker create chirp-linux-server:test /workspace/server/.venv/bin/python /tmp/notes-proof-server.py)
printf '%s\n' "$server" > "$work/server-id"
runner=''
cleanup() {
  status=$?
  docker logs "$server" > "$work/server.log" 2>&1 || true
  docker stop -t 10 "$server" >/dev/null 2>&1 || true
  if [ "$status" -ne 0 ]; then tail -n 35 "$work/server.log"; fi
}
trap cleanup EXIT INT TERM
docker cp "$root/desktop/scripts/notes-proof-server.py" "$server:/tmp/notes-proof-server.py"
docker cp "$model" "$server:/models/"
docker cp "$CHIRP_GGUF_FILE" "$server:/models/cleanup.gguf"
docker start "$server" >/dev/null
# A bounded readiness probe inside this disposable server's own network namespace.
docker exec "$server" /workspace/server/.venv/bin/python -c '
import http.client,time
for _ in range(180):
 try:
  c=http.client.HTTPConnection("127.0.0.1",17992,timeout=1);c.request("GET","/v1/health");r=c.getresponse();assert r.status==200;break
 except (OSError,AssertionError):time.sleep(.5)
else:raise SystemExit("throwaway server did not become ready")
'
docker cp "$server:/tmp/chirp-notes-proof.token" "$work/token"
docker cp "$CHIRP_DESKTOP_EVIDENCE_CONTAINER:/cargo-target/debug/examples/notes-smoke" "$work/notes-smoke"
runner=$(docker create --network "container:$server" chirp-linux-desktop:dev /tmp/notes-smoke http://127.0.0.1:17992 /tmp/proof.token /tmp/proof.pcm /tmp/proof-library)
printf '%s\n' "$runner" > "$work/client-id"
docker cp "$work/notes-smoke" "$runner:/tmp/notes-smoke"
docker cp "$work/token" "$runner:/tmp/proof.token"
docker cp "$work/speech.pcm" "$runner:/tmp/proof.pcm"
status=0
docker start -a "$runner" || status=$?
docker logs "$server" > "$work/server.log" 2>&1
python3 - "$work/server.log" <<'PY'
import sys
from pathlib import Path
text=Path(sys.argv[1]).read_text().lower()
assert not any(word in text for word in ("current budget", "not delay", "tuesday")), "Synthetic transcript reached server log"
print("Notes: no synthetic transcript in server log")
PY
echo "Notes proof containers: server=$server client=$runner"
exit "$status"
