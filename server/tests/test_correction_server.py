"""Correction path against a real local OpenAI-compatible HTTP server.

The fixture serves LM Studio-style chat-completion responses (extra fields beyond the
OpenAI spec) on an ephemeral loopback port. Fixtures and transcripts are synthetic.
"""

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from conftest import HEADERS, PCM, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector
from chirp_server.engine import FakeEngine

RAW = "um please send the project schedule tomorrow"
CLEAN = "Please send the project schedule tomorrow."


class FakeLMStudio:
    """Mutable response state for the local endpoint; never holds a real credential."""

    def __init__(self):
        self.reply = CLEAN
        self.status = 200
        self.finish = "stop"
        self.delay = 0.0
        self.requests = []
        self.url = None

    def completion_body(self):
        # LM Studio returns the full OpenAI shape plus vendor extras; the corrector
        # must tolerate both.
        return {
            "id": "chatcmpl-abc123",
            "object": "chat.completion",
            "created": 1760000000,
            "model": "lmstudio-community/test-7b-instruct",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": self.reply},
                    "finish_reason": self.finish,
                    "logprobs": None,
                }
            ],
            "usage": {"prompt_tokens": 21, "completion_tokens": 8, "total_tokens": 29},
            "system_fingerprint": "fp-lmstudio",
        }


@pytest.fixture
def fake_lm():
    state = FakeLMStudio()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):
            pass  # Keep request paths and payloads out of captured logs.

        def _send(self, status, body):
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            state.requests.append({"method": "GET", "path": self.path})
            if self.path == "/v1/models":
                self._send(
                    200,
                    {"object": "list", "data": [{"id": "test-7b-instruct", "object": "model"}]},
                )
            else:
                self._send(404, {"error": {"message": "not found"}})

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            state.requests.append(
                {
                    "method": "POST",
                    "path": self.path,
                    "authorization": self.headers.get("Authorization"),
                    "body": json.loads(self.rfile.read(length) or b"{}"),
                }
            )
            if self.path != "/v1/chat/completions":
                self._send(404, {"error": {"message": "not found"}})
                return
            if state.delay:
                time.sleep(state.delay)
            self._send(state.status, state.completion_body())

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        state.url = f"http://127.0.0.1:{server.server_address[1]}/v1"
        yield state
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()


def corrector(state, **overrides):
    # No injected transport: requests cross a real loopback socket.
    return Corrector(
        CorrectionConfig(enabled=True, base_url=state.url, model="test-7b-instruct", **overrides)
    )


async def test_correction_over_local_server(fake_lm):
    result = await corrector(fake_lm).process(RAW)
    assert result.text == CLEAN and result.corrected and result.error is None
    request = fake_lm.requests[0]
    assert request["path"] == "/v1/chat/completions"
    body = request["body"]
    assert body["model"] == "test-7b-instruct"
    assert body["temperature"] == 0
    assert json.loads(body["messages"][1]["content"].split("Transcript JSON: ", 1)[1]) == RAW
    assert request["authorization"] is None  # no key configured: no Authorization header


async def test_api_key_header_forwarded(fake_lm, monkeypatch):
    monkeypatch.setenv("CHIRP_LLM_API_KEY", "synthetic-key")
    result = await corrector(fake_lm).process(RAW)
    assert result.corrected
    assert fake_lm.requests[0]["authorization"] == "Bearer synthetic-key"


async def test_timeout_over_local_server(fake_lm):
    fake_lm.delay = 1.0
    result = await corrector(fake_lm, timeout=0.2).process(RAW)
    assert result.text == RAW and result.error == "timeout" and not result.corrected


async def test_answer_shaped_rejection(fake_lm):
    fake_lm.reply = "Sure! Here is the project schedule for tomorrow."
    result = await corrector(fake_lm).process(RAW)
    assert result.text == RAW and result.error == "rejected"


async def test_http_error_over_local_server(fake_lm):
    fake_lm.status = 500
    result = await corrector(fake_lm).process(RAW)
    assert result.text == RAW and result.error == "http"


def test_correction_through_app_over_local_server(settings, fake_lm):
    settings.correction = CorrectionConfig(
        enabled=True, base_url=fake_lm.url, model="test-7b-instruct", timeout=5.0
    )
    with TestClient(create_app(settings, FakeEngine(RAW), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            result = final(ws)
    assert result["raw"] == RAW
    assert result["text"] == CLEAN
    assert result["corrected"] is True
    assert result["correction_error"] is None
    assert result["timings_ms"]["correction"] > 0
    assert len(fake_lm.requests) == 1
