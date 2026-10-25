"""Explicit per-user systemd service. Never invoked merely by starting the server."""

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from uuid import uuid4

UNIT = "dev.chirp.server.service"
MARKER = "# Managed by chirp-server; arguments="
KIND = "systemd"


def location():
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "systemd" / "user" / UNIT


def quote(value):
    """Quote one ExecStart argument (systemd syntax, never a shell)."""
    value = str(value)
    if any(c in value for c in "\0\r\n"):
        raise ValueError("Service arguments cannot contain control characters")
    return (
        '"'
        + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$")
        + '"'
    )


def render(arguments=()):
    arguments = list(arguments)
    command = [str(Path(sys.executable).absolute()), "-m", "chirp_server", *arguments]
    return (
        MARKER + json.dumps(arguments) + "\n"
        "[Unit]\nDescription=Chirp private speech server\n\n"
        "[Service]\nType=simple\nExecStart=" + " ".join(map(quote, command)) + "\n"
        "Restart=on-failure\nRestartSec=3\nUMask=0077\n"
        "Environment=PYTHONUNBUFFERED=1\nStandardOutput=null\nStandardError=null\n"
        "NoNewPrivileges=true\n\n[Install]\nWantedBy=default.target\n"
    )


def systemctl(*arguments, check=True):
    try:
        return subprocess.run(
            ["systemctl", "--user", *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=check,
        )
    except FileNotFoundError:
        raise ValueError(
            "systemd user services are unavailable; run chirp-server in a terminal"
        ) from None
    except subprocess.CalledProcessError:
        raise ValueError(
            "Could not manage the systemd user service; check systemctl --user status " + UNIT
        ) from None


def _arguments():
    path = location()
    if path.is_symlink():
        raise ValueError("Unexpected local server service")
    try:
        lines = path.read_text().splitlines()
        first = lines[0]
    except FileNotFoundError:
        return None
    except (OSError, IndexError):
        raise ValueError("Unexpected local server service") from None
    if not first.startswith(MARKER):
        raise ValueError("Unexpected local server service")
    try:
        arguments = json.loads(first[len(MARKER) :])
    except ValueError:
        raise ValueError("Unexpected local server service") from None
    if not isinstance(arguments, list) or any(not isinstance(a, str) for a in arguments):
        raise ValueError("Unexpected local server service")
    starts = [line[len("ExecStart=") :] for line in lines if line.startswith("ExecStart=")]
    try:
        command = shlex.split(starts[0]) if len(starts) == 1 else []
    except ValueError:
        command = []
    actual = [value.replace("%%", "%").replace("$$", "$") for value in command[3:]]
    if command[1:3] != ["-m", "chirp_server"] or actual != arguments:
        raise ValueError("Unexpected local server service")
    return arguments


def install(arguments=()):
    content = render(arguments)
    _arguments()  # Do not overwrite another program's unit or follow a symlink.
    path = location()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    systemctl("daemon-reload")
    systemctl("enable", "--now", UNIT)


def uninstall():
    if _arguments() is None:
        return
    systemctl("disable", "--now", UNIT)
    location().unlink()
    systemctl("daemon-reload")


def status():
    arguments = _arguments()
    running = False
    if arguments is not None:
        result = systemctl("is-active", UNIT, check=False)
        running = result.returncode == 0 and result.stdout.strip() == "active"
    return {
        "kind": KIND,
        "installed": arguments is not None,
        "running": running,
        "arguments": arguments or [],
        "location": str(location()),
    }


def restart(port):
    arguments = _arguments()
    if arguments is None:
        install(["--port", str(port)] if port != 7821 else [])
        return
    actual = 7821
    try:
        if "--port" in arguments:
            actual = int(arguments[arguments.index("--port") + 1])
    except (ValueError, IndexError):
        raise ValueError("Unexpected local server service") from None
    if actual != port:
        raise ValueError("Unexpected local server service")
    systemctl("restart", UNIT)


def listeners(port, *, proc=Path("/proc")):
    """This user's listening PIDs from procfs; no root access or lsof dependency."""
    uid = os.getuid()
    inodes = set()
    for family in ("tcp", "tcp6"):
        try:
            lines = (proc / "net" / family).read_text().splitlines()[1:]
        except FileNotFoundError:
            continue
        for line in lines:
            fields = line.split()
            if (
                len(fields) >= 10
                and fields[3] == "0A"
                and int(fields[1].split(":")[-1], 16) == port
                and int(fields[7]) == uid
            ):
                inodes.add(fields[9])
    found = []
    for process in proc.iterdir():
        if not process.name.isdigit():
            continue
        try:
            if process.stat().st_uid != uid:
                continue
            for fd in (process / "fd").iterdir():
                if os.readlink(fd) in {f"socket:[{inode}]" for inode in inodes}:
                    found.append(int(process.name))
                    break
        except (OSError, ValueError):
            continue
    return sorted(found)


def stop(pids):
    from ..restart import stop as posix_stop

    owned = []
    for pid in pids:
        try:
            if Path(f"/proc/{int(pid)}").stat().st_uid != os.getuid():
                return False
            owned.append(int(pid))
        except FileNotFoundError:
            pass
    return posix_stop(owned)
