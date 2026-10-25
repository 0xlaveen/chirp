import numpy as np
import pytest
from starlette.testclient import TestClient

from chirp_server.app import create_app
from chirp_server.audio import wav_bytes
from chirp_server.config import Settings
from chirp_server.engine import FakeEngine
from chirp_server.speakers import SpeakerLabels

TOKEN = "synthetic-test-credential"
HEADERS = {"Authorization": f"Bearer {TOKEN}"}
# Managed-mode budgets must cover spawning the fake helper, which can take seconds on
# a loaded host. Every call that expects a completion (or a fast non-timeout failure)
# uses this generous test-only budget so host load cannot turn it into error='timeout';
# only calls whose expected result IS a timeout keep a short wall-clock budget.
TEST_TIMEOUT = 60.0
START = {
    "type": "start",
    "sample_rate": 16000,
    "encoding": "pcm_s16le",
    "client": "mac",
    "correction": False,
}
PCM = (np.sin(np.arange(8000) * 0.1) * 10000).astype("<i2").tobytes()


@pytest.fixture(autouse=True)
def _home_relative_dirs(monkeypatch):
    """Every platform location (paths.py) follows the home directory in tests."""
    for name in ("APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
        monkeypatch.delenv(name, raising=False)


def use_home(monkeypatch, path):
    """Point Path.home() at `path`: HOME on POSIX, USERPROFILE on Windows."""
    monkeypatch.setenv("HOME", str(path))
    monkeypatch.setenv("USERPROFILE", str(path))


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
def speakers():
    # Never the host's model cache: labels report the model as not downloaded.
    return SpeakerLabels(downloaded=lambda: False)


@pytest.fixture
def client(settings, engine, speakers):
    with TestClient(create_app(settings, engine, TOKEN, speakers=speakers)) as client:
        yield client


@pytest.fixture
def wav():
    return wav_bytes(PCM)
