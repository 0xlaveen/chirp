"""Generate public synthetic speech, outside the repo by default. Never captures a mic."""

import argparse
import json
import subprocess
import wave
from pathlib import Path

from chirp_server.paths import fixtures_dir

TEXT = (
    "The quick brown fox jumps over the lazy dog. "
    "Please send the updated project schedule tomorrow morning. "
    "Local speech recognition keeps our audio on this computer. "
    "We can test streaming dictation with a clear synthetic voice. "
)


def generate(directory: Path, pause_ms: int = 0):
    directory.mkdir(parents=True, exist_ok=True)
    manifest = []
    # say's exact duration varies with OS/voice. Trim at the requested duration and use
    # separate phrase files to determine the exact reference from fully retained phrases.
    phrase = directory / "phrase.wav"
    subprocess.run(
        [
            "say",
            "-v",
            "Samantha",
            "-r",
            "175",
            "-o",
            str(phrase),
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            TEXT,
        ],
        check=True,
    )
    with wave.open(str(phrase), "rb") as wav:
        pcm = wav.readframes(wav.getnframes())
    # Use complete sentences so WER references never guess a truncated word.
    sentences = TEXT.strip().split(". ")
    pieces = []
    for i, sentence in enumerate(sentences):
        sentence = sentence.rstrip(".") + "."
        path = directory / f"sentence-{i}.wav"
        subprocess.run(
            [
                "say",
                "-v",
                "Samantha",
                "-r",
                "175",
                "-o",
                str(path),
                "--file-format=WAVE",
                "--data-format=LEI16@16000",
                sentence,
            ],
            check=True,
        )
        with wave.open(str(path), "rb") as wav:
            pieces.append((sentence, wav.readframes(wav.getnframes())))
        path.unlink()
    phrase.unlink()
    for duration in (5, 15, 60):
        audio, reference = bytearray(), []
        index = 0
        while len(audio) < duration * 32000:
            sentence, pcm = pieces[index % len(pieces)]
            if audio and pause_ms:
                audio.extend(b"\0" * (pause_ms * 32))
            audio.extend(pcm)
            reference.append(sentence)
            index += 1
        path = directory / f"synthetic-{duration}s.wav"
        with wave.open(str(path), "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(audio)
        manifest.append(
            {
                "file": path.name,
                "target_seconds": duration,
                "seconds": len(audio) / 32000,
                "reference": " ".join(reference),
            }
        )
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=fixtures_dir())
    parser.add_argument("--pause-ms", type=int, default=0)
    args = parser.parse_args()
    generate(args.output, args.pause_ms)
