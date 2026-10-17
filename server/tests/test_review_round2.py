"""Regression tests for docs/review/round2.md (R2-01 fixed)."""

import asyncio
import threading

from conftest import HEADERS, PCM, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.correction import CorrectionResult
from chirp_server.engine import FakeEngine
from chirp_server.engine.fake import FakeStream
from chirp_server.retention import Retention


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
    assert result["type"] == "error" and result["code"] == "cancelled"
    assert not corrected
    assert not retained


def test_cancel_during_pending_correction_cancels_request(settings, monkeypatch):
    entered = threading.Event()
    retained = []

    class HangingCorrector:
        async def process(self, raw):
            entered.set()
            await asyncio.Event().wait()
            return CorrectionResult(raw)

    monkeypatch.setattr(Retention, "save", lambda *args: retained.append(True))
    settings.idle_seconds = 5
    settings.debug_retain = True
    with TestClient(create_app(settings, FakeEngine(), TOKEN, HangingCorrector())) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(dict(START, correction=True))
            ws.receive_json()
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            assert entered.wait(5)
            ws.send_json({"type": "cancel"})
            result = final(ws)
    assert result["type"] == "error" and result["code"] == "cancelled"
    assert not retained
