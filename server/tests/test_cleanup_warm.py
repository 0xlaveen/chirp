"""Fake-helper coverage for start prewarm, keep_loaded and the settings endpoint."""

import asyncio
import json
import os
import sys
import time
from pathlib import Path

import pytest
from conftest import HEADERS, PCM, START, TEST_TIMEOUT, TOKEN, has_mode
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.cleanup_models import DEFAULT_MODEL, MODELS
from chirp_server.config import CorrectionConfig, persist_keep_loaded, read_keep_loaded
from chirp_server.correction import Corrector
from chirp_server.engine import FakeEngine
from chirp_server.managed_cleanup import ManagedCleanup, helper_footprint_mb

HELPER = str(Path(__file__).with_name("fake_cleanup_helper.py"))
COMMAND = [sys.executable, "-u", HELPER]
# A slow helper makes the in-flight cold load observable in wall-clock assertions.
DELAYED = COMMAND + ["--delay", "1.0"]
FAILING = COMMAND + ["--fail"]


def service(command=COMMAND, **kwargs):
    config = CorrectionConfig(mode="managed", **kwargs)
    corrector = Corrector(config)
    corrector.managed = ManagedCleanup(config, command=command)
    return corrector


def counted_spawns(managed):
    """Count real subprocess spawns, not no-op _start calls on a live helper."""
    original = managed._start
    spawns = []

    async def start():
        before = managed.process
        await original()
        if managed.process is not before:
            spawns.append(managed.process)

    managed._start = start
    return spawns


def wait_until(condition, timeout=TEST_TIMEOUT):
    deadline = time.perf_counter() + timeout
    while not condition():
        assert time.perf_counter() < deadline, "timed out waiting for helper state"
        time.sleep(0.01)
    return True


