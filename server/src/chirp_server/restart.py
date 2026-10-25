"""`chirp-server setup restart|replace`: restart the LaunchAgent the Mac app manages.

The agent (`dev.chirp.server`) then runs the code on disk now. `replace` first stops a server on
the port that the agent does not own, but never one that another LaunchAgent would just start
again. Prints JSON events only; no paths, text or tokens.
"""

import contextlib
import os
import plistlib
import signal
import subprocess
import sys
import time
from pathlib import Path

from .cli import LABEL
from .setup import emit, server_running

LAUNCHCTL = "/bin/launchctl"


def _run(args, timeout=10):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return None


def listeners(port):
    """PIDs of this user's processes listening on `port`."""
    result = _run(["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"])
    return [int(p) for p in (result.stdout.split() if result else []) if p.isdigit()]


def jobs():
    """`launchctl list` as {label: pid} for the jobs that are running."""
    result = _run([LAUNCHCTL, "list"])
    found = {}
    for line in (result.stdout.splitlines() if result else [])[1:]:
        columns = line.split("\t")
        if len(columns) >= 3 and columns[0].isdigit():
            found[columns[2]] = int(columns[0])
    return found


def owner(pid):
    """The launchd label running `pid`, or None for a process started by hand."""
    return next((label for label, p in jobs().items() if p == pid), None)


def reload_agent(port):
    destination = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    if not destination.exists():
        from .cli import service

        service("install", ["--port", str(port)] if port != 7821 else [])
        return
    arguments = plistlib.loads(destination.read_bytes()).get("ProgramArguments", [])
    if arguments[1:3] != ["-m", "chirp_server"]:
        raise ValueError("Unexpected local server service")
    _run([LAUNCHCTL, "bootout", f"{domain}/{LABEL}"])
    # launchd can briefly reject bootstrap while the bootout settles.
    for attempt in range(3):
        result = _run([LAUNCHCTL, "bootstrap", domain, str(destination)], timeout=5)
        if result is not None and result.returncode == 0:
            return
        if attempt < 2:
            time.sleep(0.5)
    raise RuntimeError("bootstrap failed")


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def stop(pids):
    for pid in pids:
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if not any(alive(pid) for pid in pids):
            return True
        time.sleep(0.2)
    return False


def wait_ready(port):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if server_running(port):
            emit("restarted")
            return 0
        time.sleep(0.5)
    emit("error", reason="timeout", message="The server did not become ready.")
    return 1


def run_portable(port, replace=False):
    """Windows and Linux: the same flow through the platform's service backend."""
    from .service import backend

    service = backend()
    held = service.listeners(port)
    if held and not service.status()["running"]:
        if not replace:
            emit(
                "error",
                reason="unmanaged",
                message="A server Chirp does not manage is using this port.",
            )
            return 1
        emit("stopping")
        if not service.stop(held):
            emit(
                "error", reason="stuck", message="The other server did not stop. Quit it and retry."
            )
            return 1
    emit("starting")
    try:
        service.restart(port)
    except Exception:
        emit(
            "error",
            reason="service",
            message="Could not restart the server. Check its configuration and try again.",
        )
        return 1
    return wait_ready(port)


def run(port, replace=False):
    if sys.platform != "darwin":
        return run_portable(port, replace)
    held = listeners(port)
    ours = jobs().get(LABEL)
    if held and ours not in held:
        label = owner(held[0])
        if label:
            emit(
                "error",
                reason="other_agent",
                label=label,
                message=f"Another LaunchAgent ({label}) runs the server on this port. "
                f"Stop it with: launchctl bootout gui/{os.getuid()}/{label}",
            )
            return 1
        if not replace:
            emit(
                "error",
                reason="unmanaged",
                message="A server Chirp does not manage is using this port.",
            )
            return 1
        emit("stopping")
        if not stop(held):
            emit(
                "error", reason="stuck", message="The other server did not stop. Quit it and retry."
            )
            return 1
    emit("starting")
    try:
        reload_agent(port)
    except Exception:
        emit(
            "error",
            reason="launchd",
            message="Could not restart the server. Check its configuration and try again.",
        )
        return 1
    return wait_ready(port)
