import asyncio
import sys
from pathlib import Path

import pytest
from conftest import HEADERS, PCM, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.cleanup_models import MODELS, discover, fetch
from chirp_server.config import CorrectionConfig, Settings
from chirp_server.correction import Corrector
from chirp_server.engine import FakeEngine
from chirp_server.managed_cleanup import ManagedCleanup

COMMAND = [sys.executable, "-u", str(Path(__file__).with_name("fake_cleanup_helper.py"))]


def service(**kwargs):
    config = CorrectionConfig(mode="managed", **kwargs)
    corrector = Corrector(config)
    corrector.managed = ManagedCleanup(config, command=COMMAND)
    return corrector


async def test_warm_reuse_and_close():
    corrector = service()
    try:
        first = await corrector.process("please send the schedule")
        process = corrector.managed.process
        second = await corrector.process("please update the schedule")
        assert first.corrected and second.corrected
        assert corrector.managed.process is process
    finally:
        await corrector.close()
    assert process.returncode is not None


@pytest.mark.parametrize(
    "raw,error", [("hang", "timeout"), ("crash", "rejected"), ("invalid", "rejected")]
)
async def test_failures_recover(raw, error):
    corrector = service(timeout=0.15)
    try:
        result = await corrector.process(raw)
        assert result.error == error and result.text == raw
        assert corrector.managed.process is None
        assert (await corrector.process("hello")).corrected
    finally:
        await corrector.close()


async def test_cancel_kills_pending_helper():
    corrector = service()
    pending = asyncio.create_task(corrector.process("hang"))
    # Hand the subprocess time to finish its handshake; no real-model work here.
    await asyncio.sleep(0.1)
    process = corrector.managed.process
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    assert process.returncode is not None
    assert (await corrector.process("hello")).corrected
    await corrector.close()


async def test_idle_unload_and_reload():
    corrector = service(idle_seconds=0.02)
    await corrector.process("hello")
    process = corrector.managed.process
    await asyncio.wait_for(process.wait(), 2)
    assert corrector.managed.process is None
    assert (await corrector.process("hello")).corrected
    await corrector.close()


async def test_queue_timeout_preserves_owner():
    corrector = service(timeout=1)
    pending = asyncio.create_task(corrector.process("hang"))
    await asyncio.sleep(0.1)
    process = corrector.managed.process
    corrector.config.timeout = 0.02
    result = await corrector.process("hello")
    assert result.error == "timeout"
    assert corrector.managed.process is process and process.returncode is None
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    await corrector.close()


def test_managed_protocol(settings):
    corrector = service()
    settings.correction = corrector.config
    with TestClient(
        create_app(settings, FakeEngine("please send the schedule"), TOKEN, corrector)
    ) as client:
        health = client.get("/v1/health", headers=HEADERS).json()
        assert health["correction_mode"] == "managed"
        assert not health["correction_leaves_machine"] and health["correction_host"] is None
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            ws.receive_json()
            ws.send_bytes(PCM)
            partial = ws.receive_json()
            assert partial["text"] == "please send the schedule"
            assert corrector.managed.process is None
            ws.send_json({"type": "stop"})
            result = final(ws)
            assert result["corrected"] and result["raw"] == partial["text"]
            assert result["text"] == "Please send the schedule."
    assert corrector.managed.process is None


@pytest.mark.parametrize("mode", ["off", "managed", "endpoint"])
def test_config_modes(mode, tmp_path):
    path = tmp_path / "server.toml"
    path.write_text(f'[correction]\nmode = "{mode}"\n')
    config = Settings.read(path).correction
    assert config.enabled == (mode != "off")
    assert not config.leaves_machine


@pytest.mark.parametrize(
    "kwargs",
    [
        {"mode": "invalid"},
        {"timeout": float("nan")},
        {"idle_seconds": 0},
        {"mode": "endpoint", "base_url": "file:///tmp/example"},
        {"mode": "endpoint", "base_url": "https://user:secret@example.com/v1"},
    ],
)
def test_invalid_config(kwargs):
    with pytest.raises(ValueError):
        CorrectionConfig(**kwargs)


def test_explicit_off_overrides_legacy_enabled():
    assert not CorrectionConfig(mode="off", enabled=True).enabled
    assert CorrectionConfig(enabled=True).mode == "endpoint"


def test_pinned_cache_only_and_explicit_fetch(monkeypatch, tmp_path):
    calls = []

    def snapshot(repository, **kwargs):
        calls.append((repository, kwargs))
        return str(tmp_path)

    monkeypatch.setattr("huggingface_hub.snapshot_download", snapshot)
    for name in ["config.json", "tokenizer_config.json", "model.safetensors"]:
        (tmp_path / name).write_text("{}")
    discover()
    fetch()
    assert calls[0][1]["local_files_only"] is True
    assert "local_files_only" not in calls[1][1]
    assert all(len(kwargs["revision"]) == 40 for _, kwargs in calls)
    assert len(MODELS) >= 3


async def test_missing_model_falls_back_without_fetch(monkeypatch):
    def missing(*args):
        raise ValueError("missing")

    monkeypatch.setattr("chirp_server.managed_cleanup.discover", missing)
    corrector = Corrector(CorrectionConfig(mode="managed"))
    result = await corrector.process("hello")
    assert result.text == "hello" and result.error == "rejected"
    assert corrector.managed.process is None


def test_cancel_pending_managed_cleanup_keeps_socket_usable(settings, monkeypatch):
    import threading

    corrector = service()
    settings.correction = corrector.config
    settings.debug_retain = True
    reading = threading.Event()
    original = corrector.managed._read
    reads = 0

    async def read():
        nonlocal reads
        reads += 1
        if reads == 2:
            reading.set()
        return await original()

    monkeypatch.setattr(corrector.managed, "_read", read)
    with TestClient(create_app(settings, FakeEngine("hang"), TOKEN, corrector)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True})
            ws.receive_json()
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            response = ws.receive_json()
            while response["type"] == "partial":
                response = ws.receive_json()
            assert response == {
                "type": "correcting",
                "seq": response["seq"],
                "raw": "hang",
                "profile": "default",
            }
            assert reading.wait(3)
            process = corrector.managed.process
            ws.send_json({"type": "cancel"})
            ws.send_json(START)
            response = ws.receive_json()
            while response["type"] == "partial":
                response = ws.receive_json()
            assert response["type"] == "ready"
            assert process.returncode is not None
            assert not list(settings.debug_dir.glob("*"))
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            assert final(ws)["raw"] == "hang"
