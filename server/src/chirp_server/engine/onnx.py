"""Portable Parakeet on ONNX Runtime, adapted from Koi; explicit local models, no implicit
downloads. CPU by default; `[onnx] providers` opts in to CUDA or DirectML when installed."""

import logging
from pathlib import Path

from chirp_server.config import OnnxConfig

from .mlx import RollingStream
from .models import model_root
from .stitch import stitch_transcript

log = logging.getLogger("chirp")
CPU = "CPUExecutionProvider"
ACCELERATORS = {"cuda": "CUDAExecutionProvider", "directml": "DmlExecutionProvider"}


def choose_providers(requested: str, available) -> list[str]:
    """ONNX Runtime providers for `requested` (cpu, auto, cuda or directml), always ending in
    CPU so an unavailable accelerator falls back instead of failing."""
    if requested == "auto":
        wanted = [name for name in ACCELERATORS.values() if name in available][:1]
    elif requested in ACCELERATORS:
        wanted = [ACCELERATORS[requested]] if ACCELERATORS[requested] in available else []
    else:
        wanted = []
    return [*wanted, CPU]


def find_model(model_dir=None) -> Path:
    paths = (
        [model_dir]
        if model_dir
        else [Path.home() / ".koi/voice-models/parakeet-onnx", model_root() / "parakeet-onnx"]
    )
    directory = next(
        (Path(p) for p in paths if p and (Path(p) / "encoder-model.int8.onnx").is_file()), None
    )
    if directory is None:
        raise ValueError("ONNX model missing; run chirp-server model fetch --engine onnx")
    return directory


class ParakeetONNX:
    name = "parakeet-onnx:tdt-0.6b-v2-int8"

    def __init__(
        self,
        model_dir=None,
        finalization="full",
        *,
        intra_op_num_threads=None,
        inter_op_num_threads=None,
        providers="cpu",
    ):
        self.model_dir = model_dir
        self.finalization = finalization
        self.onnx = OnnxConfig(intra_op_num_threads, inter_op_num_threads, providers)
        self.providers = [CPU]

    def load(self):
        import onnx_asr
        import onnxruntime

        directory = find_model(self.model_dir)
        options = {}
        if any(
            value is not None
            for value in (self.onnx.intra_op_num_threads, self.onnx.inter_op_num_threads)
        ):
            session_options = onnxruntime.SessionOptions()
            for name in ("intra_op_num_threads", "inter_op_num_threads"):
                if (value := getattr(self.onnx, name)) is not None:
                    setattr(session_options, name, value)
            options["sess_options"] = session_options
        providers = choose_providers(self.onnx.providers, onnxruntime.get_available_providers())
        try:
            self.model = self._load(onnx_asr, directory, providers, options)
        except Exception:
            if providers == [CPU]:
                raise
            # A driver or op-support problem in the accelerator must not stop dictation.
            log.warning("onnx accelerator %s failed to load; using CPU", providers[0])
            providers = [CPU]
            self.model = self._load(onnx_asr, directory, providers, options)
        self.providers = providers

    @staticmethod
    def _load(onnx_asr, directory, providers, options):
        return onnx_asr.load_model(
            "nemo-conformer-tdt",
            path=directory,
            quantization="int8",
            providers=providers,
            **options,
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
