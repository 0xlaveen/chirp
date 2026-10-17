"""Read-only diagnostics: one OK/WARN/FAIL line per check, with remediation.

Doctor never mutates state: it creates no files (the token is only stat-ed, never read or
created), starts no servers or services, changes no Tailscale configuration, and prints no
secrets or transcripts. `tailscale serve status --json` is its only tailscale invocation.
"""

import asyncio
import json
import shutil
import socket
import stat
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from .cli import LABEL
from .config import Settings

OK, WARN, FAIL = "OK", "WARN", "FAIL"
DEFAULT_FIXTURE = Path.home() / "Library/Caches/Chirp/fixtures/synthetic-5s.wav"


@dataclass(frozen=True)
class Check:
    name: str
    status: str
    detail: str
    fix: str = ""


def render(check: Check) -> str:
    line = f"[{check.status}] {check.name}: {check.detail}"
    return f"{line}\n       fix: {check.fix}" if check.fix else line


def check_environment() -> Check:
    version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    uv = shutil.which("uv")
    detail = f"python {version} at {sys.executable}"
    detail += f", uv at {uv}" if uv else ", uv not on PATH"
    if (sys.version_info.major, sys.version_info.minor) != (3, 13):
        return Check("environment", FAIL, detail, "cd server && uv sync --locked")
    if not uv:
        return Check("environment", WARN, detail, "install uv (https://docs.astral.sh/uv)")
    return Check("environment", OK, detail)


def check_mlx() -> Check:
    try:
        import mlx.core as mx
    except Exception:
        return Check("mlx", FAIL, "importing mlx failed", "cd server && uv sync --locked")
    return Check("mlx", OK, f"mlx {getattr(mx, '__version__', 'available')}")


def check_model(model_dir: Path | None = None) -> Check:
    from .engine.models import discover

    try:
        directory = discover(model_dir)
    except ValueError:
        return Check(
            "model",
            FAIL,
            "no valid English Parakeet TDT v2 model found",
            "uv run chirp-server model fetch",
        )
    return Check("model", OK, f"valid English Parakeet TDT v2 at {directory}")


def _fixture_samples(fixture: Path):
    """Blocking fixture read, kept out of the async check; None when the file is absent."""
    path = Path(fixture)
    if not path.is_file():
        return None
    from .audio import decode_wav, samples

    return samples(decode_wav(path.read_bytes()))


async def check_warm_decode(model_dir: Path | None = None, fixture=DEFAULT_FIXTURE) -> Check:
    """Load the real model and decode the synthetic fixture; the transcript is never printed."""
    try:
        pcm = _fixture_samples(fixture)
    except ValueError:  # AudioError: unreadable or malformed fixture WAV
        return Check(
            "warm decode",
            FAIL,
            f"fixture {Path(fixture).name} could not be decoded",
            "uv run python scripts/generate_fixtures.py",
        )
    if pcm is None:
        return Check(
            "warm decode",
            WARN,
            f"fixture {Path(fixture).name} missing; model load skipped",
            "uv run python scripts/generate_fixtures.py",
        )
    from .engine import EngineWorker
    from .engine.mlx import ParakeetMLX

    started = time.perf_counter()
    try:
        engine = ParakeetMLX(model_dir)
        worker = EngineWorker(engine)
        await worker.start()
        try:
            text = await worker.call(engine.transcribe, pcm)
        finally:
            await worker.close()
    except Exception:
        return Check(
            "warm decode",
            FAIL,
            "model load or decode failed",
            "run without --quick and check server startup",
        )
    if "fox" not in text.lower():
        return Check(
            "warm decode",
            FAIL,
            "decoded fixture lacked the expected keyword",
            "uv run python scripts/generate_fixtures.py",
        )
    elapsed = (time.perf_counter() - started) * 1000
    return Check(
        "warm decode",
        OK,
        f"loaded, warmed and decoded {Path(fixture).name} in {elapsed:.0f} ms"
        " (keyword matched; transcript not printed)",
    )


def load_settings(config: Path | None = None) -> tuple[Settings, Check]:
    path = config if config else Settings().config_dir / "server.toml"
    if not Path(path).is_file():
        return Settings(), Check("config", OK, f"no {path}; using defaults")
    try:
        return Settings.read(config), Check("config", OK, f"parsed {path}")
    except (OSError, ValueError, TypeError):
        # Never quote the parse error: TOML diagnostics can include file content.
        return Settings(), Check(
            "config",
            FAIL,
            f"{path} is unreadable or invalid",
            "fix syntax and limits per server/README.md; API keys never belong in server.toml",
        )


def check_token(config_dir: Path) -> Check:
    path = Path(config_dir) / "token"
    try:
        info = path.lstat()
    except OSError:
        return Check("token", OK, f"not created yet; {path} is generated on first server run")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        return Check(
            "token",
            FAIL,
            f"{path} must be a regular file",
            f"remove {path}; the server regenerates it",
        )
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o077:
        return Check(
            "token",
            WARN,
            f"{path} exists but mode {oct(mode)} is group/other accessible",
            f"chmod 600 '{path}' (the server also corrects this at startup)",
        )
    return Check("token", OK, f"{path} present with mode 0600; value not printed")


