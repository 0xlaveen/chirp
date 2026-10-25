"""Platform locations; every platform's rules are checked on every host."""

import sys
from pathlib import Path

import pytest

from chirp_server import paths
from chirp_server.config import Settings, default_state_path
from chirp_server.engine import models


@pytest.fixture
def home(monkeypatch, tmp_path):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    return tmp_path


def test_macos_keeps_its_historical_paths(monkeypatch, home):
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(home / "ignored"))
    support = home / "Library/Application Support/Chirp"
    assert paths.config_dir() == home / ".config/chirp"
    assert paths.model_root() == support / "models"
    assert paths.state_path() == support / "server-state.json"
    assert paths.debug_dir() == support / "debug"
    assert paths.fixtures_dir() == home / "Library/Caches/Chirp/fixtures"


def test_windows_uses_known_folders(monkeypatch, home):
    monkeypatch.setattr(sys, "platform", "win32")
    roaming, local = home / "Roaming", home / "Local"
    monkeypatch.setenv("APPDATA", str(roaming))
    monkeypatch.setenv("LOCALAPPDATA", str(local))
    assert paths.config_dir() == roaming / "Chirp"
    assert paths.model_root() == local / "Chirp/models"
    assert paths.state_path() == local / "Chirp/server-state.json"
    assert paths.debug_dir() == local / "Chirp/debug"
    assert paths.fixtures_dir() == local / "Chirp/Cache/fixtures"


def test_windows_without_known_folder_variables_uses_the_profile(monkeypatch, home):
    monkeypatch.setattr(sys, "platform", "win32")
    assert paths.config_dir() == home / "AppData/Roaming/Chirp"
    assert paths.data_dir() == home / "AppData/Local/Chirp"


def test_linux_follows_xdg(monkeypatch, home):
    monkeypatch.setattr(sys, "platform", "linux")
    assert paths.config_dir() == home / ".config/chirp"
    assert paths.model_root() == home / ".local/share/chirp/models"
    assert paths.fixtures_dir() == home / ".cache/chirp/fixtures"
    for name, folder in (("XDG_CONFIG_HOME", "c"), ("XDG_DATA_HOME", "d"), ("XDG_CACHE_HOME", "x")):
        monkeypatch.setenv(name, str(home / folder))
    assert paths.config_dir() == home / "c/chirp"
    assert paths.state_path() == home / "d/chirp/server-state.json"
    assert paths.cache_dir() == home / "x/chirp"


def test_relative_xdg_values_are_ignored(monkeypatch, home):
    monkeypatch.setattr(sys, "platform", "linux")
    monkeypatch.setenv("XDG_CONFIG_HOME", "relative/config")
    assert paths.config_dir() == home / ".config/chirp"


def test_settings_and_models_use_platform_paths(monkeypatch, home):
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setenv("APPDATA", str(home / "Roaming"))
    monkeypatch.setenv("LOCALAPPDATA", str(home / "Local"))
    settings = Settings()
    assert settings.config_dir == home / "Roaming/Chirp"
    assert settings.debug_dir == home / "Local/Chirp/debug"
    assert default_state_path() == home / "Local/Chirp/server-state.json"
    assert models.model_root() == home / "Local/Chirp/models"
