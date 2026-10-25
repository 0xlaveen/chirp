"""Where Chirp keeps its files on each platform.

macOS keeps the paths it has always used. Windows uses the Known Folders: `%APPDATA%\\Chirp` for
the small config that may roam (server.toml, token, devices) and `%LOCALAPPDATA%\\Chirp` for
models, state, debug files and caches, which must never sync. Linux follows XDG.

Everything is resolved on each call from the environment and `Path.home()`, so a different HOME
(or USERPROFILE on Windows) moves every location together.
"""

import os
import sys
from pathlib import Path


def _env_dir(name: str, fallback: Path) -> Path:
    value = os.environ.get(name, "")
    # XDG and Known Folder variables must be absolute; a relative one is ignored.
    return Path(value) if value and os.path.isabs(value) else fallback


def config_dir() -> Path:
    """server.toml, the shared token, devices.json and the model selection."""
    if sys.platform == "win32":
        return _env_dir("APPDATA", Path.home() / "AppData/Roaming") / "Chirp"
    if sys.platform == "darwin":
        return Path.home() / ".config/chirp"
    return _env_dir("XDG_CONFIG_HOME", Path.home() / ".config") / "chirp"


def data_dir() -> Path:
    """Models, runtime state and opt-in debug files."""
    if sys.platform == "win32":
        return _env_dir("LOCALAPPDATA", Path.home() / "AppData/Local") / "Chirp"
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/Chirp"
    return _env_dir("XDG_DATA_HOME", Path.home() / ".local/share") / "chirp"


def cache_dir() -> Path:
    """Regenerable files such as synthetic test fixtures."""
    if sys.platform == "win32":
        return data_dir() / "Cache"
    if sys.platform == "darwin":
        return Path.home() / "Library/Caches/Chirp"
    return _env_dir("XDG_CACHE_HOME", Path.home() / ".cache") / "chirp"


def model_root() -> Path:
    return data_dir() / "models"


def state_path() -> Path:
    return data_dir() / "server-state.json"


def debug_dir() -> Path:
    return data_dir() / "debug"


def fixtures_dir() -> Path:
    return cache_dir() / "fixtures"
