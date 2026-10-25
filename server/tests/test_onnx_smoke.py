"""Real ONNX Parakeet on a real `chirp-server` process: the portable engine end to end.

Runs with `pytest -m onnx` when the int8 ONNX model is present (CHIRP_ONNX_MODEL_DIR, or the
location `chirp-server model fetch --engine onnx` writes). CI runs it on Linux and Windows. The
speech is a committed synthetic clip (macOS `say`), never a recording of a person.
"""

import json
import os
import re
import socket
import subprocess
import sys
import time
import wave
from pathlib import Path

import httpx
import pytest
from websockets.sync.client import connect

from chirp_server import fsutil, paths

pytestmark = pytest.mark.onnx

WAV = Path(__file__).parent / "fixtures/synthetic-fox.wav"
KEYWORDS = {"quick", "brown", "fox", "schedule"}


def model_dir() -> Path:
    if explicit := os.environ.get("CHIRP_ONNX_MODEL_DIR"):
        return Path(explicit)
    for candidate in (
        paths.model_root() / "parakeet-onnx",
        Path.home() / ".koi/voice-models/parakeet-onnx",
    ):
        if (candidate / "encoder-model.int8.onnx").is_file():
            return candidate
    pytest.skip("ONNX model missing; run chirp-server model fetch --engine onnx")


def words(text: str) -> set[str]:
    return set(re.findall(r"\b\w+\b", text.lower()))


def assert_fixture_keywords(text: str):
    recognized = words(text)
    # This int8 model sometimes inflects the synthetic imperative as "scheduled".
    # Keep the second sentence in the contract without making this a WER benchmark.
    if "scheduled" in recognized:
        recognized.add("schedule")
    assert KEYWORDS <= recognized, "ONNX smoke missed synthetic fixture keywords"


@pytest.fixture
def server(tmp_path, monkeypatch):
    """A throwaway server on a free port with every platform directory under tmp_path."""
    model = model_dir()
    home = tmp_path / "home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "USERPROFILE": str(home),
        "APPDATA": str(home / "Roaming"),
        "LOCALAPPDATA": str(home / "Local"),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "PYTHONUNBUFFERED": "1",
    }
    for name in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME"):
        monkeypatch.setenv(name, env[name])
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    log = tmp_path / "server.log"
    with log.open("wb") as sink:
        process = subprocess.Popen(
            [sys.executable, "-m", "chirp_server", "--engine", "onnx"]
            + ["--model-dir", str(model), "--port", str(port)],
            env=env,
            stdout=sink,
            stderr=subprocess.STDOUT,
        )
    base = f"http://127.0.0.1:{port}"
    token_path = paths.config_dir() / "token"
    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            assert process.poll() is None, log.read_text(errors="replace")
            if token_path.is_file():
                token = token_path.read_text().strip()
                try:
                    health = httpx.get(
                        f"{base}/v1/health",
                        headers={"Authorization": f"Bearer {token}"},
                        timeout=2,
                        trust_env=False,
                    ).json()
                    if health.get("ready") is True:
                        break
                except httpx.HTTPError:
                    pass
            time.sleep(0.5)
        else:
            pytest.fail("server did not become ready:\n" + log.read_text(errors="replace"))
        yield base, token, token_path, log, health
    finally:
        process.terminate()
        try:
            process.wait(15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


@pytest.mark.parametrize("client_name", ["android", "desktop"])
def test_onnx_server_transcribes_and_streams(server, client_name):
    base, token, token_path, log, health = server
    assert health["engine"].startswith("parakeet-onnx")
    assert fsutil.is_private(token_path)
    assert fsutil.is_private(token_path.parent)
    headers = {"Authorization": f"Bearer {token}"}
    wrong = {"Authorization": "Bearer wrong"}
    assert httpx.post(f"{base}/v1/transcribe", content=b"", headers=wrong).status_code == 401

    response = httpx.post(
        f"{base}/v1/transcribe", content=WAV.read_bytes(), headers=headers, timeout=120
    )
    assert response.status_code == 200
    # Never print transcripts; compare keyword sets only.
    assert_fixture_keywords(response.json()["text"])

    with wave.open(str(WAV), "rb") as clip:
        pcm = clip.readframes(clip.getnframes())
    ws_url = base.replace("http://", "ws://") + "/v1/stream"
    with connect(ws_url, additional_headers=wrong, max_size=2**20) as rejected:
        assert json.loads(rejected.recv(timeout=5))["code"] == "auth"
    with connect(ws_url, additional_headers=headers, max_size=2**20) as ws:
        start = {
            "type": "start",
            "sample_rate": 16000,
            "encoding": "pcm_s16le",
            "client": client_name,
        }
        ws.send(json.dumps(start))
        assert json.loads(ws.recv(timeout=30))["type"] == "ready"
        # 100 ms frames, paced a little faster than real time.
        for offset in range(0, len(pcm), 3200):
            ws.send(pcm[offset : offset + 3200])
            time.sleep(0.05)
        ws.send(json.dumps({"type": "stop"}))
        partials, final = 0, None
        while final is None:
            message = json.loads(ws.recv(timeout=120))
            assert message["type"] != "error", message.get("code")
            partials += message["type"] == "partial"
            final = message if message["type"] == "final" else None
    assert partials >= 1
    assert_fixture_keywords(final["text"])
    assert final["timings_ms"]["first_partial"] is not None

    # The server log never holds what was said.
    text = log.read_text(errors="replace").lower()
    assert not any(word in text for word in ("brown fox", "schedule"))
