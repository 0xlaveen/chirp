#!/bin/bash
# Standalone source install: no Nix, dotfiles, Koi or Tailscale required.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SERVER="$HOME/Library/Application Support/Chirp/server"
PORT="${CHIRP_PORT:-7821}"
LABEL=dev.chirp.server
MODE=app
RESTART=1
for arg in "$@"; do
  case "$arg" in
  --server-only) MODE=server ;;
  --no-restart) RESTART=0 ;;
  --help | -h)
    echo 'Usage: scripts/install-mac.sh [--server-only] [--no-restart]'
    echo '  After updating the server it checks what answers on port 7821 (CHIRP_PORT overrides)'
    echo '  and restarts it when it is the Chirp-managed LaunchAgent; --no-restart only reports.'
    exit 0
    ;;
  *)
    echo 'Unknown option. Use --help.' >&2
    exit 64
    ;;
  esac
done
if [ "$(uname -s)" != Darwin ]; then
  echo 'This installer requires macOS 14 or later.' >&2
  exit 1
fi
if ! command -v uv >/dev/null 2>&1; then
  echo 'Install uv first: https://docs.astral.sh/uv/getting-started/installation/' >&2
  exit 1
fi
if [ "$MODE" = app ] && ! xcode-select -p >/dev/null 2>&1; then
  echo 'Install Apple Command Line Tools first: xcode-select --install' >&2
  exit 1
fi
# Copy only the server source and locked environment definition; preserve its venv.
mkdir -p "$SERVER"
cp "$ROOT/server/pyproject.toml" "$ROOT/server/uv.lock" "$SERVER/"
mkdir -p "$SERVER/src/chirp_server"
rsync -a --exclude __pycache__ "$ROOT/server/src/chirp_server/" "$SERVER/src/chirp_server/"
# Keep the optional SenseVoice runtime if the app added it; a plain sync would remove it.
EXTRA=
# Intel Macs use portable Parakeet; MLX wheels are installed only on arm64.
if [ "$(uname -m)" != arm64 ]; then
  EXTRA='--extra onnx --extra cleanup'
  # Under Rosetta an arm64 clang interprets -march=native as an Apple CPU even
  # when building x86_64. Use llama.cpp's portable x86 CPU flags instead.
  # Chirp downloads through Python; llama.cpp needs no HTTPS/OpenSSL dependency
  # (which can otherwise resolve to an incompatible arm64 Homebrew library).
  export CMAKE_ARGS="${CMAKE_ARGS:-} -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF"
fi
if "$SERVER/.venv/bin/python" -c 'import importlib.util as u, sys; sys.exit(not u.find_spec("sherpa_onnx"))' 2>/dev/null; then
  EXTRA="$EXTRA --extra sensevoice"
fi
# shellcheck disable=SC2086
uv sync --project "$SERVER" --locked --no-dev $EXTRA
# The server reports this commit in its health; the copy has no .git to ask.
if COMMIT=$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null); then
  printf '%s\n' "$COMMIT" >"$SERVER/src/chirp_server/BUILD_COMMIT"
else
  rm -f "$SERVER/src/chirp_server/BUILD_COMMIT"
fi

# A server that was already running keeps running the old code until it restarts. Say which one it is.
check_running_server() {
  local pid label command plist program
  pid=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)
  [ -n "$pid" ] || return 0
  label=$(launchctl list 2>/dev/null | awk -v pid="$pid" '$1 == pid { print $3; exit }' || true)
  command=$(ps -o command= -p "$pid" 2>/dev/null || true)
  plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  if [ "$label" = "$LABEL" ] && [ -f "$plist" ]; then
    program=$(plutil -extract ProgramArguments.0 raw -o - "$plist" 2>/dev/null || true)
    if [ "$RESTART" = 1 ] && [ -x "$SERVER/.venv/bin/chirp-server" ]; then
      echo "Restarting the Chirp server ($LABEL, pid $pid) so it runs the code just installed…"
      "$SERVER/.venv/bin/chirp-server" --port "$PORT" setup restart || {
        echo "Restart failed. Run: $SERVER/.venv/bin/chirp-server --port $PORT setup restart" >&2
        return 0
      }
    else
      echo "The Chirp server ($LABEL, pid $pid) is still running its old code. Restart it with:"
      echo "  $SERVER/.venv/bin/chirp-server --port $PORT setup restart"
    fi
    if [ -n "$program" ] && [ "$program" != "$SERVER/.venv/bin/python" ]; then
      echo "Note: that LaunchAgent runs $program, not the copy installed in Application Support."
      echo "To switch: $SERVER/.venv/bin/chirp-server service uninstall && $SERVER/.venv/bin/chirp-server service install"
    fi
  elif [ -n "$label" ]; then
    echo "Port $PORT is served by the LaunchAgent '$label' (pid $pid), which Chirp does not manage; it was not restarted."
    echo "  running: $command"
    echo "To use the managed server instead:"
    echo "  launchctl bootout gui/$(id -u)/$label"
    echo "  $SERVER/.venv/bin/chirp-server --port $PORT setup restart"
  else
    echo "Port $PORT is served by a process Chirp did not start (pid $pid); it was not restarted."
    echo "  running: $command"
    echo "To use the managed server instead, either quit it and run:"
    echo "  $SERVER/.venv/bin/chirp-server --port $PORT setup restart"
    echo "or run the same with 'replace' instead of 'restart' to stop it for you."
  fi
}
check_running_server

if [ "$MODE" = server ]; then
  printf 'Server installed: %s\n' "$SERVER/.venv/bin/chirp-server"
  echo 'Use its setup commands to select/download models and start the server.'
  exit 0
fi
"$ROOT/mac/scripts/make-cert.sh"
"$ROOT/mac/scripts/bundle.sh"
"$ROOT/mac/scripts/install.sh"
open "$HOME/Applications/Chirp.app" --args --models
echo 'Choose your speech/correction models in Chirp, download them, then start the server.'
