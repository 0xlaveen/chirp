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


def test_real_model_retranscribe_parity_priority_and_privacy(
    settings, tmp_path, monkeypatch, caplog
):
    """Kept synthetic speech decodes identically, with live audio ahead of the next clip."""
    import logging
    import threading

    from conftest import use_home

    from chirp_server.activity import Activity
    from chirp_server.engine.models import discover as speech_model

    pcm = decode_wav((fixture_directory() / "synthetic-5s.wav").read_bytes())
    model_dir = speech_model()
    home = tmp_path / "home"
    home.mkdir()
    use_home(monkeypatch, home)
    settings.idle_seconds = 60
    settings.queue_timeout = settings.retranscribe_queue_timeout = 60
    caplog.set_level(logging.INFO, logger="chirp")
    engine = ParakeetMLX(model_dir)
    app = create_app(settings, engine, TOKEN)
    lease = app.state.worker.lease
    acquire = lease.acquire
    queued_replay, queued_live = threading.Event(), threading.Event()

    async def observed_acquire(*, retranscribe=False):
        if lease.locked():
            (queued_replay if retranscribe else queued_live).set()
        return await acquire(retranscribe=retranscribe)

    lease.acquire = observed_acquire
    results = []

    def send_audio(ws):
        for offset in range(0, len(pcm), 3200):  # Buffered clips, at most 100 ms per frame.
            ws.send_bytes(pcm[offset : offset + 3200])

    options = {**START, "word_timings": True, "correction_profile": "live_notes"}
    with TestClient(app) as client:
        before = {p for p in tmp_path.rglob("*") if p.is_file()}
        with (
            client.websocket_connect("/v1/stream", headers=HEADERS) as first,
            client.websocket_connect("/v1/stream", headers=HEADERS) as replay,
            client.websocket_connect("/v1/stream", headers=HEADERS) as live,
        ):
            first.send_json({**options, "retranscribe": True})
            ready = first.receive_json()
            assert ready["type"] == "ready" and not ready["debug_retention"]
            send_audio(first)
            replay.send_json({**options, "retranscribe": True})
            assert queued_replay.wait(10)
            live.send_json(options)
            assert queued_live.wait(10)
            first.send_json({"type": "stop"})
            result = first.receive_json()  # No partial may precede the final.
            assert result["type"] == "final" and result["engine"] == ready["engine"]
            assert result["timings_ms"]["first_partial"] is None
            results.append(result)
            assert live.receive_json()["type"] == "ready"
            live.send_bytes(pcm[:6400])
            assert live.receive_json()["type"] == "partial"
            for offset in range(6400, len(pcm), 3200):
                live.send_bytes(pcm[offset : offset + 3200])
            live.send_json({"type": "stop"})
            results.append(final(live))
            assert replay.receive_json()["type"] == "ready"
            send_audio(replay)
            replay.send_json({"type": "stop"})
            result = replay.receive_json()
            assert result["type"] == "final" and result["timings_ms"]["first_partial"] is None
            results.append(result)
    # Booleans keep synthetic transcript text out of pytest assertion output.
    same_text = all(r["raw"] == results[0]["raw"] == r["text"] for r in results)
    assert same_text
    same_words = all(r["words"] == results[0]["words"] for r in results)
    assert same_words
    keywords_match = {"quick", "brown", "fox"} <= set(results[0]["raw"].lower().split())
    assert keywords_match
    assert {p for p in tmp_path.rglob("*") if p.is_file()} - before == {settings.activity_path}
    activity = settings.activity_path.read_text()
    events = Activity(settings.activity_path).events
    replay_events = [e for e in events if e["kind"] == "notes_retranscribe"]
    assert len(replay_events) == 2
    assert all(e["audio_ms"] == len(pcm) // 32 and e["outcome"] == "ok" for e in replay_events)
    no_content = all(
        word not in caplog.text.lower() and word not in activity.lower()
        for word in ("quick", "brown", "fox")
    )
    assert no_content
    assert TOKEN not in caplog.text and TOKEN not in activity
