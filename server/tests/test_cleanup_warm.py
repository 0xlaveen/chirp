"""Fake-helper coverage for start prewarm, keep_loaded and the settings endpoint."""

import json
import stat
import sys
import time
from pathlib import Path

import pytest
from conftest import HEADERS, PCM, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.cleanup_models import DEFAULT_MODEL, MODELS
from chirp_server.config import CorrectionConfig, persist_keep_loaded, read_keep_loaded
from chirp_server.correction import Corrector
from chirp_server.engine import FakeEngine
from chirp_server.managed_cleanup import ManagedCleanup

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


def wait_until(condition, timeout=6.0):
    deadline = time.perf_counter() + timeout
    while not condition():
        assert time.perf_counter() < deadline, "timed out waiting for helper state"
        time.sleep(0.01)
    return True


def test_start_prewarms_without_delaying_ack_or_partials(settings):
    corrector = service(command=DELAYED)
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
    corrector = service(command=DELAYED)
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
        assert live["memory_mb"] == 12 and live["memory_estimated"] is False
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
        assert after["memory_mb"] == 12 and after["memory_estimated"] is False


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
    assert stat.S_IMODE(settings.state_path.stat().st_mode) == 0o600
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