def test_start_prewarms_without_delaying_ack_or_partials(settings):
    corrector = service(command=DELAYED, timeout=TEST_TIMEOUT)
    settings.correction = corrector.config
    engine = FakeEngine("please send the schedule")
    with TestClient(create_app(settings, engine, TOKEN, corrector)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            started = time.perf_counter()
            ws.send_json({**START, "correction": True})
            assert ws.receive_json()["type"] == "ready"
            # The 1 s helper load is still in flight, yet the ack arrived immediately.
            assert time.perf_counter() - started < 0.5
            ws.send_bytes(PCM)
            assert ws.receive_json()["type"] == "partial"
            # Keep traffic flowing while the background load finishes.
            while not corrector.managed.loaded:
                ws.send_bytes(PCM[:640])
                time.sleep(0.02)
            ws.send_json({"type": "stop"})
            result = final(ws)
    assert result["corrected"] and result["text"] == "Please send the schedule."
    assert corrector.managed.process is None


async def test_concurrent_prewarms_share_one_load():
    corrector = service(command=DELAYED)
    managed = corrector.managed
    spawns = counted_spawns(managed)
    for _ in range(3):
        managed.prewarm()
    assert managed.loading
    await managed.wait_warm()
    assert len(spawns) == 1 and managed.loaded
    await corrector.close()


def test_prewarm_failure_falls_back_to_raw(settings):
    corrector = service(command=FAILING)
    spawns = counted_spawns(corrector.managed)
    settings.correction = corrector.config
    with TestClient(
        create_app(settings, FakeEngine("please send the schedule"), TOKEN, corrector)
    ) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            result = final(ws)
    # The failed background load falls back to raw exactly as a cold start would;
    # the final retried the load itself once.
    assert result["corrected"] is False
    assert result["correction_error"] == "rejected"
    assert result["text"] == result["raw"] == "please send the schedule"
    assert len(spawns) == 2
    assert corrector.managed.process is None


def test_final_waits_for_inflight_prewarm(settings):
    corrector = service(command=DELAYED, timeout=TEST_TIMEOUT)
    spawns = counted_spawns(corrector.managed)
    settings.correction = corrector.config
    with TestClient(
        create_app(settings, FakeEngine("please send the schedule"), TOKEN, corrector)
    ) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            # Stop immediately: the load is still in flight and the final must wait.
            ws.send_json({"type": "stop"})
            result = final(ws)
    assert result["corrected"] and result["text"] == "Please send the schedule."
    # The whole-call correction budget included waiting for the in-flight load,
    # and no second helper was spawned.
    assert result["timings_ms"]["correction"] > 300
    assert len(spawns) == 1
    assert corrector.managed.process is None


def test_timed_out_final_keeps_shared_prewarm_load(settings):
    # (a) A final whose whole-call timeout fires while the prewarm is still loading
    # falls back to raw; the shared load is not cancelled and later finals reuse it.
    corrector = service(command=DELAYED, timeout=0.5)
    spawns = counted_spawns(corrector.managed)
    settings.correction = corrector.config
    with TestClient(create_app(settings, FakeEngine("hello there"), TOKEN, corrector)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            result = final(ws)
        assert result["corrected"] is False
        assert result["correction_error"] == "timeout"
        assert result["text"] == result["raw"] == "hello there"
        # The load outlived the timed-out final and completes (a live pid alone
        # would still be mid-load; the load task must be done).
        assert wait_until(lambda: corrector.managed.loaded and not corrector.managed.loading)
        # The warm final reuses the shared load: it must not race the 0.5 s budget
        # that produced the intended timeout above.
        corrector.config.timeout = TEST_TIMEOUT
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            warm = final(ws)
    assert warm["corrected"] and warm["text"] == "Hello there."
    assert len(spawns) == 1


async def test_one_timed_out_final_does_not_cancel_shared_load():
    # (b) Two finals wait on one in-flight load; the one that times out must not
    # cancel the load the other is still waiting on.
    corrector = service(command=DELAYED, timeout=TEST_TIMEOUT)
    managed = corrector.managed
    spawns = counted_spawns(managed)
    first = asyncio.create_task(managed.generate("first", "p"))
    await asyncio.sleep(0.05)  # settle into the shared-load wait
    managed.config.timeout = 0.05
    with pytest.raises(TimeoutError):
        await managed.generate("second", "p")
    text, finish = await first
    assert text == "First." and finish == "stop"
    assert managed.loaded and len(spawns) == 1
    await corrector.close()


def test_cancel_during_prewarm_wait_suppresses_only_that_final(settings):
    # (c) An utterance cancel while the final waits on the prewarm suppresses only
    # that final; the shared load survives and warms the next utterance.
    corrector = service(command=DELAYED, timeout=TEST_TIMEOUT)
    settings.correction = corrector.config
    with TestClient(create_app(settings, FakeEngine("hello there"), TOKEN, corrector)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            message = ws.receive_json()
            while message["type"] == "partial":
                message = ws.receive_json()
            assert message["type"] == "correcting"
            ws.send_json({"type": "cancel"})
            # No final follows the cancel; the reused socket serves the next start.
            ws.send_json({**START, "correction": True})
            response = ws.receive_json()
            while response["type"] == "partial":
                response = ws.receive_json()
            assert response["type"] == "ready"
            assert wait_until(lambda: corrector.managed.loaded)
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            result = final(ws)
    assert result["corrected"] and result["text"] == "Hello there."


def test_helper_footprint_mb_reads_this_process():
    value = helper_footprint_mb(os.getpid())
    if sys.platform == "darwin":
        assert isinstance(value, int) and value > 0
    else:
        assert value is None
    assert helper_footprint_mb(-1) is None


def test_cancelled_start_leaves_warm_helper_on_idle_timer(settings):
    corrector = service(command=DELAYED, idle_seconds=0.15)
    settings.correction = corrector.config
    with TestClient(create_app(settings, FakeEngine("hello there"), TOKEN, corrector)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            assert ws.receive_json()["type"] == "ready"
            # Cancel while the load is still in flight.
            ws.send_json({"type": "cancel"})
        # The utterance is gone, but the background load completes anyway...
        assert wait_until(lambda: corrector.managed.loaded)
        process = corrector.managed.process
        assert process is not None
        # ...then the normal idle timer unloads the warm helper.
        assert wait_until(lambda: corrector.managed.process is None)
        assert wait_until(lambda: process.returncode is not None)


def test_keep_loaded_settings_lifecycle(settings):
    corrector = service(idle_seconds=0.05)
    settings.correction = corrector.config
    with TestClient(create_app(settings, FakeEngine("hello there"), TOKEN, corrector)) as client:
        initial = client.get("/v1/correction/settings", headers=HEADERS).json()
        assert initial == {
            "keep_loaded": False,
            "loaded": False,
            "loading": False,
            "model": DEFAULT_MODEL,
            "memory_mb": MODELS[DEFAULT_MODEL].memory_mb,
            "memory_estimated": True,
            "mode": "managed",
        }
        put = client.put("/v1/correction/settings", headers=HEADERS, json={"keep_loaded": True})
        assert put.status_code == 200
        assert put.json()["keep_loaded"] is True
        # PUT true starts a background load immediately.
        assert wait_until(lambda: corrector.managed.loaded)
        # keep_loaded blocks the idle unload...
        time.sleep(0.3)
        assert corrector.managed.loaded
        live = client.get("/v1/correction/settings", headers=HEADERS).json()
        assert live["loaded"] is True and live["loading"] is False
        assert isinstance(live["memory_mb"], int) and live["memory_mb"] > 0
        assert live["memory_estimated"] is False
        health = client.get("/v1/health", headers=HEADERS).json()
        assert health["correction_keep_loaded"] is True
        assert health["correction_loaded"] is True
        # ...until it is turned off again, which re-arms the idle timer.
        off = client.put("/v1/correction/settings", headers=HEADERS, json={"keep_loaded": False})
        assert off.status_code == 200 and off.json()["keep_loaded"] is False
        assert wait_until(lambda: corrector.managed.process is None)
        after = client.get("/v1/correction/settings", headers=HEADERS).json()
        assert after["loaded"] is False and after["loading"] is False
        # The last measured memory survives the unload.
        assert after["memory_mb"] == live["memory_mb"] and after["memory_estimated"] is False


def test_keep_loaded_persists_and_overrides_toml(settings):
    corrector = service()
    settings.correction = corrector.config
    with TestClient(create_app(settings, FakeEngine("hello there"), TOKEN, corrector)) as client:
        assert (
            client.put(
                "/v1/correction/settings", headers=HEADERS, json={"keep_loaded": True}
            ).status_code
            == 200
        )
    assert has_mode(settings.state_path, 0o600)
    assert json.loads(settings.state_path.read_text()) == {"correction_keep_loaded": True}
    assert read_keep_loaded(settings.state_path) is True
    # A restarted server applies the persisted override over the toml default and
    # prewarms at startup.
    second = service(keep_loaded=False)
    settings.correction = second.config
    with TestClient(create_app(settings, FakeEngine(), TOKEN, second)) as client:
        assert wait_until(lambda: second.managed.loaded)
        body = client.get("/v1/correction/settings", headers=HEADERS).json()
        assert body["keep_loaded"] is True
        health = client.get("/v1/health", headers=HEADERS).json()
        assert health["correction_keep_loaded"] is True and health["correction_loaded"] is True


def test_state_override_false_wins_over_toml_true(settings):
    persist_keep_loaded(settings.state_path, False)
    corrector = service(keep_loaded=True)
    settings.correction = corrector.config
    with TestClient(create_app(settings, FakeEngine(), TOKEN, corrector)) as client:
        time.sleep(0.1)
        # No startup prewarm: the override turned keep_loaded off.
        assert corrector.managed.process is None
        body = client.get("/v1/correction/settings", headers=HEADERS).json()
        assert body["keep_loaded"] is False and body["loaded"] is False
        health = client.get("/v1/health", headers=HEADERS).json()
        assert health["correction_keep_loaded"] is False


@pytest.mark.parametrize(
    "content",
    [
        "",
        "not json",
        "[]",
        "{}",
        '{"keep_loaded": "yes"}',
        '{"keep_loaded": 1}',
        '{"keep_loaded": null}',
        '{"keep_loaded": true, "extra": 1}',
    ],
)
def test_put_settings_rejects_invalid_bodies(settings, content):
    corrector = service()
    settings.correction = corrector.config
    with TestClient(create_app(settings, FakeEngine(), TOKEN, corrector)) as client:
        response = client.put("/v1/correction/settings", headers=HEADERS, content=content)
    assert response.status_code == 400
    assert response.json()["code"] == "bad_request"
    assert not settings.state_path.exists()


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}])
def test_settings_endpoints_require_auth(settings, headers):
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        get = client.get("/v1/correction/settings", headers=headers)
        assert get.status_code == 401
        assert get.headers["www-authenticate"] == "Bearer"
        put = client.put("/v1/correction/settings", headers=headers, json={"keep_loaded": True})
        assert put.status_code == 401
        assert put.headers["www-authenticate"] == "Bearer"
        assert not settings.state_path.exists()


@pytest.mark.parametrize("mode", ["off", "endpoint"])
def test_put_settings_unsupported_outside_managed(settings, mode):
    settings.correction = CorrectionConfig(mode=mode)
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        put = client.put("/v1/correction/settings", headers=HEADERS, json={"keep_loaded": True})
        assert put.status_code == 409
        assert put.json()["code"] == "unsupported"
        get = client.get("/v1/correction/settings", headers=HEADERS).json()
        assert get == {
            "keep_loaded": False,
            "loaded": False,
            "loading": False,
            "model": None,
            "memory_mb": None,
            "memory_estimated": False,
            "mode": mode,
        }
        assert not settings.state_path.exists()


async def test_keep_loaded_helper_has_no_idle_exit_of_its_own():
    # The helper's own idle exit used to end a keep_loaded helper ~idle_seconds + 5 s after
    # its last call; with keep_loaded it is launched with 0 (no self-timeout).
    corrector = service(idle_seconds=0.2)
    managed = corrector.managed
    managed.keep_loaded = True
    managed.prewarm()
    await managed.wait_warm()
    assert managed.loaded and managed.launched_idle == 0
    await corrector.close()

    corrector = service(idle_seconds=0.2)
    managed = corrector.managed
    managed.prewarm()
    await managed.wait_warm()
    assert managed.launched_idle == 0.2
    await corrector.close()


async def test_turning_keep_loaded_on_relaunches_a_self_timing_helper():
    corrector = service(idle_seconds=30)
    managed = corrector.managed
    spawns = counted_spawns(managed)
    managed.prewarm()
    await managed.wait_warm()
    assert managed.launched_idle == 30
    await managed.set_keep_loaded(True)
    managed.prewarm()
    await managed.wait_warm()
    assert len(spawns) == 2 and managed.loaded and managed.launched_idle == 0
    # Already without a self-timeout: turning it on again keeps the same helper.
    await managed.set_keep_loaded(True)
    managed.prewarm()
    await managed.wait_warm()
    assert len(spawns) == 2
    # Off: the server's own idle timer unloads it.
    await managed.set_keep_loaded(False)
    assert managed.idle is not None
    await corrector.close()
