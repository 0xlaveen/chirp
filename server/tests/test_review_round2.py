"""Synthetic reproductions for docs/review/round2.md; no production fixes."""

import threading

import pytest
from conftest import HEADERS, PCM, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.correction import CorrectionResult
from chirp_server.engine import FakeEngine
from chirp_server.engine.fake import FakeStream
from chirp_server.retention import Retention


@pytest.mark.xfail(strict=True, reason="R2-01: cancel is not read during finalization")
def test_cancel_during_finish_prevents_correction_and_retention(settings, monkeypatch):
    entered, release = threading.Event(), threading.Event()
    corrected, retained = [], []

    class BlockedStream(FakeStream):
        def finish(self):
            entered.set()
            if not release.wait(5):
                raise RuntimeError("test barrier timed out")
            return super().finish()

    class BlockedEngine(FakeEngine):
        def open_stream(self):
            return BlockedStream(self)

    class Corrector:
        async def process(self, raw):
            corrected.append(True)
            return CorrectionResult(raw)

    # Observe side effects without writing audio/transcripts, even in debug mode.
    monkeypatch.setattr(Retention, "save", lambda *args: retained.append(True))
    settings.idle_seconds = 5
    settings.debug_retain = True
    with TestClient(create_app(settings, BlockedEngine(), TOKEN, Corrector())) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(dict(START, correction=True))
            ws.receive_json()
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            try:
                assert entered.wait(5)
                ws.send_json({"type": "cancel"})
            finally:
                release.set()
            result = final(ws)
    assert (result["type"] == "final", bool(corrected), bool(retained)) == (False, False, False)
