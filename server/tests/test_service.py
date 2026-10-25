import plistlib
import sys
from types import SimpleNamespace

from chirp_server import cli


def test_service_install_reloads_an_existing_agent(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(cli.Path, "home", lambda: tmp_path)

    def run(arguments, *args, **kwargs):
        calls.append(arguments)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(cli.subprocess, "run", run)
    monkeypatch.setattr(
        sys, "argv", ["chirp-server", "--root-path", "/chirp", "service", "install"]
    )
    cli.main()
    plist = plistlib.loads((tmp_path / "Library/LaunchAgents/dev.chirp.server.plist").read_bytes())
    assert plist["ProgramArguments"][1:] == ["-m", "chirp_server", "--root-path", "/chirp"]
    assert [call[1] for call in calls] == ["bootout", "bootstrap"]

    monkeypatch.setattr(sys, "argv", ["chirp-server", "--port", "7900", "service", "install"])
    cli.main()
    plist = plistlib.loads((tmp_path / "Library/LaunchAgents/dev.chirp.server.plist").read_bytes())
    assert plist["ProgramArguments"][3:] == ["--port", "7900"]
    # A second install boots out the loaded agent before bootstrapping the new plist.
    assert [call[1] for call in calls] == ["bootout", "bootstrap", "bootout", "bootstrap"]


def test_service_install_retries_while_bootout_settles(tmp_path, monkeypatch):
    attempts, sleeps = [], []

    def run(arguments, *args, **kwargs):
        if arguments[1] == "bootstrap":
            attempts.append(arguments[1])
            return SimpleNamespace(returncode=1 if len(attempts) < 3 else 0)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(cli.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(cli.subprocess, "run", run)
    monkeypatch.setattr(cli.time, "sleep", sleeps.append)
    monkeypatch.setattr(sys, "argv", ["chirp-server", "service", "install"])

    cli.main()

    assert len(attempts) == 3
    assert sleeps == [0.5, 0.5]
