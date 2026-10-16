"""Koi's in-memory Parakeet decode plus the maintained streaming context API."""

import numpy as np

from chirp_server.audio import silent

from .base import Partial
from .models import discover


class ParakeetMLX:
    name = "parakeet-mlx:tdt-0.6b-v2"

    def __init__(
        self, model_dir=None, precision="float32", streaming="rolling", finalization="full"
    ):
        self.model_dir = model_dir
        self.precision = precision
        self.streaming = streaming
        self.finalization = finalization
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
        mel = get_logmel(self.mx.array(pcm, dtype=self.mx.float32), self.model.preprocessor_config)
        return self.model.generate(mel.astype(self.dtype))[0]

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
        if self.streaming == "incremental":
            try:
                return MLXStream(self)
            except (AttributeError, NotImplementedError):
                pass
        return MLXRollingStream(self)

    def close(self):
        self.model = None
        self.mx.clear_cache()


class RollingStream:
    """Bounded preview windows; optional pause segments finalized during capture."""

    def __init__(self, engine):
        self.engine = engine
        self.parts = []
        self.committed = ""
        self.preview = ""
        self.segments = 0

    @staticmethod
    def pause_cut(audio):
        # 20 ms frames, >=400 ms contiguous low signal, after some spoken audio.
        length = len(audio) // 320 * 320
        if length < 6400:
            return 0
        frames = audio[:length].reshape(-1, 320)
        quiet = (np.max(np.abs(frames), axis=1) < 0.001) & (
            np.sqrt(np.mean(frames * frames, axis=1)) < 0.0002
        )
        edges = np.diff(np.r_[False, quiet, False].astype(np.int8))
        starts, ends = np.flatnonzero(edges == 1), np.flatnonzero(edges == -1)
        cuts = [
            end * 320
            for start, end in zip(starts, ends, strict=True)
            if end - start >= 20 and start >= 5
        ]
        return cuts[-1] if cuts else 0

    def feed(self, pcm):
        self.parts.append(pcm)
        audio = np.concatenate(self.parts)
        if getattr(self.engine, "finalization", "full") == "segments":
            cut = self.pause_cut(audio)
            if cut:
                segment = self.engine.transcribe(audio[:cut])
                self.committed = " ".join(p for p in (self.committed, segment) if p)
                self.segments += bool(segment)
                audio = audio[cut:]
                self.parts = [audio] if audio.size else []
                self.preview = ""
                self.preview_tokens = []
        self.preview = self.render_preview(audio) if audio.size else ""
        return Partial(" ".join(p for p in (self.committed, self.preview) if p), self.committed)

    def render_preview(self, audio):
        from .stitch import stitch_transcript

        tail = self.engine.transcribe(audio[-8 * 16000 :])
        if len(audio) > 8 * 16000 and self.preview:
            return stitch_transcript(self.preview, tail) or tail
        return tail

    def finish(self):
        audio = np.concatenate(self.parts) if self.parts else np.zeros(0, dtype=np.float32)
        self.parts.clear()
        tail = self.engine.transcribe(audio)
        return " ".join(p for p in (self.committed, tail) if p)

    def cancel(self):
        self.parts.clear()
        self.committed = self.preview = ""


class MLXRollingStream(RollingStream):
    """Use upstream timestamped token merging so an 8s preview retains older text."""

    def __init__(self, engine):
        super().__init__(engine)
        self.preview_tokens = []

    def render_preview(self, audio):
        from parakeet_mlx.alignment import (
            merge_longest_common_subsequence,
            merge_longest_contiguous,
            sentences_to_result,
            tokens_to_sentences,
        )

        start = max(0, len(audio) - 8 * 16000)
        result = self.engine.decode(audio[start:])
        if result is None:
            return self.preview
        for token in result.tokens:
            token.start += start / 16000
            token.end = token.start + token.duration
        if start and self.preview_tokens:
            try:
                self.preview_tokens = merge_longest_contiguous(
                    self.preview_tokens, result.tokens, overlap_duration=1.0
                )
            except RuntimeError:
                self.preview_tokens = merge_longest_common_subsequence(
                    self.preview_tokens, result.tokens, overlap_duration=1.0
                )
        else:
            self.preview_tokens = result.tokens
        return sentences_to_result(tokens_to_sentences(self.preview_tokens)).text.strip()

    def cancel(self):
        self.preview_tokens.clear()
        super().cancel()


class MLXStream(RollingStream):
    def __init__(self, engine):
        super().__init__(engine)
        # Upstream's documented window. Smaller right context failed our WER sanity check.
        self.context = engine.model.transcribe_stream(context_size=(256, 256)).__enter__()
        self.pending = []

    def feed(self, pcm):
        self.parts.append(pcm)
        if self.context is None:
            return Partial(self.engine.transcribe(np.concatenate(self.parts)[-8 * 16000 :]))
        self.pending.append(pcm)
        if sum(len(part) for part in self.pending) < 16000:
            return None
        chunk = np.concatenate(self.pending)
        self.pending.clear()
        try:
            self.context.add_audio(self.engine.mx.array(chunk, dtype=self.engine.mx.float32))
            return Partial(self.context.result.text.strip())
        except Exception:
            # Some model/library variants cannot incrementally decode; use bounded windows.
            self._close_context()
            return Partial(self.engine.transcribe(np.concatenate(self.parts)[-8 * 16000 :]))

    def snapshot(self):
        """Candidate final for benchmark comparison; does not promise final-quality output."""
        if self.context and self.pending:
            self.context.add_audio(
                self.engine.mx.array(np.concatenate(self.pending), dtype=self.engine.mx.float32)
            )
            self.pending.clear()
        return self.context.result.text.strip() if self.context else None

    def _close_context(self):
        if self.context is not None:
            self.context.__exit__(None, None, None)
            self.context = None
        self.pending.clear()

    def finish(self):
        # Restore full attention before the authoritative full-utterance decode.
        self._close_context()
        return super().finish()

    def cancel(self):
        self._close_context()
        super().cancel()
