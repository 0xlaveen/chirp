"""Deterministic engine for protocol tests; records thread IDs, never audio."""

import threading

from .base import Partial


class FakeEngine:
    name = "fake"

    def __init__(self, text="Synthetic dictation test."):
        self.text = text
        self.threads = []

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
        return Partial(self.engine.text)

    def finish(self):
        return self.engine.transcribe(None)

    def cancel(self):
        self.engine.threads.append(threading.get_ident())
