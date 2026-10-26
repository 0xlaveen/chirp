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
    # Learning: an unambiguous technical mishearing, rather than an ordinary adjective the model should preserve.
    say -v Samantha -r 135 -o "$speech_tmp/learn.aiff" 'Please deploy the service to acme cloud before the meeting tomorrow.'
    afconvert -f WAVE -d LEI16@16000 -c 1 "$speech_tmp/learn.aiff" "$asset_dir/synthetic-learn.wav"
    # Two different voices, one after the other, for the speaker-labels check: a short meeting exchange.
    say -v Samantha -r 150 -o "$speech_tmp/one.aiff" 'We should ship the beta on Friday, but only if the review is done by Thursday.'
    say -v Daniel -r 150 -o "$speech_tmp/two.aiff" 'That works for me. I can send the spec tomorrow morning and check the budget.'
    afconvert -f WAVE -d LEI16@16000 -c 1 "$speech_tmp/one.aiff" "$speech_tmp/one.wav"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$speech_tmp/two.aiff" "$speech_tmp/two.wav"
    python3 -I - "$speech_tmp/one.wav" "$speech_tmp/two.wav" "$asset_dir/synthetic-two.wav" <<'PY'
import sys, wave
frames = []
for path in sys.argv[1:3]:
    with wave.open(path) as part: frames.append(part.readframes(part.getnframes()))
with wave.open(sys.argv[3], "wb") as out:
    out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
    out.writeframes(frames[0] + b"\0\0" * 9600 + frames[1])  # 0.6 s between the two people
PY
elif [ -n "${CHIRP_SYNTHETIC_WAV:-}" ]; then
    cp "$CHIRP_SYNTHETIC_WAV" "$asset_dir/synthetic.wav"
fi
