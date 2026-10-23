"""Pinned SenseVoice assets. Only the explicit model-fetch command uses the network."""

import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile
from urllib.request import urlopen

from .models import model_root

REPOSITORY = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
REVISION = "2365baeacb507f821a0c8120fcee3d484dba7a07"
FILES = ("model.onnx", "tokens.txt", "silero_vad.onnx")
VAD_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
VAD_SHA256 = "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
HUB_FILES = ["model.onnx", "tokens.txt", "LICENSE"]
# Must match the `sensevoice` extra in pyproject.toml (a test checks).
REQUIREMENTS = ("sherpa-onnx==1.13.8", "sherpa-onnx-core==1.13.8")
UV = ("~/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "~/.cargo/bin/uv")


def discover(explicit: Path | None = None) -> Path:
    directory = explicit if explicit is not None else model_root() / "sensevoice-small"
    if not all(
        (directory / name).is_file() and (directory / name).stat().st_size for name in FILES
    ):
        raise ValueError(
            "SenseVoice model incomplete; run chirp-server model fetch --engine sensevoice "
            "or use --model-dir with model.onnx, tokens.txt and silero_vad.onnx"
        )
    return directory


def runtime_installed() -> bool:
    return importlib.util.find_spec("sherpa_onnx") is not None


def install_command() -> list[str] | None:
    """How to add the optional runtime to this environment; None when it is not ours to change."""
    if not os.access(sys.prefix, os.W_OK):
        return None  # A read-only (e.g. Nix store) environment.
    found = shutil.which("uv") or next(
        (p for p in map(os.path.expanduser, UV) if os.access(p, os.X_OK)), None
    )
    if found is None:
        return None
    project = Path(sys.prefix).parent
    if Path(sys.prefix).name == ".venv" and (project / "uv.lock").is_file():
        # Locked like scripts/install-mac.sh; --inexact keeps whatever else is installed.
        return [
            found,
            "sync",
            "--project",
            str(project),
            "--locked",
            "--no-dev",
            "--inexact",
            "--extra",
            "sensevoice",
        ]
    return [found, "pip", "install", "--python", sys.executable, *REQUIREMENTS]


class RuntimeUnavailable(RuntimeError):
    """Safe to show: names no path, URL or credential."""


def install_runtime() -> None:
    command = install_command()
    if command is None:
        raise RuntimeUnavailable(
            "This chirp-server can't add the SenseVoice runtime itself. Install "
            "chirp-server[sensevoice] (uv sync --extra sensevoice), then retry."
        )
    subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=900, check=True)
    importlib.invalidate_caches()
    if not runtime_installed():
        raise RuntimeError("SenseVoice runtime missing after install")


def fetch() -> Path:
    from huggingface_hub import snapshot_download

    directory = model_root() / "sensevoice-small"
    snapshot_download(REPOSITORY, revision=REVISION, local_dir=directory, allow_patterns=HUB_FILES)
    return fetch_vad(directory)


def fetch_vad(directory: Path) -> Path:
    if (directory / "silero_vad.onnx").is_file():
        with (directory / "silero_vad.onnx").open("rb") as existing:
            if hashlib.file_digest(existing, "sha256").hexdigest() == VAD_SHA256:
                return discover(directory)
    # The release URL is mutable, so pin its content too. Never install a partial
    # download or an unverified replacement over an existing VAD model.
    temporary = None
    try:
        digest = hashlib.sha256()
        with (
            urlopen(VAD_URL, timeout=60) as response,
            NamedTemporaryFile(dir=directory, prefix=".vad-", delete=False) as output,
        ):
            temporary = Path(output.name)
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != VAD_SHA256:
            raise ValueError("Silero VAD checksum mismatch; model was not installed")
        os.replace(temporary, directory / "silero_vad.onnx")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return discover(directory)
