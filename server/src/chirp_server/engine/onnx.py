"""CPU fallback adapted from Koi; explicit local models, no implicit downloads."""

from pathlib import Path

from .mlx import RollingStream
from .models import model_root
from .stitch import stitch_transcript


class ParakeetONNX:
    name = "parakeet-onnx:tdt-0.6b-v2-int8"

    def __init__(self, model_dir=None, finalization="full"):
        self.model_dir = model_dir
        self.finalization = finalization

    def load(self):
        import onnx_asr

        paths = (
            [self.model_dir]
            if self.model_dir
            else [Path.home() / ".koi/voice-models/parakeet-onnx", model_root() / "parakeet-onnx"]
        )
        directory = next(
            (p for p in paths if p and (p / "encoder-model.int8.onnx").is_file()), None
        )
        if directory is None:
            raise ValueError("ONNX model missing; run chirp-server model fetch --engine onnx")
        self.model = onnx_asr.load_model(
            "nemo-conformer-tdt",
            path=directory,
            quantization="int8",
            providers=["CPUExecutionProvider"],
        )

    def warm(self):
        import numpy as np

        self.model.recognize(np.zeros(8000, dtype=np.float32), sample_rate=16000)

    def transcribe(self, pcm):
        from chirp_server.audio import silent

        if len(pcm) < 1600 or silent(pcm):
            return ""
        text = ""
        for start in range(0, len(pcm), 25 * 16000):
            tail = self.model.recognize(pcm[start : start + 30 * 16000], sample_rate=16000)
            text = (stitch_transcript(text, tail) or f"{text} {tail}").strip() if text else tail
            if start + 30 * 16000 >= len(pcm):
                break
        return text

    def open_stream(self):
        return RollingStream(self)

    def close(self):
        self.model = None
