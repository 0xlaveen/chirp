import logging
import os
import time
from pathlib import Path

from conftest import HEADERS, PCM, START, TOKEN, use_home
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.config import CorrectionConfig, load_token
from chirp_server.engine import FakeEngine
from chirp_server.retention import Retention


def test_no_retention(settings, monkeypatch, tmp_path, caplog):
    home, temp = tmp_path / "home", tmp_path / "temp"
    home.mkdir()
    temp.mkdir()
    use_home(monkeypatch, home)
    monkeypatch.setenv("TMPDIR", str(temp))
    engine = FakeEngine("Private synthetic sentinel zyxwvu.")
    caplog.set_level(logging.INFO)
    with TestClient(create_app(settings, engine, TOKEN)) as client:
        # Observe all Python file opens and deny writing anywhere during the session.
        import builtins

        original_open, original_os_open = builtins.open, os.open
        writes = []

        def checked_open(file, mode="r", *args, **kwargs):
            if isinstance(mode, str) and any(flag in mode for flag in "wax+"):
                writes.append(str(file))
            return original_open(file, mode, *args, **kwargs)

        def checked_os_open(file, flags, *args, **kwargs):
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT):
                writes.append(str(file))
            return original_os_open(file, flags, *args, **kwargs)

        with monkeypatch.context() as patch:
            patch.setattr(builtins, "open", checked_open)
            patch.setattr(os, "open", checked_os_open)
            with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
                ws.send_json(START)
                assert not ws.receive_json()["debug_retention"]
                ws.send_bytes(PCM)
                ws.send_json({"type": "stop"})
                assert final(ws)["raw"] == engine.text
            assert (
                client.post(
                    "/v1/transcribe",
                    headers=HEADERS,
                    content=__import__("chirp_server.audio", fromlist=["wav_bytes"]).wav_bytes(PCM),
                ).status_code
                == 200
            )
        assert writes == []
    assert not list(home.rglob("*"))
    assert not list(temp.rglob("*"))
    assert not settings.debug_dir.exists()
    assert engine.text not in caplog.text
    assert TOKEN not in caplog.text


def test_debug_visibility_permissions_purge(settings):
    settings.debug_retain = True
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        assert client.get("/v1/health", headers=HEADERS).json()["debug_retention"]
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            assert ws.receive_json()["debug_retention"]
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            final(ws)
    files = list(settings.debug_dir.iterdir())
    assert len(files) == 2
    assert settings.debug_dir.stat().st_mode & 0o777 == 0o700
    assert all(p.stat().st_mode & 0o777 == 0o600 for p in files)
    for path in files:
        os.utime(path, (time.time() - 4 * 86400,) * 2)
    assert Retention(settings).purge() == 2
    Retention(settings).save("synthetic", PCM, {})
    assert Retention(settings).purge(all_files=True) == 2


def test_cancel_not_retained(settings):
    settings.debug_retain = True
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            ws.receive_json()
            ws.send_bytes(PCM)
            ws.send_json({"type": "cancel"})
    assert not list(settings.debug_dir.glob("*"))


def test_token_permissions(tmp_path):
    token = load_token(tmp_path)
    assert len(token) >= 32
    assert (tmp_path / "token").stat().st_mode & 0o777 == 0o600
    (tmp_path / "token").chmod(0o644)
    assert load_token(tmp_path) == token
    assert (tmp_path / "token").stat().st_mode & 0o777 == 0o600


def test_external_correction_health(settings):
    settings.correction = CorrectionConfig(
        enabled=True, model="test", base_url="https://llm.example/v1"
    )
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        health = client.get("/v1/health", headers=HEADERS).json()
        assert health["correction_leaves_machine"]
        assert health["correction_host"] == "llm.example"


def test_loopback_hosts():
    for host in ("127.0.0.1", "localhost", "[::1]"):
        assert not CorrectionConfig(
            mode="endpoint", base_url=f"http://{host}:1234/v1"
        ).leaves_machine


def test_no_sensitive_fixture_files_in_repo():
    root = Path(__file__).resolve().parents[1]
    assert not list((root / "fixtures").glob("*.wav"))
