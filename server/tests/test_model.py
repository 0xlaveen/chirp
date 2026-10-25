"""Real cached MLX integration; generated speech stays outside the repository."""

import asyncio
import importlib.util
import time
from pathlib import Path

import pytest
from conftest import HEADERS, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.audio import decode_wav, samples
from chirp_server.cleanup_models import discover
from chirp_server.config import CorrectionConfig
from chirp_server.engine import EngineWorker
from chirp_server.engine.mlx import ParakeetMLX
from chirp_server.managed_cleanup import ManagedCleanup
from chirp_server.paths import fixtures_dir

pytestmark = pytest.mark.model


def fixture_directory():
    path = fixtures_dir()
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
        keywords_match = {"quick", "brown", "fox"}.issubset(set(text.lower().split()))
        assert keywords_match
    finally:
        await worker.close()


async def test_prewarm_first_final_faster_than_cold():
    """A start-triggered prewarm overlaps the cold load, so the first final that
    uses the warm helper lands far faster than an un-prewarmed cold first final."""
    try:
        discover()
    except ValueError:
        pytest.skip("cleanup weights missing; explicitly run model fetch --cleanup")
    config = CorrectionConfig(mode="managed", timeout=120, idle_seconds=60)
    raw = "um, so, please send the project schedule tomorrow"
    prompt = "Fix punctuation and casing only. Change nothing else."
    cold = ManagedCleanup(config)
    try:
        started = time.perf_counter()
        await cold.generate(raw, prompt)
        cold_ms = (time.perf_counter() - started) * 1000
    finally:
        await cold.close()
    warm = ManagedCleanup(config)
    try:
        warm.prewarm()
        await warm.wait_warm()
        started = time.perf_counter()
        await warm.generate(raw, prompt)
        warm_ms = (time.perf_counter() - started) * 1000
        assert warm_ms < cold_ms
    finally:
        await warm.close()


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
            keyword_match = "fox" in result["raw"].lower()
            assert keyword_match
            assert result["timings_ms"]["first_partial"] is not None


def test_real_model_word_timings_align_with_text(settings):
    """Every partial's and the final's words join back into its text, with monotonic times
    inside the audio; words older than the preview window become stable."""
    settings.idle_seconds = 60
    pcm = decode_wav((fixture_directory() / "synthetic-15s.wav").read_bytes())
    seconds = len(pcm) / 32000
    with TestClient(create_app(settings, ParakeetMLX(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "word_timings": True})
            assert ws.receive_json()["type"] == "ready"

            async def paced():
                for offset in range(0, len(pcm), 6400):
                    ws.send_bytes(pcm[offset : offset + 6400])
                    await asyncio.sleep(0.2)

            asyncio.run(paced())
            ws.send_json({"type": "stop"})
            partials, result = [], None
            while result is None:
                message = ws.receive_json()
                if message["type"] == "partial":
                    partials.append(message)
                elif message["type"] in {"final", "error"}:
                    result = message
    assert result["type"] == "final"
    assert partials and all("words" in p for p in partials)
    for message in [*partials, result]:
        words = message["words"]
        text = message.get("raw", message.get("text"))
        joined_matches = " ".join(w["text"] for w in words) == text
        assert joined_matches
        assert all(0 <= w["start"] <= w["end"] <= seconds + 0.5 for w in words)
        assert all(a["start"] <= b["start"] for a, b in zip(words, words[1:], strict=False))
    assert all(w["stable"] for w in result["words"])
    stable_seen = any(w["stable"] for w in partials[-1]["words"])
    assert stable_seen
    assert not any(w["stable"] for w in partials[0]["words"])
