import os
import stat
import sys
from pathlib import Path

import numpy as np
import pytest
from starlette.testclient import TestClient

from chirp_server import voices
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


@pytest.fixture(autouse=True)
def _voices_dir(monkeypatch, tmp_path):
    """Saved voices (#247) are never the host's: every library a test makes lives in tmp_path."""
    monkeypatch.setattr(voices, "directory", lambda: tmp_path / "saved-voices")


@pytest.fixture
def launchd(monkeypatch):
    """Exercise the macOS LaunchAgent code on any host; launchctl itself is always faked."""
    monkeypatch.setattr(sys, "platform", "darwin")
    if not hasattr(os, "getuid"):
        # Only builds gui/<uid> strings; 0 matches what Windows reports as st_uid, which
        # pytest's temporary-directory ownership check compares against.
        monkeypatch.setattr(os, "getuid", lambda: 0, raising=False)


def pytest_make_parametrize_id(config, val, argname):
    """Short ids for long string/bytes parameters: pytest puts the test id in the
    PYTEST_CURRENT_TEST variable, and Windows caps environment variables at 32,767 characters."""
    if isinstance(val, str | bytes) and len(val) > 80:
        return f"{type(val).__name__}-{len(val)}"
    return None


def has_mode(path, mode) -> bool:
    """Owner-only access: exactly `mode` on POSIX; an owner-only access list on Windows, which
    has no mode bits."""
    if sys.platform == "win32":
        from chirp_server.fsutil import is_private

        return is_private(path)
    return stat.S_IMODE(Path(path).lstat().st_mode) == mode


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
