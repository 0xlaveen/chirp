"""Configuration and local credentials; never log configuration objects."""

import contextlib
import ipaddress
import json
import math
import os
import secrets
import stat
import tomllib
from dataclasses import dataclass, field, replace
from pathlib import Path
from urllib.parse import urlsplit
from uuid import uuid4

from .profiles import MAX_PROMPT_CHARS, Profile, resolve_profiles


@dataclass
class CorrectionConfig:
    # Legacy enabled=true maps to endpoint only when mode is omitted.
    enabled: bool = False
    mode: str | None = None
    base_url: str = "http://127.0.0.1:1234/v1"
    model: str = ""
    prompt: str = ""
    timeout: float = 8.0
    api_key_env: str = "CHIRP_LLM_API_KEY"
    keychain_service: str = ""
    idle_seconds: float = 60.0
    keep_loaded: bool = False
    profiles: dict = field(default_factory=dict)
    resolved_profiles: dict[str, Profile] = field(init=False, repr=False)

    def __post_init__(self):
        if not isinstance(self.prompt, str) or len(self.prompt) > MAX_PROMPT_CHARS:
            raise ValueError("Invalid correction prompt")
        if not isinstance(self.keep_loaded, bool):
            raise ValueError("Invalid keep_loaded")
        self.resolved_profiles = resolve_profiles(self.profiles)
        if self.prompt and "prompt" not in self.profiles.get("default", {}):
            self.resolved_profiles["default"] = replace(
                self.resolved_profiles["default"], prompt=self.prompt
            )
        self.mode = self.mode if self.mode is not None else ("endpoint" if self.enabled else "off")
        if self.mode not in {"off", "managed", "endpoint"}:
            raise ValueError("Invalid correction mode")
        self.enabled = self.mode != "off"
        if any(not math.isfinite(v) or v <= 0 for v in (self.timeout, self.idle_seconds)):
            raise ValueError("Invalid correction limits")
        if self.mode == "endpoint":
            url = urlsplit(self.base_url)
            if (
                url.scheme not in {"http", "https"}
                or not url.hostname
                or url.username
                or url.password
                or url.query
                or url.fragment
            ):
                raise ValueError("Correction requires an HTTP(S) base URL without credentials")

    @property
    def host(self) -> str | None:
        return urlsplit(self.base_url).hostname if self.mode == "endpoint" else None

    @property
    def leaves_machine(self) -> bool:
        if self.mode != "endpoint":
            return False
        host = urlsplit(self.base_url).hostname or ""
        if host.lower() == "localhost":
            return False
        try:
            return not ipaddress.ip_address(host).is_loopback
        except ValueError:
            return True


def default_state_path() -> Path:
    return Path.home() / "Library/Application Support/Chirp/server-state.json"


def read_keep_loaded(path: Path) -> bool | None:
    """Client-set runtime override from the state file; None when absent or unreadable."""
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    value = data.get("correction_keep_loaded")
    return value if isinstance(value, bool) else None


def persist_keep_loaded(path: Path, value: bool) -> None:
    """Atomically rewrite the 0600 state file; server.toml is never rewritten."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(json.dumps({"correction_keep_loaded": value}) + "\n")
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise


@dataclass
class Settings:
    config_dir: Path = field(default_factory=lambda: Path.home() / ".config/chirp")
    debug_dir: Path = field(
        default_factory=lambda: Path.home() / "Library/Application Support/Chirp/debug"
    )
    state_path: Path = field(default_factory=default_state_path)
    debug_retain: bool = False
    retain_days: int = 3
    model_dir: Path | None = None
    engine: str = "mlx"
    precision: str = "float32"
    streaming: str = "rolling"
    finalization: str = "full"
    correction: CorrectionConfig = field(default_factory=CorrectionConfig)
    idle_seconds: float = 60.0
    auth_seconds: float = 5.0
    max_pending_auth: int = 8
    queue_timeout: float = 10.0

    @classmethod
    def read(cls, path: Path | None = None) -> "Settings":
        result = cls()
        path = path or result.config_dir / "server.toml"
        if path.exists():
            data = tomllib.loads(path.read_text())
            debug = data.get("debug", {})
            result.debug_retain = debug.get("retain", False)
            result.retain_days = int(debug.get("retain_days", 3))
            result.correction = CorrectionConfig(**data.get("correction", {}))
        if result.retain_days < 1 or result.correction.timeout <= 0:
            raise ValueError("Invalid configuration limits")
        return result


def load_token(directory: Path) -> str:
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / "token"
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
            raise ValueError("Token must be a regular file") from None
        path.chmod(0o600)
        token = path.read_text().strip()
        if not token:
            raise ValueError("Token file is empty") from None
        return token
    with os.fdopen(fd, "w") as stream:
        token = secrets.token_urlsafe(32)
        stream.write(token + "\n")
    return token
