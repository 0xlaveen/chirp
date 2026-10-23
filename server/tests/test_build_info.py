"""Version, commit and capabilities in health, and the restart that fixes an out-of-date server."""

import json
import os
import plistlib
import time
from types import SimpleNamespace

from conftest import HEADERS

from chirp_server import build, restart, setup


def test_authenticated_health_reports_build_and_capabilities(client):
    health = client.get("/v1/health", headers=HEADERS).json()
    assert health["api"] == build.API_LEVEL
    assert health["version"] == build.version()
    assert set(build.CAPABILITIES) <= set(health["capabilities"])
    assert health["pid"] == os.getpid()
    assert health["started_at"] <= time.time()
    assert health["source"].endswith("server")
    assert "commit" in health


def test_capabilities_match_the_boolean_flags(client):
    health = client.get("/v1/health", headers=HEADERS).json()
    assert all(health[name] is True for name in health["capabilities"])


def test_unauthenticated_health_stays_minimal(client):
    assert client.get("/v1/health").json() == {"ok": True}


def test_commit_prefers_the_installers_file(tmp_path, monkeypatch):
    (tmp_path / build.COMMIT_FILE).write_text("0123456789abcdef\n")
    monkeypatch.setattr(build, "PACKAGE", tmp_path)
    build.commit.cache_clear()
    assert build.commit() == "0123456789ab"
    build.commit.cache_clear()


def test_commit_is_none_without_file_or_git(tmp_path, monkeypatch):
    monkeypatch.setattr(build, "PACKAGE", tmp_path)
    monkeypatch.setattr(
        build.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=128, stdout="")
    )
    build.commit.cache_clear()
    assert build.commit() is None
    build.commit.cache_clear()


def test_source_shortens_the_home_folder(tmp_path, monkeypatch):
    monkeypatch.setattr(build.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(build, "PACKAGE", tmp_path / "work/chirp/server/src/chirp_server")
    assert build.source() == "~/work/chirp/server"


def events(capsys):
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def fake_launchd(monkeypatch, tmp_path, *, held, jobs, plist=True):
    monkeypatch.setattr(restart.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(restart, "listeners", lambda port: held)
    monkeypatch.setattr(restart, "jobs", lambda: jobs)
    monkeypatch.setattr(restart, "server_running", lambda port: True)
    if plist:
        path = tmp_path / "Library/LaunchAgents/dev.chirp.server.plist"
        path.parent.mkdir(parents=True)
        path.write_bytes(
            plistlib.dumps(
                {"Label": "dev.chirp.server", "ProgramArguments": ["/p", "-m", "chirp_server"]}
            )
        )
    calls = []
    monkeypatch.setattr(
        restart,
        "_run",
        lambda args, timeout=10: calls.append(args[1]) or SimpleNamespace(returncode=0, stdout=""),
    )
    return calls


def test_restart_reloads_the_managed_agent(monkeypatch, tmp_path, capsys):
    calls = fake_launchd(monkeypatch, tmp_path, held=[7], jobs={"dev.chirp.server": 7})
    assert restart.run(7821) == 0
    assert calls == ["bootout", "bootstrap"]
    assert [e["event"] for e in events(capsys)] == ["starting", "restarted"]


def test_restart_refuses_a_server_another_agent_owns(monkeypatch, tmp_path, capsys):
    calls = fake_launchd(
        monkeypatch, tmp_path, held=[9], jobs={"dev.chirp.server": 0, "org.example.chirp": 9}
    )
    assert restart.run(7821, replace=True) == 1
    error = events(capsys)[-1]
    assert error["reason"] == "other_agent" and error["label"] == "org.example.chirp"
    assert "launchctl bootout" in error["message"] and calls == []


def test_restart_needs_replace_for_a_hand_started_server(monkeypatch, tmp_path, capsys):
    calls = fake_launchd(monkeypatch, tmp_path, held=[9], jobs={})
    assert restart.run(7821) == 1
    assert events(capsys)[-1]["reason"] == "unmanaged" and calls == []


def test_replace_stops_the_hand_started_server_then_starts_ours(monkeypatch, tmp_path, capsys):
    calls = fake_launchd(monkeypatch, tmp_path, held=[9], jobs={})
    stopped = []
    monkeypatch.setattr(restart, "stop", lambda pids: stopped.extend(pids) or True)
    assert restart.run(7821, replace=True) == 0
    assert stopped == [9] and calls == ["bootout", "bootstrap"]
    assert [e["event"] for e in events(capsys)] == ["stopping", "starting", "restarted"]


def test_setup_run_dispatches_restart_and_replace(monkeypatch):
    seen = []
    monkeypatch.setattr(restart, "run", lambda port, replace=False: seen.append(replace) or 0)
    assert setup.run("restart", "speech", None, 7899) == 0
    assert setup.run("replace", "speech", None, 7899) == 0
    assert seen == [False, True]


def test_jobs_parses_launchctl_list(monkeypatch):
    rows = ["PID\tStatus\tLabel", "4242\t0\tdev.chirp.server", "-\t0\tcom.example.idle"]
    listing = "\n".join([*rows, "17\t0\torg.example.chirp"])
    monkeypatch.setattr(restart, "_run", lambda *a, **k: SimpleNamespace(stdout=listing))
    assert restart.jobs() == {"dev.chirp.server": 4242, "org.example.chirp": 17}
    assert restart.owner(17) == "org.example.chirp" and restart.owner(5) is None
