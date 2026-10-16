"""Run upstream README streaming example on v2; emit WER/counts only."""

import json
import time
from pathlib import Path

import jiwer
import mlx.core as mx
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import load_audio

from chirp_server.engine.models import discover

root = Path.home() / "Library/Caches/Chirp/fixtures"
entry = json.loads((root / "manifest.json").read_text())[0]
model = from_pretrained(str(discover()))
# Upstream load_audio defaults to bf16, but get_logmel 0.5.3 reinterprets FFT complex64
# as the input dtype. Use fp32 audio to avoid its invalid 514-bin fp16/bf16 view.
audio = load_audio(root / entry["file"], 16000, mx.float32)
normalize = jiwer.Compose([jiwer.ToLowerCase(), jiwer.RemovePunctuation(), jiwer.Strip()])
for context in [(256, 256), (128, 16)]:
    started = time.perf_counter()
    with model.transcribe_stream(context_size=context) as transcriber:
        for offset in range(0, len(audio), 16000):
            transcriber.add_audio(audio[offset : offset + 16000])
        text = transcriber.result.text
        print(
            json.dumps(
                {
                    "context": context,
                    "chunk_seconds": 1,
                    "seconds": time.perf_counter() - started,
                    "wer": jiwer.wer(normalize(entry["reference"]), normalize(text)),
                    "finalized_tokens": len(transcriber.finalized_tokens),
                    "draft_tokens": len(transcriber.draft_tokens),
                }
            )
        )
