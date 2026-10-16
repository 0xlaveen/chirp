"""Koi's in-memory Parakeet decode plus the maintained streaming context API."""

import numpy as np

from chirp_server.audio import silent

from .base import Partial
from .models import discover


class ParakeetMLX:
    name = "parakeet-mlx:tdt-0.6b-v2"

    def __init__(self, model_dir=None, precision="float32", streaming="incremental"):
        self.model_dir = model_dir
        self.precision = precision
        self.streaming = streaming
        self.model = None

    def load(self):
        import mlx.core as mx
        from parakeet_mlx import from_pretrained

        self.mx = mx
        self.dtype = getattr(mx, self.precision)
        self.model = from_pretrained(str(discover(self.model_dir)))
        if self.precision != "float32":
            self.model.set_dtype(self.dtype)
        mx.eval(self.model.parameters())

    def decode(self, pcm):
        from parakeet_mlx.audio import get_logmel

        if len(pcm) < 1600 or silent(pcm):
            return None
        mel = get_logmel(self.mx.array(pcm, dtype=self.dtype), self.model.preprocessor_config)
        return self.model.generate(mel)[0]

    def transcribe(self, pcm):
        if len(pcm) <= 30 * 16000:
            result = self.decode(pcm)
            return result.text.strip() if result else ""
        # Reuse the library's timestamp-aware overlap merge without writing a WAV.
        from parakeet_mlx.alignment import (
            merge_longest_common_subsequence,
            merge_longest_contiguous,
            sentences_to_result,
            tokens_to_sentences,
        )

        tokens = []
        for start in range(0, len(pcm), 25 * 16000):
            result = self.decode(pcm[start : start + 30 * 16000])
            if result is None:
                continue
            for token in result.tokens:
                token.start += start / 16000
                token.end = token.start + token.duration
            if tokens:
                try:
                    tokens = merge_longest_contiguous(tokens, result.tokens, overlap_duration=5.0)
                except RuntimeError:
                    tokens = merge_longest_common_subsequence(
                        tokens, result.tokens, overlap_duration=5.0
                    )
            else:
                tokens = result.tokens
            if start + 30 * 16000 >= len(pcm):
                break
        return sentences_to_result(tokens_to_sentences(tokens)).text.strip() if tokens else ""

    def open_stream(self):
        return MLXStream(self) if self.streaming == "incremental" else RollingStream(self)

    def close(self):
        self.model = None
        self.mx.clear_cache()


class RollingStream:
    def __init__(self, engine):
        self.engine = engine
        self.parts = []

    def feed(self, pcm):
        self.parts.append(pcm)
        audio = np.concatenate(self.parts)
        return Partial(self.engine.transcribe(audio[-8 * 16000 :]))

    def finish(self):
        audio = np.concatenate(self.parts) if self.parts else np.zeros(0, dtype=np.float32)
        self.parts.clear()
        return self.engine.transcribe(audio)

    def cancel(self):
        self.parts.clear()


class MLXStream(RollingStream):
    def __init__(self, engine):
        super().__init__(engine)
        # 16 frames of lookahead = 1.28 s; smaller than upstream's 20.48 s default.
        self.context = engine.model.transcribe_stream(context_size=(128, 16)).__enter__()

    def feed(self, pcm):
        self.parts.append(pcm)
        if self.context is None:
            return Partial(self.engine.transcribe(np.concatenate(self.parts)[-8 * 16000 :]))
        try:
            self.context.add_audio(self.engine.mx.array(pcm, dtype=self.engine.dtype))
            return Partial(self.context.result.text.strip())
        except Exception:
            # Some model/library variants cannot incrementally decode; use bounded windows.
            self._close_context()
            return Partial(self.engine.transcribe(np.concatenate(self.parts)[-8 * 16000 :]))

    def _close_context(self):
        if self.context is not None:
            self.context.__exit__(None, None, None)
            self.context = None

    def finish(self):
        # Restore full attention before the authoritative full-utterance decode.
        self._close_context()
        return super().finish()

    def cancel(self):
        self._close_context()
        super().cancel()
