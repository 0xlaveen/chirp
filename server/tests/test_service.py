import plistlib
import sys

from chirp_server import cli


def test_service_install_forwards_root_path_and_port(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(cli.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: calls.append(a[0]))
    monkeypatch.setattr(
        sys, "argv", ["chirp-server", "--root-path", "/chirp", "service", "install"]
    )
    cli.main()
    plist = plistlib.loads((tmp_path / "Library/LaunchAgents/dev.chirp.server.plist").read_bytes())
    assert plist["ProgramArguments"][1:] == ["-m", "chirp_server", "--root-path", "/chirp"]
    assert calls and calls[0][:2] == ["launchctl", "bootstrap"]

    monkeypatch.setattr(sys, "argv", ["chirp-server", "--port", "7900", "service", "install"])
    cli.main()
    plist = plistlib.loads((tmp_path / "Library/LaunchAgents/dev.chirp.server.plist").read_bytes())
    assert plist["ProgramArguments"][3:] == ["--port", "7900"]
