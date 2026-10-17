"""Deterministic engine for protocol tests; records thread IDs, never audio."""

import threading

from .base import Partial, Transcript
from .words import Word


def fake_words(text: str, stable: bool = False) -> tuple[Word, ...]:
    """Evenly spaced word timings for `text`: 300 ms per word, 250 ms spoken."""
    return tuple(
        Word(word, round(index * 0.3, 3), round(index * 0.3 + 0.25, 3), stable)
        for index, word in enumerate(text.split())
    )


class FakeEngine:
    name = "fake"

    def __init__(self, text="Synthetic dictation test.", timed=True):
        self.text = text
        # False mimics an engine without token timings (the ONNX fallback): no `words`.
        self.timed = timed
        self.threads = []

    @property
    def words(self):
        return fake_words(self.text) if self.timed else None

    def load(self):
        self.threads.append(threading.get_ident())

    def transcribe(self, pcm):
        self.threads.append(threading.get_ident())
        return self.text

    def open_stream(self):
        self.threads.append(threading.get_ident())
        return FakeStream(self)


class FakeStream:
    def __init__(self, engine):
        self.engine = engine

    def feed(self, pcm):
        self.engine.threads.append(threading.get_ident())
        return Partial(self.engine.text, words=self.engine.words)

    def buffer(self, pcm):
        self.engine.threads.append(threading.get_ident())

    def finish(self):
        text = self.engine.transcribe(None)
        words = fake_words(text, stable=True) if self.engine.timed else None
        return Transcript(text, words)

    def cancel(self):
        self.engine.threads.append(threading.get_ident())
