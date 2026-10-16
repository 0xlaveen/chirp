import asyncio
import json

import httpx
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


def corrector(reply=CLEAN, status=200, finish="stop"):
    config = CorrectionConfig(enabled=True, model="test-model")

    def handle(request):
        payload = json.loads(request.content)
        assert json.loads(payload["messages"][1]["content"].split(": ", 1)[1]) == RAW
        return httpx.Response(
            status, json={"choices": [{"message": {"content": reply}, "finish_reason": finish}]}
        )

    return Corrector(config, httpx.MockTransport(handle))


async def test_correction_success():
    result = await corrector().process(RAW)
    assert result.text == CLEAN and result.corrected and result.error is None


@pytest.mark.parametrize(
    "reply,finish",
    [
        ("", "stop"),
        ("Sure, here is the answer", "stop"),
        (CLEAN, "length"),
        ("unrelated nonsense", "stop"),
    ],
)
async def test_rejected(reply, finish):
    result = await corrector(reply, finish=finish).process(RAW)
    assert result.text == RAW and result.error == "rejected"


async def test_http_error():
    result = await corrector(status=503).process(RAW)
    assert result.text == RAW and result.error == "http"


async def test_timeout():
    async def handle(request):
        await asyncio.Event().wait()

    result = await Corrector(
        CorrectionConfig(enabled=True, timeout=0.01), httpx.MockTransport(handle)
    ).process(RAW)
    assert result.text == RAW and result.error == "timeout"


@pytest.mark.parametrize(
    "server_enabled,client_enabled", [(False, True), (True, False), (True, True)]
)
def test_correction_final_opt_in_only(settings, server_enabled, client_enabled):
    calls = []

    async def handle(request):
        calls.append(request)
        return httpx.Response(
            200, json={"choices": [{"message": {"content": CLEAN}, "finish_reason": "stop"}]}
        )

    settings.correction = CorrectionConfig(enabled=server_enabled, model="test")
    service = Corrector(settings.correction, httpx.MockTransport(handle))
    with TestClient(create_app(settings, FakeEngine(RAW), TOKEN, service)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": client_enabled})
            ws.receive_json()
            ws.send_bytes(PCM)
            assert ws.receive_json()["text"] == RAW
            assert not calls
            ws.send_json({"type": "stop"})
            result = final(ws)
    assert len(calls) == int(server_enabled and client_enabled)
    assert result["text"] == (CLEAN if calls else RAW)
    assert result["raw"] == RAW
