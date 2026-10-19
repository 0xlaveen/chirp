import json
from types import SimpleNamespace

import pytest

from chirp_server import setup


def events(capsys):
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def test_status_is_offline_and_reports_both_models(settings, monkeypatch):
    monkeypatch.setattr(setup.speech_models, "discover", lambda: "/cached/speech")
    monkeypatch.setattr(
        setup.cleanup_models, "discover", lambda *_: (_ for _ in ()).throw(ValueError())
    )
    rows = setup.status(settings)
    assert [(r["id"], r["ready"]) for r in rows] == [("speech", True), ("cleanup", False)]


def test_cached_download_does_not_contact_hub(settings, monkeypatch, capsys):
    import huggingface_hub

    monkeypatch.setattr(setup, "configure_downloads", lambda: None)
    monkeypatch.setattr(setup.speech_models, "discover", lambda: "/cached/speech")
    monkeypatch.setattr(
        huggingface_hub,
        "snapshot_download",
        lambda *a, **k: pytest.fail("network for a cached model"),
    )
    setup.download("speech", settings)
    assert events(capsys)[-1] == {"event": "complete", "model": "speech"}


def test_byte_progress_includes_cached_files_and_resume_offset(settings, monkeypatch, capsys):
    import huggingface_hub

    monkeypatch.setattr(setup, "configure_downloads", lambda: None)
    calls = 0

    def discover():
        nonlocal calls
        calls += 1
        if calls == 1:
            raise ValueError("not installed")
        return "/cached/speech"

    monkeypatch.setattr(setup.speech_models, "discover", discover)
    plan = [
        SimpleNamespace(file_size=10, will_download=False, filename="config.json"),
        SimpleNamespace(file_size=100, will_download=True, filename="model.safetensors"),
    ]
    monkeypatch.setattr(huggingface_hub, "snapshot_download", lambda *a, **k: plan)

    def fetch(repo, filename, **kwargs):
        assert repo == setup.speech_models.REPOSITORY
        assert kwargs["revision"] == setup.speech_models.REVISION
        with kwargs["tqdm_class"](total=100, initial=40) as bar:
            bar.update(60)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fetch)
    setup.download("speech", settings)
    output = events(capsys)
    progress = [e for e in output if e.get("phase") == "downloading"]
    assert any(e["completed_bytes"] == 50 for e in progress)
    assert progress[-1]["completed_bytes"] == progress[-1]["total_bytes"] == 110
    assert output[-1]["event"] == "complete"
    assert calls == 2  # Completion is checked again after all files arrive.


def test_failed_or_interrupted_download_never_reports_complete(settings, monkeypatch, capsys):
    monkeypatch.setattr(setup.Settings, "read", lambda *_: settings)
    monkeypatch.setattr(
        setup,
        "download",
        lambda *_: (_ for _ in ()).throw(OSError("https://signed.invalid/?secret=value")),
    )
    assert setup.run("download", "cleanup", None, 7821) == 1
    output = events(capsys)
    assert output[-1]["event"] == "error"
    assert "secret" not in json.dumps(output)
    monkeypatch.setattr(setup, "download", lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    assert setup.run("download", "cleanup", None, 7821) == 130
    assert events(capsys)[-1]["event"] == "cancelled"


def test_start_reuses_a_running_server_without_touching_launchd(monkeypatch, capsys):
    monkeypatch.setattr(setup.speech_models, "discover", lambda: "/cached/speech")
    monkeypatch.setattr(setup, "server_running", lambda _: True)
    monkeypatch.setattr(
        setup.subprocess, "run", lambda *a, **k: pytest.fail("unexpected service restart")
    )
    setup.start_server(7821)
    assert events(capsys) == [{"event": "started"}]


def test_start_reloads_managed_plist_without_rewriting_it(tmp_path, monkeypatch, capsys):
    import plistlib

    monkeypatch.setattr(setup.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(setup.speech_models, "discover", lambda: "/cached/speech")
    replies = iter([False, True])
    monkeypatch.setattr(setup, "server_running", lambda _: next(replies))
    path = tmp_path / "Library/LaunchAgents/dev.chirp.server.plist"
    path.parent.mkdir(parents=True)
    content = plistlib.dumps(
        {
            "Label": "dev.chirp.server",
            "ProgramArguments": ["/managed/python", "-m", "chirp_server", "--root-path", "/chirp"],
        }
    )
    path.write_bytes(content)
    path.chmod(0o444)
    calls = []
    monkeypatch.setattr(
        setup.subprocess, "run", lambda args, **kwargs: calls.append((args, kwargs))
    )
    setup.start_server(7821)
    assert path.read_bytes() == content
    assert [c[0][1] for c in calls] == ["bootout", "bootstrap"]
    assert all(c[1]["timeout"] == 10 for c in calls)
    assert events(capsys)[-1]["event"] == "started"


def test_download_uses_verified_http_and_honors_explicit_ca(monkeypatch):
    monkeypatch.setenv("SSL_CERT_FILE", "/custom/trusted.pem")
    monkeypatch.delenv("HF_HUB_DISABLE_XET", raising=False)
    setup.configure_downloads()
    assert setup.os.environ["HF_HUB_DISABLE_XET"] == "1"
    assert setup.os.environ["SSL_CERT_FILE"] == "/custom/trusted.pem"
