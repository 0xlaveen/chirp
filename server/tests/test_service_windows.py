"""The Windows Task Scheduler backend and the portable setup/restart flows, on any host:
schtasks and PowerShell are faked; the task XML and argument handling are pure."""

import json
import sys
import xml.etree.ElementTree as ElementTree
from types import SimpleNamespace

import pytest

from chirp_server import restart, service, setup
from chirp_server.engine.onnx import choose_providers
from chirp_server.service import windows

NS = {"t": windows.NAMESPACE}
SID = "S-1-5-21-1-2-3-1001"


def test_task_xml_runs_the_server_at_logon_without_limits():
    xml = windows.task_xml(
        r"C:\Users\Zoë Q\chirp\.venv\Scripts\pythonw.exe",
        ["-m", "chirp_server", "--root-path", "/chirp a&b", "--port", "7900"],
        r"C:\Users\Zoë Q\AppData\Local\Chirp",
        SID,
    )
    root = ElementTree.fromstring(xml.split("?>", 1)[1])
    assert root.findtext("t:Triggers/t:LogonTrigger/t:UserId", namespaces=NS) == SID
    principal = root.find("t:Principals/t:Principal", NS)
    assert principal.findtext("t:LogonType", namespaces=NS) == "InteractiveToken"
    assert principal.findtext("t:RunLevel", namespaces=NS) == "LeastPrivilege"
    settings = root.find("t:Settings", NS)
    assert settings.findtext("t:ExecutionTimeLimit", namespaces=NS) == "PT0S"
    assert settings.findtext("t:DisallowStartIfOnBatteries", namespaces=NS) == "false"
    assert settings.findtext("t:StopIfGoingOnBatteries", namespaces=NS) == "false"
    assert settings.find("t:RestartOnFailure", NS) is not None
    command, arguments = windows.parse_task(xml)
    assert command.endswith("pythonw.exe") and "Zoë Q" in command
    assert arguments == ["-m", "chirp_server", "--root-path", "/chirp a&b", "--port", "7900"]
    assert windows.server_arguments((command, arguments))[-2:] == ["--port", "7900"]


def test_foreign_or_broken_tasks_are_not_ours():
    assert windows.parse_task("not xml") is None
    xml = windows.task_xml(r"C:\x\notepad.exe", ["readme.txt"], r"C:\x", SID)
    assert windows.server_arguments(windows.parse_task(xml)) is None
    assert windows.server_arguments(None) is None


def test_decode_handles_schtasks_utf16_and_utf8():
    text = "<Task>Zoë</Task>"
    assert windows.decode(text.encode("utf-16")) == text
    assert windows.decode(text.encode("utf-8")) == text


def test_port_of_reads_stored_arguments():
    assert service.port_of(None) == 7821
    assert service.port_of(["--root-path", "/chirp"]) == 7821
    assert service.port_of(["--port", "7900"]) == 7900


@pytest.mark.parametrize(
    ("requested", "available", "expected"),
    [
        ("cpu", ["DmlExecutionProvider", "CPUExecutionProvider"], ["CPUExecutionProvider"]),
        (
            "auto",
            ["DmlExecutionProvider", "CPUExecutionProvider"],
            ["DmlExecutionProvider", "CPUExecutionProvider"],
        ),
        (
            "auto",
            ["CUDAExecutionProvider", "DmlExecutionProvider", "CPUExecutionProvider"],
            ["CUDAExecutionProvider", "CPUExecutionProvider"],
        ),
        ("auto", ["CPUExecutionProvider"], ["CPUExecutionProvider"]),
        ("directml", ["CPUExecutionProvider"], ["CPUExecutionProvider"]),
        (
            "cuda",
            ["CUDAExecutionProvider", "CPUExecutionProvider"],
            ["CUDAExecutionProvider", "CPUExecutionProvider"],
        ),
    ],
)
def test_choose_providers_always_falls_back_to_cpu(requested, available, expected):
    assert choose_providers(requested, available) == expected


class FakeService:
    KIND = "fake"

    def __init__(self, installed=True, running=True, arguments=(), held=()):
        self.state = {
            "kind": "fake",
            "installed": installed,
            "running": running,
            "arguments": list(arguments) if arguments is not None else None,
            "location": "fake",
        }
        self.held, self.calls = list(held), []

    def status(self):
        return self.state

    def install(self, arguments=()):
        self.calls.append(("install", list(arguments)))

    def restart(self, port):
        self.calls.append(("restart", port))

    def listeners(self, port):
        return self.held

    def stop(self, pids):
        self.calls.append(("stop", list(pids)))
        return True


