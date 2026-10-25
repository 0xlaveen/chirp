#!/bin/sh
# A macOS Documents bind mount can hang before Docker even starts the process.
# Snapshot outside protected folders; copy into a disposable Linux container.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
snapshot=$(mktemp -d /tmp/chirp-linux-build.XXXXXX)
echo "Linux build evidence: $snapshot"
mkdir -p "$snapshot/desktop"
rsync -a --exclude node_modules --exclude target --exclude gen "$root/desktop/" "$snapshot/desktop/"
status=0
# docker cp also works when Docker Desktop file sharing is blocked by TCC.
container=$(docker create -e CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-3}" chirp-linux-desktop:dev "$@")
printf '%s\n' "$container" > "$snapshot/container-id"
docker cp "$snapshot/desktop/." "$container:/workspace/desktop/"
docker start -a "$container" || status=$?
docker cp "$container:/workspace/desktop/." "$snapshot/desktop/" || true
# Retain the stopped container as well: the printed ID can be inspected for artifacts.
echo "Linux evidence container: $container"
if [ -f "$snapshot/desktop/src-tauri/Cargo.lock" ]; then
  cp "$snapshot/desktop/src-tauri/Cargo.lock" "$root/desktop/src-tauri/Cargo.lock"
fi
if [ "${CHIRP_COPY_FORMAT:-0}" = 1 ]; then
  rsync -a "$snapshot/desktop/src-tauri/src/" "$root/desktop/src-tauri/src/"
  rsync -a "$snapshot/desktop/src-tauri/examples/" "$root/desktop/src-tauri/examples/"
  cp "$snapshot/desktop/src-tauri/build.rs" "$root/desktop/src-tauri/build.rs"
fi
# The snapshot is retained for reviewing build output and native artifacts.
exit "$status"
