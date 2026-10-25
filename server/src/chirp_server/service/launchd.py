"""macOS: the `dev.chirp.server` LaunchAgent. The implementation stays where it has always been
(`cli.service`, `restart`); this module only gives it the shared backend interface."""

import plistlib
from pathlib import Path

from . import LABEL

KIND = "launchd"


def plist_path() -> Path:
    return Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"


def install(arguments=()):
    from ..cli import service

    service("install", list(arguments))


def uninstall():
    from ..cli import service

    service("uninstall")


def restart(port):
    from ..restart import reload_agent

    reload_agent(port)


def status() -> dict:
    from ..restart import jobs

    path = plist_path()
    arguments = None
    if path.is_file():
        try:
            program = plistlib.loads(path.read_bytes()).get("ProgramArguments", [])
        except (OSError, ValueError, plistlib.InvalidFileException):
            program = []
        if program[1:3] == ["-m", "chirp_server"]:
            arguments = program[3:]
    return {
        "kind": KIND,
        "installed": path.is_file(),
        "running": LABEL in jobs() if path.is_file() else False,
        "arguments": arguments,
        "location": str(path),
    }


def listeners(port):
    from ..restart import listeners as lsof_listeners

    return lsof_listeners(port)


def stop(pids):
    from ..restart import stop as stop_pids

    return stop_pids(pids)
