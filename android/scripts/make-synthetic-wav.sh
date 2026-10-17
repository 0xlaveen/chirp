#!/bin/sh
# Debug build asset only. Never commit generated audio or use user speech.
set -eu
asset_dir="$(dirname "$0")/../app/build/generated/chirp-debug-assets"
mkdir -p "$asset_dir"
if command -v say >/dev/null && command -v afconvert >/dev/null; then
    speech_tmp="$(mktemp -d)"
    trap 'rm -rf "$speech_tmp"' EXIT
    say -v Samantha -r 135 -o "$speech_tmp/speech.aiff" 'Um, this is a, a synthetic keyboard test. Uh, please send the, the draft tomorrow.'
    afconvert -f WAVE -d LEI16@16000 -c 1 "$speech_tmp/speech.aiff" "$asset_dir/synthetic.wav"
elif [ -n "${CHIRP_SYNTHETIC_WAV:-}" ]; then
    cp "$CHIRP_SYNTHETIC_WAV" "$asset_dir/synthetic.wav"
fi
