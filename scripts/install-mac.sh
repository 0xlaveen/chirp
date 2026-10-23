#!/bin/bash
# Standalone source install: no Nix, dotfiles, Koi or Tailscale required.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SERVER="$HOME/Library/Application Support/Chirp/server"
MODE=app
case "${1:-}" in
--server-only) MODE=server ;;
--help | -h)
  echo 'Usage: scripts/install-mac.sh [--server-only]'
  exit 0
  ;;
'') ;;
*)
  echo 'Unknown option. Use --help.' >&2
  exit 64
  ;;
esac
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'Local MLX models require an Apple Silicon Mac.' >&2
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
if "$SERVER/.venv/bin/python" -c 'import importlib.util as u, sys; sys.exit(not u.find_spec("sherpa_onnx"))' 2>/dev/null; then
  EXTRA='--extra sensevoice'
fi
# shellcheck disable=SC2086
uv sync --project "$SERVER" --locked --no-dev $EXTRA
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
