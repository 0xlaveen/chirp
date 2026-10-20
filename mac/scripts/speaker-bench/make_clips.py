"""Synthetic multi-speaker conversations from macOS `say` voices, with ground-truth RTTM.

Writes 16 kHz mono PCM16 WAVs + RTTM under OUT (outside the repo). Optional low-level
pink-ish noise so the clips are not studio-clean. Never uses operator audio.

usage: uv run --with numpy python make_clips.py OUT
"""

import json
import os
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

RATE = 16000
# CHIRP_CLIP_SEED draws other conversations from the same lines and voices (the bench's extra 4-voice seeds).
rng = np.random.default_rng(int(os.environ.get("CHIRP_CLIP_SEED", "7")))

LINES = [
    "okay so let's get started with the launch review",
    "sure, I pulled the numbers this morning and the beta signups are up about twenty percent",
    "that's better than I expected honestly",
    "yeah",
    "the problem is the onboarding flow still drops people on the second screen",
    "do we know why, is it the permissions prompt",
    "mostly the microphone permission, people don't understand why we need it",
    "right",
    "we could explain it before the system dialog shows up",
    "I can draft that copy by friday if someone reviews it",
    "I'll review it, send it to me",
    "great, and what about the pricing page",
    "we decided last week not to change pricing before launch",
    "okay, so that's settled then",
    "one open question is whether we support the older macs",
    "I'm not sure the neural engine path works on intel at all",
    "it doesn't, we would need the cpu fallback",
    "mm hmm",
    "let's leave intel out of scope for now and revisit in march",
    "agreed, I'll write that down as a decision",
    "next item is the server migration, who owns that",
    "that's mine, I'm moving the box on tuesday",
    "will there be downtime",
    "maybe ten minutes, I'll post in the channel first",
    "sounds good",
    "anything else before we wrap up",
    "just a reminder that the demo is on the third",
    "thanks everyone, talk soon",
]

SCENARIOS = {
    # name: (voices, turns, noise_db)
    "two_distinct": (["Samantha", "Daniel"], 28, -45),
    "three_mixed": (["Samantha", "Daniel", "Moira"], 28, -45),
    "four_similar": (["Samantha", "Flo (English (US))", "Reed (English (US))", "Rishi"], 40, -40),
    "two_long": (["Karen", "Aman"], 140, -45),
    # Neural voices only: Flo/Reed are Eloquence formant voices that embeddings cannot tell apart.
    "four_distinct": (["Samantha", "Daniel", "Moira", "Rishi"], 40, -40),
    # The long-session gate: an hour of three voices, for identity swaps (the lines repeat; the voices stay).
    "three_60min": (["Samantha", "Daniel", "Moira"], 1230, -45),
}

_said = {}


def say(voice: str, text: str) -> np.ndarray:
    if (voice, text) in _said:
        return _said[(voice, text)]
    _said[(voice, text)] = _say(voice, text)
    return _said[(voice, text)]


def _say(voice: str, text: str) -> np.ndarray:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "x.wav"
        subprocess.run(
            ["say", "-v", voice, "-o", str(path), "--file-format=WAVE",
             "--data-format=LEI16@16000", text],
            check=True,
        )
        with wave.open(str(path)) as w:
            pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
    pcm /= 32768
    # Trim TTS leading/trailing silence so the RTTM is tight.
    voiced = np.flatnonzero(np.abs(pcm) > 0.01)
    return pcm[voiced[0] : voiced[-1] + 1] if voiced.size else pcm


def build(name, voices, turns, noise_db, out: Path):
    audio, rttm, script = [], [], []
    t = 0.0
    speaker = 0
    for i in range(turns):
        # Mostly alternate, sometimes jump; never the same speaker twice in a row.
        if i:
            choices = [s for s in range(len(voices)) if s != speaker]
            speaker = choices[0] if rng.random() < 0.6 else int(rng.choice(choices))
        text = LINES[i % len(LINES)]
        pcm = say(voices[speaker], text) * float(rng.uniform(0.5, 0.9))
        gap = float(rng.uniform(0.15, 0.9))
        audio.append(np.zeros(int(gap * RATE), np.float32))
        t += gap
        dur = len(pcm) / RATE
        audio.append(pcm)
        rttm.append(f"SPEAKER {name} 1 {t:.3f} {dur:.3f} <NA> <NA> spk{speaker} <NA> <NA>")
        script.append({"speaker": f"spk{speaker}", "start": round(t, 3),
                       "end": round(t + dur, 3), "text": text})
        t += dur
    signal = np.concatenate(audio + [np.zeros(RATE // 2, np.float32)])
    noise = np.cumsum(rng.normal(size=signal.size)).astype(np.float32)
    noise -= np.convolve(noise, np.ones(64) / 64, mode="same")  # crude high-pass of brown -> pinkish
    noise *= 10 ** (noise_db / 20) / (np.sqrt(np.mean(noise**2)) + 1e-9)
    signal = np.clip(signal + noise, -1, 1)
    with wave.open(str(out / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((signal * 32767).astype(np.int16).tobytes())
    (out / f"{name}.rttm").write_text("\n".join(rttm) + "\n")
    (out / f"{name}.json").write_text(json.dumps(script, indent=1))
    return signal.size / RATE


if __name__ == "__main__":
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    only = set(sys.argv[2:])
    for name, (voices, turns, noise_db) in SCENARIOS.items():
        if only and name not in only:
            continue
        seed = os.environ.get("CHIRP_CLIP_SEED")
        seconds = build(name + (f"_seed{seed}" if seed else ""), voices, turns, noise_db, out)
        print(f"{name}: {len(voices)} speakers, {seconds:.1f}s")
