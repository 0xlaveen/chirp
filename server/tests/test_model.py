"""Real cached MLX integration; generated speech stays outside the repository."""

import asyncio
import importlib.util
from pathlib import Path

import pytest
from conftest import HEADERS, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.audio import decode_wav, samples
from chirp_server.engine import EngineWorker
from chirp_server.engine.mlx import ParakeetMLX

pytestmark = pytest.mark.model


def fixture_directory():
    path = Path.home() / "Library/Caches/Chirp/fixtures"
    if not (path / "manifest.json").exists():
        spec = importlib.util.spec_from_file_location(
            "generate_fixtures",
            Path(__file__).resolve().parents[1] / "scripts/generate_fixtures.py",
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.generate(path)
    return path


async def test_real_model_decode():
    path = fixture_directory() / "synthetic-5s.wav"
    engine = ParakeetMLX()
    worker = EngineWorker(engine)
    await worker.start()
    try:
        text = await worker.call(engine.transcribe, samples(decode_wav(path.read_bytes())))
        # Do not put transcript text into failure messages or recorded logs.
        assert {"quick", "brown", "fox"}.issubset(set(text.lower().split()))
    finally:
        await worker.close()


def test_real_model_stream(settings):
    settings.idle_seconds = 60
    pcm = decode_wav((fixture_directory() / "synthetic-5s.wav").read_bytes())
    with TestClient(create_app(settings, ParakeetMLX(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            assert ws.receive_json()["type"] == "ready"

            # Wait for each feed so this test exercises incremental decoding rather than coalescing.
            async def paced():
                for offset in range(0, len(pcm), 6400):
                    ws.send_bytes(pcm[offset : offset + 6400])
                    await asyncio.sleep(0.2)

            asyncio.run(paced())
            ws.send_json({"type": "stop"})
            result = final(ws)
            assert result["type"] == "final"
            assert "fox" in result["raw"].lower()
            assert result["timings_ms"]["first_partial"] is not None