@pytest.fixture
def portable(monkeypatch):
    monkeypatch.setattr(sys, "platform", "win32")

    def use(fake):
        monkeypatch.setattr(service, "backend", lambda: fake)
        return fake

    return use


def events(capsys):
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def test_portable_start_installs_then_restarts(portable, monkeypatch, tmp_path):
    monkeypatch.setattr(setup.model_catalog, "root", lambda: tmp_path)
    fake = portable(FakeService(installed=False))
    setup.start_service(7900)
    assert fake.calls == [("install", ["--port", "7900"])]
    fake = portable(FakeService(arguments=["--port", "7900"]))
    setup.start_service(7900)
    assert fake.calls == [("restart", 7900)]


def test_portable_start_refuses_foreign_or_mismatched_services(portable, monkeypatch, tmp_path):
    monkeypatch.setattr(setup.model_catalog, "root", lambda: tmp_path)
    portable(FakeService(arguments=None))
    with pytest.raises(ValueError, match="Unexpected"):
        setup.start_service(7821)
    portable(FakeService(arguments=["--port", "7900"]))
    with pytest.raises(ValueError, match="port"):
        setup.start_service(7821)
    monkeypatch.setattr(setup.model_catalog, "pending_restart", lambda: True)
    portable(FakeService(arguments=["--engine", "onnx"]))
    with pytest.raises(ValueError, match="override"):
        setup.start_service(7821)


def test_portable_restart_needs_replace_for_an_unmanaged_server(portable, monkeypatch, capsys):
    monkeypatch.setattr(restart, "server_running", lambda port: True)
    fake = portable(FakeService(running=False, held=[4242]))
    assert restart.run(7821) == 1
    assert events(capsys)[-1]["reason"] == "unmanaged" and fake.calls == []
    assert restart.run(7821, replace=True) == 0
    assert fake.calls == [("stop", [4242]), ("restart", 7821)]
    assert [e["event"] for e in events(capsys)] == ["stopping", "starting", "restarted"]


def test_portable_restart_of_our_running_service(portable, monkeypatch, capsys):
    monkeypatch.setattr(restart, "server_running", lambda port: True)
    fake = portable(FakeService(running=True, held=[17]))
    assert restart.run(7821) == 0
    assert fake.calls == [("restart", 7821)]


def test_windows_restart_rejects_a_foreign_task(monkeypatch):
    monkeypatch.setattr(windows, "query", lambda: ("notepad.exe", ["x"]))
    monkeypatch.setattr(windows, "_run", lambda *a, **k: pytest.fail("must not touch the task"))
    with pytest.raises(ValueError, match="Unexpected"):
        windows.restart(7821)


def test_windows_status_and_listeners_parse_powershell(monkeypatch):
    task = ("pythonw.exe", ["-m", "chirp_server", "--port", "7900"])
    monkeypatch.setattr(windows, "query", lambda: task)
    monkeypatch.setattr(windows, "_powershell", lambda command, timeout=20: "Running")
    assert windows.status() == {
        "kind": "schtasks",
        "installed": True,
        "running": True,
        "arguments": ["--port", "7900"],
        "location": "Task Scheduler › Chirp Server",
    }
    monkeypatch.setattr(windows, "_powershell", lambda command, timeout=20: "4242\r\n0\r\n4242\r\n")
    assert windows.listeners(7821) == [4242]


def test_windows_install_registers_and_starts_the_task(monkeypatch, tmp_path):
    calls, written = [], []

    def run(args, timeout=20, check=False):
        calls.append(args[:2])
        if args[1] == "/Create":
            written.append(open(args[5], encoding="utf-16").read())
        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

    monkeypatch.setattr(windows, "_run", run)
    monkeypatch.setattr(windows, "state", lambda: "Ready")
    monkeypatch.setattr(windows.paths, "data_dir", lambda: tmp_path)
    monkeypatch.setitem(sys.modules, "chirp_server._win_acl", SimpleNamespace(user_sid=lambda: SID))
    windows.install(["--port", "7900"])
    assert calls == [
        ["schtasks.exe", "/Create"],
        ["schtasks.exe", "/End"],
        ["schtasks.exe", "/Run"],
    ]
    assert windows.server_arguments(windows.parse_task(written[0])) == ["--port", "7900"]


@pytest.mark.parametrize(
    ("fake", "status", "words"),
    [
        (FakeService(installed=False), "OK", "not installed"),
        (FakeService(arguments=None), "WARN", "does not run"),
        (FakeService(running=False), "WARN", "not running"),
        (FakeService(), "OK", "running"),
    ],
)
def test_doctor_reports_the_platform_service(portable, fake, status, words):
    from chirp_server import doctor

    portable(fake)
    check = doctor.check_service()
    assert (check.name, check.status) == ("service", status) and words in check.detail
