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

from . import paths
from .cli import LABEL
from .config import Settings, read_keep_loaded
from .fsutil import is_private

OK, WARN, FAIL = "OK", "WARN", "FAIL"
DEFAULT_FIXTURE = paths.fixtures_dir() / "synthetic-5s.wav"


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
            "no valid Parakeet TDT speech model found",
            "Download the selected speech model in Chirp → Manage Local Models…"
            if model_dir
            else "uv run chirp-server model fetch",
        )
    return Check("model", OK, f"valid Parakeet TDT at {directory}")


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
    if sys.platform == "win32":
        try:
            private = is_private(path)
        except OSError:
            private = False
        if not private:
            return Check(
                "token",
                WARN,
                f"{path} is readable by other accounts",
                "restart the server; it restores owner-only access at startup",
            )
        return Check("token", OK, f"{path} present, owner-only access; value not printed")
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


def _listener(port: int) -> tuple[int, int, str] | None:
    """(pid, seconds since it started, command line) of the process listening on `port`, if any."""
    try:
        pids = subprocess.run(
            ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        ).stdout.split()
        pid = int(pids[0])
        fields = subprocess.run(
            ["/bin/ps", "-o", "etimes=,command=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        ).stdout.split(None, 1)
        return pid, int(fields[0]), fields[1].strip()
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        return None


def _newest_source(server_dir: Path) -> float:
    try:
        return max(p.stat().st_mtime for p in (server_dir / "src/chirp_server").rglob("*.py"))
    except (OSError, ValueError):
        return 0.0


def check_server_version(port: int = 7821, listener=_listener, newest=_newest_source) -> Check:
    """Flag a running server that started before the code it runs from was last changed.

    The token is never read, so this uses the process, not the authenticated health: it also covers
    servers too old to report a version.
    """
    if not _listening(port):
        return Check("server version", OK, f"no server on 127.0.0.1:{port}")
    found = listener(port)
    if found is None or "chirp_server" not in found[2]:
        return Check("server version", OK, "could not identify the process on the port")
    pid, age, command = found
    # By the venv marker, not the first word: the managed install's path contains a space.
    root, marker, _ = command.partition("/.venv/bin/")
    server_dir = Path(root) if marker and root.startswith("/") else None
    if server_dir is None or not (server_dir / "src/chirp_server").is_dir():
        return Check("server version", OK, "running; its source folder is not recognised")
    home = str(Path.home())
    where = str(server_dir)
    where = "~" + where[len(home) :] if where.startswith(home) else where
    if newest(server_dir) > time.time() - age + 1:
        return Check(
            "server version",
            WARN,
            f"server pid {pid} started {age // 3600}h ago, before its code in {where} changed",
            "restart it: uv run chirp-server setup restart (or scripts/install-mac.sh)",
        )
    return Check("server version", OK, f"running code from {where} that has not changed since")


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
        from .cleanup_models import discover, model_spec

        try:
            discover(config.model)
        except ValueError:
            return Check("correction", WARN, "managed model missing", "run model fetch --cleanup")
        if config.backend == "llama_cpp":
            import importlib.util

            if importlib.util.find_spec("llama_cpp") is None:
                return Check(
                    "correction",
                    WARN,
                    "portable cleanup runtime missing",
                    "run uv sync --extra cleanup",
                )
        # The effective keep_loaded is the client-persisted override, else server.toml.
        override = read_keep_loaded(settings.state_path)
        keep = override if override is not None else config.keep_loaded
        source = "state override" if override is not None else "server.toml"
        try:
            estimate = model_spec(config.model).memory_mb
        except ValueError:
            estimate = None
        memory = f"; loaded helper ≈ {estimate} MiB" if estimate else ""
        return Check(
            "correction",
            OK,
            f"managed; keep_loaded {'on' if keep else 'off'} ({source}){memory};"
            " final text stays on this machine",
        )
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


def check_service() -> Check:
    """The platform's background service (LaunchAgent, Task Scheduler task or systemd unit)."""
    if sys.platform == "darwin":
        return check_launchagent()
    from .service import backend

    try:
        state = backend().status()
    except Exception:
        return Check("service", OK, "background service not available on this platform")
    if not state["installed"]:
        return Check(
            "service",
            OK,
            "not installed (optional; keeps the model warm across logons)",
            "chirp-server service install",
        )
    if state["arguments"] is None:
        return Check(
            "service",
            WARN,
            f"{state['location']} does not run chirp_server",
            "chirp-server service uninstall, then chirp-server service install",
        )
    if state["running"] is False:
        return Check(
            "service",
            WARN,
            f"installed ({state['location']}) but not running",
            "chirp-server setup restart",
        )
    return Check("service", OK, f"installed ({state['location']}), running")


async def check_onnx(model_dir, providers: str, quick: bool) -> Check:
    """ONNX Parakeet: the runtime, its providers, the model and (unless quick) a warm load."""
    try:
        import onnx_asr  # noqa: F401
        import onnxruntime

        from .engine.onnx import ParakeetONNX, choose_providers, find_model

        directory = find_model(model_dir)
    except ImportError:
        return Check(
            "onnx", FAIL, "onnx-asr or onnxruntime is not installed", "uv sync --extra onnx"
        )
    except ValueError:
        return Check(
            "onnx",
            FAIL,
            "ONNX Parakeet model missing",
            "uv run chirp-server model fetch --engine onnx",
        )
    available = onnxruntime.get_available_providers()
    chosen = choose_providers(providers, available)
    detail = (
        f"onnxruntime {onnxruntime.__version__}, providers {', '.join(available)};"
        f" using {chosen[0]} for {directory}"
    )
    if providers not in {"cpu", "auto"} and chosen == ["CPUExecutionProvider"]:
        return Check(
            "onnx",
            WARN,
            detail + f" ({providers} requested but not installed)",
            "see server/README.md › Parakeet ONNX accelerators",
        )
    if quick:
        return Check("onnx", OK, detail + "; load skipped (--quick)")
    from .engine import EngineWorker

    engine = ParakeetONNX(directory, providers=providers)
    worker = EngineWorker(engine)
    try:
        started = time.perf_counter()
        await worker.start()
        elapsed = (time.perf_counter() - started) * 1000
    except Exception:
        return Check("onnx", FAIL, "local model load or warm decode failed", "check server startup")
    finally:
        await worker.close()
    if engine.providers != chosen:
        return Check(
            "onnx",
            WARN,
            detail + f"; {chosen[0]} failed to load, fell back to CPU",
            'update the GPU driver, or set [onnx] providers = "cpu"',
        )
    return Check("onnx", OK, f"{detail}; loaded and warmed in {elapsed:.0f} ms")


async def check_sensevoice(model_dir, num_threads, quick):
    from .engine import EngineWorker
    from .engine.sensevoice import SenseVoice
    from .engine.sensevoice_models import discover

    try:
        discover(model_dir)
        import sherpa_onnx

        version = sherpa_onnx.__version__

        engine = SenseVoice(model_dir, num_threads)
    except (ImportError, ValueError):
        return Check(
            "sensevoice",
            FAIL,
            "optional package, configuration or model files unavailable",
            "install chirp-server[sensevoice]; run chirp-server model fetch --engine sensevoice",
        )
    if quick:
        return Check(
            "sensevoice", OK, f"sherpa-onnx {version} and local files found; load skipped (--quick)"
        )
    worker = EngineWorker(engine)
    try:
        await worker.start()
        return Check("sensevoice", OK, "loaded and warmed local CPU model")
    except Exception:
        return Check("sensevoice", FAIL, "local model load or warm decode failed")
    finally:
        await worker.close()


def doctor(args, tailscale_status: tuple[int, str] | None = None) -> int:
    """Run every check in order; return 1 only when some check FAILs."""
    settings, config_check = load_settings(args.config)
    model_dir = args.model_dir or settings.model_dir
    engine = getattr(args, "engine", None) or settings.engine
    sensevoice = engine == "sensevoice"
    checks = [check_environment()]
    if engine == "onnx":
        checks.append(
            asyncio.run(
                check_onnx(model_dir, settings.onnx.providers, getattr(args, "quick", False))
            )
        )
    elif sensevoice:
        threads = getattr(args, "sensevoice_num_threads", None)
        checks.append(
            asyncio.run(
                check_sensevoice(
                    args.model_dir,
                    settings.sensevoice_num_threads if threads is None else threads,
                    getattr(args, "quick", False),
                )
            )
        )
    else:
        checks.extend([check_mlx(), check_model(model_dir)])
    if engine != "mlx":
        pass
    elif getattr(args, "quick", False):
        print("[SKIP] warm decode: skipped (--quick)")
    else:
        checks.append(asyncio.run(check_warm_decode(model_dir)))
    checks.extend(
        [
            config_check,
            check_token(settings.config_dir),
            check_port(args.port),
            check_server_version(args.port),
            check_retention(settings),
            check_correction(settings),
            check_tailscale(tailscale_status),
            check_service(),
        ]
    )
    for check in checks:
        print(render(check))
    counts = {status: sum(c.status == status for c in checks) for status in (OK, WARN, FAIL)}
    print(f"{len(checks)} checks: {counts[OK]} OK, {counts[WARN]} WARN, {counts[FAIL]} FAIL")
    return 1 if counts[FAIL] else 0
