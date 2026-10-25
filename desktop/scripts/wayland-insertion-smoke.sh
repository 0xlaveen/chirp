#!/bin/sh
set -eu
# Sway refuses to run as root. No device access or added capabilities are required.
if [ "$(id -u)" = 0 ]; then
    exec runuser -u nobody -- env CHIRP_PLATFORM_SMOKE="${CHIRP_PLATFORM_SMOKE:-/cargo-target/debug/examples/platform-smoke}" python3 scripts/wayland-insertion-smoke.py
fi
exec python3 scripts/wayland-insertion-smoke.py