def _listening(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def _health_ok(port: int) -> bool:
    import httpx

    try:
        response = httpx.get(f"http://127.0.0.1:{port}/v1/health", timeout=2.0, trust_env=False)
        return response.status_code == 200 and response.json() == {"ok": True}
    except Exception:
        return False


def check_port(port: int = 7821) -> Check:
    if not _listening(port):
        return Check("port", OK, f"127.0.0.1:{port} free")
    if _health_ok(port):
        return Check("port", OK, "held by chirp-server (unauthenticated /v1/health answered)")
    return Check("port", WARN, "held by a non-chirp process", f"lsof -nP -iTCP:{port} -sTCP:LISTEN")


def check_retention(settings: Settings) -> Check:
    count = size = 0
    if settings.debug_dir.is_dir():
        for path in settings.debug_dir.iterdir():
            if path.is_file():
                count += 1
                size += path.stat().st_size
    state = "enabled" if settings.debug_retain else "off"
    size_mib = size / 1048576
    detail = f"{state}; {count} retained file(s), {size_mib:.1f} MiB under {settings.debug_dir}"
    if settings.debug_retain:
        return Check(
            "debug retention",
            WARN,
            detail + " — utterance audio/transcripts are kept on disk",
            "set [debug] retain = false and run: uv run chirp-server debug purge",
        )
    if count:
        return Check(
            "debug retention", WARN, detail, "clear leftovers: uv run chirp-server debug purge"
        )
    return Check("debug retention", OK, detail)


def check_correction(settings: Settings) -> Check:
    config = settings.correction
    if not config.enabled:
        return Check("correction", OK, "off; finals keep raw text on this machine")
    if config.mode == "managed":
        from .cleanup_models import discover

        try:
            discover(config.model)
        except ValueError:
            return Check("correction", WARN, "managed model missing", "run model fetch --cleanup")
        return Check("correction", OK, "managed; final text stays on this machine")
    host = urlsplit(config.base_url).hostname or "unknown host"
    if config.leaves_machine:
        return Check(
            "correction",
            WARN,
            f"enabled for {host}; corrected final text leaves this machine",
            "clients must label it; use a loopback base_url to stay local",
        )
    return Check(
        "correction",
        OK,
        f"enabled for loopback host {host}; final text stays on this machine",
    )


def _funnel(node) -> bool:
    if isinstance(node, dict):
        for key, value in node.items():
            if key.lower() == "funnel" and value:
                return True
            if _funnel(value):
                return True
        return False
    if isinstance(node, list):
        return any(_funnel(item) for item in node)
    return False


def check_tailscale(status: tuple[int, str] | None = None) -> Check:
    """Parse `tailscale serve status --json` read-only; never change the Serve configuration."""
    if status is None:
        try:
            process = subprocess.run(
                ["tailscale", "serve", "status", "--json"],
                capture_output=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return Check(
                "tailscale",
                WARN,
                "tailscale CLI unavailable or timed out",
                "install or start Tailscale, then publish:"
                " tailscale serve --bg --set-path /chirp http://127.0.0.1:7821",
            )
        status = (process.returncode, process.stdout)
    code, stdout = status
    if code != 0:
        return Check("tailscale", WARN, "tailscale serve status failed", "is tailscaled running?")
    text_out = stdout.decode("utf-8", "replace") if isinstance(stdout, bytes) else str(stdout)
    brace = text_out.find("{")
    if brace < 0:
        return Check("tailscale", WARN, "no JSON in serve status output")
    try:
        data = json.loads(text_out[brace:])
    except ValueError:
        return Check("tailscale", WARN, "unexpected serve status output")
    for name, entry in (data.get("Web") or {}).items():
        handlers = entry.get("Handlers") if isinstance(entry, dict) else None
        if not isinstance(handlers, dict):
            continue
        paths = [p for p in handlers if p == "/chirp" or p.startswith("/chirp/")]
        if not paths:
            continue
        host = name.rsplit(":", 1)[0]
        if _funnel(entry):
            return Check(
                "tailscale",
                WARN,
                f"https://{host}/chirp is published with Funnel (publicly reachable)",
                "operator action: tailscale funnel off",
            )
        targets = sorted(
            {(handlers[p].get("Proxy") or "?") for p in paths if isinstance(handlers[p], dict)}
        )
        target = ", ".join(targets)
        if targets and all("127.0.0.1:7821" in t for t in targets):
            return Check(
                "tailscale",
                OK,
                f"https://{host}/chirp published, tailnet-only (proxy {target})",
            )
        return Check(
            "tailscale",
            WARN,
            f"https://{host}/chirp published but proxying to {target}, not 127.0.0.1:7821",
            "operator action: tailscale serve --set-path /chirp http://127.0.0.1:7821",
        )
    return Check("tailscale", OK, "not published on the tailnet (optional; docs/TESTING.md step 2)")


def check_launchagent(home: Path | None = None) -> Check:
    path = (home or Path.home()) / "Library/LaunchAgents" / f"{LABEL}.plist"
    if path.is_file():
        return Check("launchagent", OK, f"installed at {path}")
    return Check("launchagent", OK, "not installed (optional; keeps the model warm across reboots)")


def doctor(args, tailscale_status: tuple[int, str] | None = None) -> int:
    """Run every check in order; return 1 only when some check FAILs."""
    checks = [check_environment(), check_mlx(), check_model(args.model_dir)]
    if getattr(args, "quick", False):
        print("[SKIP] warm decode: skipped (--quick)")
    else:
        checks.append(asyncio.run(check_warm_decode(args.model_dir)))
    settings, config_check = load_settings(args.config)
    checks.extend(
        [
            config_check,
            check_token(settings.config_dir),
            check_port(args.port),
            check_retention(settings),
            check_correction(settings),
            check_tailscale(tailscale_status),
            check_launchagent(),
        ]
    )
    for check in checks:
        print(render(check))
    counts = {status: sum(c.status == status for c in checks) for status in (OK, WARN, FAIL)}
    print(f"{len(checks)} checks: {counts[OK]} OK, {counts[WARN]} WARN, {counts[FAIL]} FAIL")
    return 1 if counts[FAIL] else 0
