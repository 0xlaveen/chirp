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

from . import paths
from .fsutil import make_private, private_mkdir
from .platforms import default_cleanup_backend, default_engine
from .profiles import LIVE_NOTES, LIVE_NOTES_ID, MAX_PROMPT_CHARS, Profile, resolve_profiles


@dataclass
class CorrectionConfig:
    # Legacy enabled=true maps to endpoint only when mode is omitted.
    enabled: bool = False
    mode: str | None = None
    base_url: str = "http://127.0.0.1:1234/v1"
    model: str = ""
    backend: str = "auto"
    llama_threads: int = 4
    prompt: str = ""
    timeout: float | None = None
    # Live Notes segment correction: longer input than a dictation, and it may queue behind a
    # running structuring pass (see docs/bench.md).
    notes_timeout: float | None = None
    structure_timeout: float | None = None
    # A reorganize generates up to 1024 tokens: about 15 s at the cap on an M5 Pro (docs/bench.md),
    # so slower Macs need more room than structuring's 30 s.
    reorganize_timeout: float | None = None
    api_key_env: str = "CHIRP_LLM_API_KEY"
    keychain_service: str = ""
    idle_seconds: float = 60.0
    keep_loaded: bool = False
    profiles: dict = field(default_factory=dict)
    resolved_profiles: dict[str, Profile] = field(init=False, repr=False)
    _default_budgets: tuple[str, ...] = field(init=False, repr=False, compare=False)

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
        if self.backend == "auto":
            from .cleanup_models import GGUF_MODELS, MODELS

            self.backend = (
                "llama_cpp"
                if self.model in GGUF_MODELS
                else "mlx"
                if self.model in MODELS
                else default_cleanup_backend()
            )
        if self.backend not in {"mlx", "llama_cpp"}:
            raise ValueError("Correction backend must be auto, mlx or llama_cpp")
        if type(self.llama_threads) is not int or not 1 <= self.llama_threads <= 256:
            raise ValueError("Correction llama_threads must be an integer between 1 and 256")
        portable = self.backend == "llama_cpp" and self.mode != "endpoint"
        # A CPU Qwen prompt can take ~20 s including a cold load. Preserve explicit
        # budgets and the existing MLX/endpoint defaults; make the portable default usable.
        self._default_budgets = tuple(
            name
            for name in ("timeout", "notes_timeout", "structure_timeout", "reorganize_timeout")
            if getattr(self, name) is None
        )
        for name, normal, cpu in (
            ("timeout", 8.0, 30.0),
            ("notes_timeout", 15.0, 45.0),
            ("structure_timeout", 30.0, 90.0),
            ("reorganize_timeout", 45.0, 120.0),
        ):
            if getattr(self, name) is None:
                setattr(self, name, cpu if portable else normal)
        if not self.model and self.backend == "llama_cpp" and self.mode != "endpoint":
            from .cleanup_models import PORTABLE_MODEL

            self.model = PORTABLE_MODEL
        if any(
            not math.isfinite(v) or v <= 0
            for v in (
                self.timeout,
                self.notes_timeout,
                self.structure_timeout,
                self.reorganize_timeout,
                self.idle_seconds,
            )
        ):
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

    def with_model(self, model_id: str, backend: str):
        """A picker changes backend defaults while retaining explicitly configured budgets."""
        defaults = {name: None for name in self._default_budgets}
        return replace(self, mode="managed", model=model_id, backend=backend, **defaults)

    def profile(self, profile_id) -> Profile | None:
        """A listed style, or the hidden Live Notes style; None for anything else."""
        if profile_id == LIVE_NOTES_ID:
            return LIVE_NOTES
        return self.resolved_profiles.get(profile_id)

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
    return paths.state_path()


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
    private_mkdir(path.parent)
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
class OnnxConfig:
    intra_op_num_threads: int | None = None
    inter_op_num_threads: int | None = None
    # cpu (default), auto (CUDA, then DirectML, when installed), cuda or directml.
    providers: str = "cpu"

    def __post_init__(self):
        if self.providers not in {"cpu", "auto", "cuda", "directml"}:
            raise ValueError("ONNX providers must be cpu, auto, cuda or directml")
        for name in ("intra_op_num_threads", "inter_op_num_threads"):
            value = getattr(self, name)
            if value is not None and (type(value) is not int or not 0 <= value <= 2**31 - 1):
                raise ValueError(f"ONNX {name} must be an integer between 0 and 2147483647")


