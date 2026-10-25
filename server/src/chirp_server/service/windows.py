"""Windows: a per-user Task Scheduler logon task, registered without administrator rights.

The task runs `pythonw.exe -m chirp_server …` (no console window) when the user logs on, only
while they are logged on, restarts after a failure, and never stops on battery or after a time
limit. Its output is discarded, like the macOS LaunchAgent's. The XML and argument handling are
pure functions so every platform's tests cover them; `schtasks` and PowerShell run only here.
"""

import contextlib
import os
import shlex
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ElementTree
from pathlib import Path
from xml.sax.saxutils import escape

from .. import paths

KIND = "schtasks"
TASK = "Chirp Server"
NAMESPACE = "http://schemas.microsoft.com/windows/2004/02/mit/task"
# Hide console windows of the helper commands when called from a windowed client.
CREATE_NO_WINDOW = 0x08000000


def task_xml(command: str, arguments: list[str], working_directory: str, user: str) -> str:
    """A Task Scheduler 1.2 definition for `command arguments` at `user`'s logon."""
    values = {
        "user": escape(user),
        "command": escape(command),
        "arguments": escape(subprocess.list2cmdline(arguments)),
        "directory": escape(working_directory),
    }
    return """<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="{namespace}">
  <RegistrationInfo>
    <Description>Chirp speech server, listening on 127.0.0.1 only.</Description>
    <URI>\\{task}</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{user}</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{user}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{command}</Command>
      <Arguments>{arguments}</Arguments>
      <WorkingDirectory>{directory}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
""".format(namespace=NAMESPACE, task=TASK, **values)


def parse_task(xml: str) -> tuple[str, list[str]] | None:
    """(command, arguments) of a task definition's first Exec action, or None."""
    # ElementTree refuses str input that still declares an encoding.
    if xml.lstrip().startswith("<?xml"):
        xml = xml.split("?>", 1)[1]
    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError:
        return None
    exec_ = root.find(f"{{{NAMESPACE}}}Actions/{{{NAMESPACE}}}Exec")
    if exec_ is None:
        return None
    command = exec_.findtext(f"{{{NAMESPACE}}}Command", "")
    arguments = exec_.findtext(f"{{{NAMESPACE}}}Arguments", "")
    # Windows rules: quotes group, no escapes beyond the quotes list2cmdline writes.
    words = [word.strip('"') for word in shlex.split(arguments, posix=False)]
    return command, words


def server_arguments(task: tuple[str, list[str]] | None) -> list[str] | None:
    """The arguments after `-m chirp_server`, or None for any other program."""
    if task is None or task[1][:2] != ["-m", "chirp_server"]:
        return None
    return task[1][2:]


def windowless_python() -> str:
    """pythonw.exe next to this interpreter (a venv has both), else this interpreter."""
    executable = Path(sys.executable).absolute()
    candidate = executable.with_name("pythonw.exe")
    return str(candidate if candidate.is_file() else executable)


def decode(output: bytes) -> str:
    if output.startswith((b"\xff\xfe", b"\xfe\xff")):
        return output.decode("utf-16")
    try:
        return output.decode("utf-8")
    except UnicodeDecodeError:
        return output.decode("mbcs" if sys.platform == "win32" else "latin-1", errors="replace")


def _run(args, timeout=20, check=False):
    return subprocess.run(
        args,
        capture_output=True,
        timeout=timeout,
        check=check,
        creationflags=CREATE_NO_WINDOW if sys.platform == "win32" else 0,
    )


def _powershell(command: str, timeout=20) -> str:
    try:
        result = _run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command], timeout
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return decode(result.stdout).strip() if result.returncode == 0 else ""


def query() -> tuple[str, list[str]] | None:
    """The registered task's action, or None when the task does not exist."""
    try:
        result = _run(["schtasks.exe", "/Query", "/TN", TASK, "/XML", "ONE"])
    except (OSError, subprocess.SubprocessError):
        return None
    return parse_task(decode(result.stdout)) if result.returncode == 0 else None


def state() -> str:
    """Task Scheduler's state name (Ready, Running, Disabled), or "" when unknown."""
    return _powershell(f"(Get-ScheduledTask -TaskName '{TASK}' -ErrorAction Stop).State")


def install(arguments=()):
    from .._win_acl import user_sid

    working_directory = paths.data_dir()
    working_directory.mkdir(parents=True, exist_ok=True)
    definition = task_xml(
        windowless_python(),
        ["-m", "chirp_server", *arguments],
        str(working_directory),
        user_sid(),
    )
    # schtasks reads UTF-16 task files; the temporary file holds no secret.
    descriptor, name = tempfile.mkstemp(suffix=".xml")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-16") as stream:
            stream.write(definition)
        _run(["schtasks.exe", "/Create", "/TN", TASK, "/XML", name, "/F"], check=True)
    finally:
        with contextlib.suppress(OSError):
            os.unlink(name)
    _end()
    _run(["schtasks.exe", "/Run", "/TN", TASK], check=True)


def _end():
    try:
        _run(["schtasks.exe", "/End", "/TN", TASK])
    except (OSError, subprocess.SubprocessError):
        return
    # /End returns before the process has exited; give it a moment to release the port.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and state() == "Running":
        time.sleep(0.25)


def uninstall():
    if query() is None:
        return
    _end()
    _run(["schtasks.exe", "/Delete", "/TN", TASK, "/F"])


def restart(port):
    task = query()
    if task is None:
        from . import DEFAULT_PORT

        install(["--port", str(port)] if port != DEFAULT_PORT else [])
        return
    if server_arguments(task) is None:
        raise ValueError("Unexpected local server service")
    _end()
    _run(["schtasks.exe", "/Run", "/TN", TASK], check=True)


def status() -> dict:
    task = query()
    return {
        "kind": KIND,
        "installed": task is not None,
        "running": (state() == "Running") if task is not None else False,
        "arguments": server_arguments(task),
        "location": f"Task Scheduler › {TASK}",
    }


def listeners(port) -> list[int]:
    output = _powershell(
        f"Get-NetTCPConnection -LocalPort {int(port)} -State Listen -ErrorAction SilentlyContinue"
        " | Select-Object -ExpandProperty OwningProcess"
    )
    return sorted({int(word) for word in output.split() if word.isdigit() and int(word) > 0})


def alive(pid) -> bool:
    output = _powershell(f"Get-Process -Id {int(pid)} -ErrorAction SilentlyContinue | % Id")
    return output.strip() == str(int(pid))


def stop(pids) -> bool:
    # A windowless server cannot receive Ctrl+C; taskkill /F is TerminateProcess.
    for pid in pids:
        with contextlib.suppress(OSError, subprocess.SubprocessError):
            _run(["taskkill.exe", "/PID", str(int(pid)), "/F"])
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if not any(alive(pid) for pid in pids):
            return True
        time.sleep(0.2)
    return False
