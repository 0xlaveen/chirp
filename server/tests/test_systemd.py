"""Unit tests render commands only; never contact the user's systemd instance."""

import os
from types import SimpleNamespace

import pytest
from conftest import has_mode

from chirp_server.service import systemd

pytestmark = pytest.mark.skipif(os.name != "posix", reason="systemd is a POSIX service backend")


@pytest.fixture
def service(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    calls = []

    def run(*args, **kwargs):
        calls.append((args, kwargs))
        return SimpleNamespace(returncode=0, stdout="active\n")

    monkeypatch.setattr(systemd, "systemctl", run)
    return calls


def test_install_is_private_and_user_scoped(service):
    systemd.install(["--port", "7898", "--root-path", "/chirp"])
    content = systemd.location().read_text()
    assert '"--port" "7898" "--root-path" "/chirp"' in content
    assert "UMask=0077" in content and "StandardOutput=null" in content
    assert has_mode(systemd.location(), 0o600)
    assert service[0][0] == ("daemon-reload",)
    assert service[1][0] == ("enable", "--now", systemd.UNIT)
    status = systemd.status()
    assert status["installed"] and status["running"]
    assert status["arguments"] == ["--port", "7898", "--root-path", "/chirp"]
    systemd.uninstall()
    assert not systemd.location().exists()


def test_restart_respects_port_and_never_replaces_foreign_unit(service):
    systemd.restart(7898)
    with pytest.raises(ValueError, match="Unexpected local server service"):
        systemd.restart(7899)
    systemd.restart(7898)
    assert service[-1][0] == ("restart", systemd.UNIT)
    systemd.location().write_text("[Service]\nExecStart=/usr/bin/other\n")
    with pytest.raises(ValueError, match="Unexpected local server service"):
        systemd.install()
    with pytest.raises(ValueError, match="Unexpected local server service"):
        systemd.uninstall()


def test_quotes_systemd_metacharacters_and_rejects_newlines(service):
    assert systemd.quote('a "$HOME" %h \\') == '"a \\"$$HOME\\" %%h \\\\"'
    with pytest.raises(ValueError, match="control characters"):
        systemd.render(["--root-path", "bad\nExecStart=/bin/false"])
    assert not systemd.location().exists()


def test_refuses_symlink_unit(service, tmp_path):
    target = tmp_path / "foreign"
    target.write_text("keep")
    systemd.location().parent.mkdir(parents=True)
    systemd.location().symlink_to(target)
    with pytest.raises(ValueError, match="Unexpected local server service"):
        systemd.install()
    assert target.read_text() == "keep"


def test_listeners_use_own_listening_socket_inodes_without_lsof(tmp_path):
    import os

    proc = tmp_path / "proc"
    (proc / "net").mkdir(parents=True)
    (proc / "net" / "tcp").write_text(
        "header\n"
        f"0: 0100007F:1EDA 00000000:0000 0A 0:0 0:0 0 {os.getuid()} 0 1234\n"
        f"1: 0100007F:1EDB 00000000:0000 0A 0:0 0:0 0 {os.getuid()} 0 5678\n"
    )
    for pid, inode in [(111, 1234), (222, 5678)]:
        fd = proc / str(pid) / "fd"
        fd.mkdir(parents=True)
        (fd / "4").symlink_to(f"socket:[{inode}]")
    assert systemd.listeners(7898, proc=proc) == [111]
    assert systemd.listeners(7899, proc=proc) == [222]


def test_managed_marker_cannot_hide_a_foreign_execstart(service):
    systemd.install(["--port", "7898"])
    content = systemd.location().read_text().replace('"-m" "chirp_server"', '"-m" "another_server"')
    systemd.location().write_text(content)
    with pytest.raises(ValueError, match="Unexpected local server service"):
        systemd.restart(7898)
    with pytest.raises(ValueError, match="Unexpected local server service"):
        systemd.install()