@dataclass
class ActivityConfig:
    """`[activity]` in server.toml: the per-device activity list (docs/privacy.md)."""

    keep: bool = True
    max_events: int = 5000
    max_days: int = 30

    def __post_init__(self):
        if not isinstance(self.keep, bool):
            raise ValueError("Activity keep must be true or false")
        for name, limit in (("max_events", 100_000), ("max_days", 365)):
            value = getattr(self, name)
            if type(value) is not int or not 1 <= value <= limit:
                raise ValueError(f"Activity {name} must be an integer between 1 and {limit}")


@dataclass
class Settings:
    config_dir: Path = field(default_factory=paths.config_dir)
    debug_dir: Path = field(default_factory=paths.debug_dir)
    state_path: Path = field(default_factory=default_state_path)
    debug_retain: bool = False
    retain_days: int = 3
    model_dir: Path | None = None
    speech_model: str = "parakeet-v2"
    engine: str = field(default_factory=default_engine)
    sensevoice_num_threads: int = 4
    precision: str = "float32"
    streaming: str = "rolling"
    finalization: str = "full"
    onnx: OnnxConfig = field(default_factory=OnnxConfig)
    activity: ActivityConfig = field(default_factory=ActivityConfig)
    correction: CorrectionConfig = field(default_factory=CorrectionConfig)
    idle_seconds: float = 60.0
    auth_seconds: float = 5.0
    max_pending_auth: int = 8
    queue_timeout: float = 10.0

    @property
    def activity_path(self) -> Path:
        """The saved activity list, beside the server state."""
        return self.state_path.with_name("device-activity.json")

    @classmethod
    def read(cls, path: Path | None = None) -> "Settings":
        result = cls()
        path = path or result.config_dir / "server.toml"
        if path.exists():
            data = tomllib.loads(path.read_text())
            result.engine = data.get("engine", result.engine)
            result.sensevoice_num_threads = data.get("sensevoice", {}).get("num_threads", 4)
            debug = data.get("debug", {})
            result.debug_retain = debug.get("retain", False)
            result.retain_days = int(debug.get("retain_days", 3))
            result.correction = CorrectionConfig(**data.get("correction", {}))
            result.onnx = OnnxConfig(**data.get("onnx", {}))
            result.activity = ActivityConfig(**data.get("activity", {}))
        if result.retain_days < 1 or result.correction.timeout <= 0:
            raise ValueError("Invalid configuration limits")
        if result.engine not in {"mlx", "onnx", "sensevoice"}:
            raise ValueError("Invalid speech engine")
        if (
            type(result.sensevoice_num_threads) is not int
            or not 1 <= result.sensevoice_num_threads <= 256
        ):
            raise ValueError("SenseVoice num_threads must be an integer between 1 and 256")
        from .model_catalog import apply_settings

        apply_settings(result)
        if result.engine == "sensevoice":
            # A Mac model-picker selection is an MLX choice, not a SenseVoice path.
            result.model_dir = None
            result.speech_model = "sensevoice-small"
        return result


def load_token(directory: Path, name: str = "token") -> str:
    """The shared token, or (`name="owner-token"`) the owner's: a 0600 regular file, created
    on first use."""
    private_mkdir(directory)
    path = directory / name
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
            raise ValueError("Token must be a regular file") from None
        make_private(path)
        token = path.read_text().strip()
        if not token:
            raise ValueError("Token file is empty") from None
        return token
    with os.fdopen(fd, "w") as stream:
        token = secrets.token_urlsafe(32)
        stream.write(token + "\n")
    make_private(path)
    return token
