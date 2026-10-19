"""Explicit local setup for the Mac app. Status is offline; downloads need a user action."""

import json
import os
import subprocess
import time
from pathlib import Path

from . import cleanup_models
from .config import Settings
from .engine import models as speech_models


def emit(event, **values):
    print(json.dumps({"event": event, **values}), flush=True)


def status(settings):
    result = []
    for kind, title, discover in (
        ("speech", "Parakeet · English speech", speech_models.discover),
        (
            "cleanup",
            f"Qwen · {settings.correction.model or cleanup_models.DEFAULT_MODEL}",
            lambda: cleanup_models.discover(settings.correction.model),
        ),
    ):
        try:
            discover()
            ready = True
        except (OSError, ValueError):
            ready = False
        result.append({"id": kind, "title": title, "ready": ready})
    return result


def configure_downloads():
    # HTTP gives resumable byte progress, including behind inspecting proxies.
    # Determinate exports the Mac's trusted Keychain roots for Python/OpenSSL.
    # Honor an explicit CA override; never disable certificate verification.
    os.environ["HF_HUB_DISABLE_XET"] = "1"
    keychain = Path("/etc/nix/macos-keychain.crt")
    if "SSL_CERT_FILE" not in os.environ and keychain.is_file():
        os.environ["SSL_CERT_FILE"] = str(keychain)


def download(kind, settings):
    configure_downloads()
    from huggingface_hub import hf_hub_download, snapshot_download
    from huggingface_hub.utils import tqdm

    if kind == "speech":
        repository, revision = speech_models.REPOSITORY, speech_models.REVISION
        patterns = speech_models.FILES
        local = speech_models.model_root() / "parakeet-mlx"
        discover = speech_models.discover
    else:
        model = cleanup_models.model_spec(settings.correction.model)
        repository, revision = model.repository, model.revision
        patterns, local = cleanup_models.PATTERNS, None

        def discover():
            return cleanup_models.discover(settings.correction.model)

    emit("progress", model=kind, phase="preparing", completed_bytes=0, total_bytes=0)
    try:
        discover()
        emit("complete", model=kind)
        return
    except (OSError, ValueError):
        pass

    plan = snapshot_download(
        repository, revision=revision, allow_patterns=patterns, local_dir=local, dry_run=True
    )
    total = sum(item.file_size for item in plan)
    completed = sum(item.file_size for item in plan if not item.will_download)
    last = 0.0

    def progress(current, *, force=False):
        nonlocal last
        now = time.monotonic()
        if force or now - last >= 0.15:
            emit(
                "progress",
                model=kind,
                phase="downloading",
                completed_bytes=min(total, max(0, current)),
                total_bytes=total,
            )
            last = now

    class ByteProgress(tqdm):
        def __init__(self, *args, **kwargs):
            kwargs["disable"] = True
            super().__init__(*args, **kwargs)
            progress(completed + self.n, force=True)

        def update(self, n=1):
            self.n += n or 0
            progress(completed + self.n)

    progress(completed, force=True)
    for item in plan:
        if not item.will_download:
            continue
        hf_hub_download(
            repository, item.filename, revision=revision, local_dir=local, tqdm_class=ByteProgress
        )
        completed += item.file_size
        progress(completed, force=True)
    discover()  # Only a complete usable snapshot gets a green checkmark.
    emit("complete", model=kind)


def server_running(port):
    import httpx

    try:
        response = httpx.get(f"http://127.0.0.1:{port}/v1/health", timeout=1, trust_env=False)
        return response.status_code == 200 and response.json().get("ok") is True
    except (httpx.HTTPError, ValueError):
        return False


def start_server(port):
    speech_models.discover()
    if server_running(port):
        emit("started")
        return
    emit("starting")
    label = "dev.chirp.server"
    domain = f"gui/{os.getuid()}"
    destination = Path.home() / "Library/LaunchAgents" / f"{label}.plist"
    if destination.exists():
        # Reload a launchd job that was registered before its venv existed.
        # Reuse nix-darwin's plist, including its port/root-path configuration.
        import plistlib

        document = plistlib.loads(destination.read_bytes())
        arguments = document.get("ProgramArguments", [])
        if document.get("Label") != label or arguments[1:3] != ["-m", "chirp_server"]:
            raise ValueError("Unexpected local server service")
        service_port = (
            int(arguments[arguments.index("--port") + 1]) if "--port" in arguments else 7821
        )
        if service_port != port:
            raise ValueError("Local server port differs from the app setting")
        subprocess.run(
            ["/bin/launchctl", "bootout", f"{domain}/{label}"],
            capture_output=True,
            timeout=10,
            check=False,
        )
        subprocess.run(
            ["/bin/launchctl", "bootstrap", domain, str(destination)],
            capture_output=True,
            timeout=10,
            check=True,
        )
    else:
        from .cli import service

        service("install", ["--port", str(port)] if port != 7821 else [])
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if server_running(port):
            emit("started")
            return
        time.sleep(0.5)
    raise TimeoutError("Server did not become ready")


def run(action, model, config, port):
    try:
        settings = Settings.read(config)
        if action == "status":
            emit(
                "status",
                models=status(settings),
                correction_mode=settings.correction.mode,
                server_running=server_running(port),
            )
        elif action == "download":
            download(model, settings)
        else:
            start_server(port)
        return 0
    except KeyboardInterrupt:
        emit("cancelled", model=model)
        return 130
    except Exception:
        # Exception text can contain signed download URLs or credentials.
        message = (
            "Could not start the server. Check its configuration and try again."
            if action == "start"
            else "Could not finish setup. Check your connection and free disk space, then retry."
            if action == "download"
            else "Could not read local setup. Check the server configuration."
        )
        emit("error", model=model if action == "download" else None, message=message)
        return 1
