import numpy as np
import pytest
from starlette.testclient import TestClient

from chirp_server.app import create_app
from chirp_server.audio import wav_bytes
from chirp_server.config import Settings
from chirp_server.engine import FakeEngine

TOKEN = "synthetic-test-credential"
HEADERS = {"Authorization": f"Bearer {TOKEN}"}
START = {
    "type": "start",
    "sample_rate": 16000,
    "encoding": "pcm_s16le",
    "client": "mac",
    "correction": False,
}
PCM = (np.sin(np.arange(8000) * 0.1) * 10000).astype("<i2").tobytes()


@pytest.fixture
def settings(tmp_path):
    return Settings(
        config_dir=tmp_path / "config",
        debug_dir=tmp_path / "debug",
        state_path=tmp_path / "state" / "server-state.json",
        idle_seconds=0.2,
        auth_seconds=0.05,
        queue_timeout=0.05,
    )


@pytest.fixture
def engine():
    return FakeEngine()


@pytest.fixture
def client(settings, engine):
    with TestClient(create_app(settings, engine, TOKEN)) as client:
        yield client


@pytest.fixture
def wav():
    return wav_bytes(PCM)
