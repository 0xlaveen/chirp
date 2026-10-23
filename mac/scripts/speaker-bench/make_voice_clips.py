"""Two-voice conversations for the voice-profile bench (issue #18 M3): every pair of eight neural `say` voices,
about a minute each, with ground-truth RTTM, written under OUT (outside the repo). Never uses operator audio.

usage: uv run --no-project --with numpy python make_voice_clips.py OUT
"""

import itertools
import sys
from pathlib import Path

import make_clips

# Neural voices only (Eloquence formant voices merge in every embedding, see make_clips.py).
VOICES = ["Samantha", "Daniel", "Moira", "Rishi", "Karen", "Aman", "Tessa", "Tara"]

if __name__ == "__main__":
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for a, b in itertools.combinations(VOICES, 2):
        name = f"pair_{a}_{b}"
        if (out / f"{name}.wav").exists():
            continue
        seconds = make_clips.build(name, [a, b], 22, -45, out)
        print(f"{name}: {seconds:.1f}s")
