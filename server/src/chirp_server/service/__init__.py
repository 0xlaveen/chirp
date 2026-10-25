"""The per-user service that keeps the server running, one backend per platform.

Every backend module provides the same functions, all explicit user actions (never called on
server startup or by tests against the real system):

- `KIND`: "launchd", "schtasks" or "systemd".
- `install(arguments=())`: register the service to run `python -m chirp_server *arguments` at
  logon and start it now. Idempotent.
- `uninstall()`: stop and unregister it; no error when it is absent.
- `restart(port)`: restart the registered service with its stored arguments, or install it with
  `--port` when none is registered. Raises ValueError when the registered service is not a
  `python -m chirp_server` one.
- `status()`: {"kind", "installed", "running" (bool, or None when unknown), "arguments" (the
  arguments after `-m chirp_server`, or None), "location" (where it is registered)}.
- `listeners(port)`: PIDs of this user's processes listening on 127.0.0.1:`port`.
- `stop(pids)`: stop those processes; True once they have all exited.
"""

import sys

LABEL = "dev.chirp.server"
DEFAULT_PORT = 7821


def backend():
    if sys.platform == "darwin":
        from . import launchd

        return launchd
    if sys.platform == "win32":
        from . import windows

        return windows
    if sys.platform.startswith("linux"):
        try:
            from . import systemd
        except ImportError:
            pass
        else:
            return systemd
    raise RuntimeError(f"No background service support on {sys.platform}")


def port_of(arguments) -> int:
    """The --port among stored service arguments (the default when absent)."""
    arguments = list(arguments or ())
    if "--port" in arguments:
        return int(arguments[arguments.index("--port") + 1])
    return DEFAULT_PORT
