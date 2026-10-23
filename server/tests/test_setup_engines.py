"""The Mac picker switches between MLX Parakeet and SenseVoice without editing server.toml."""

import json
import sys
import tomllib
from pathlib import Path
from types import SimpleNamespace

import pytest

from chirp_server import model_catalog as catalog
from chirp_server import setup
from chirp_server.config import Settings
from chirp_server.engine import sensevoice_models

SENSEVOICE = "sensevoice-small"


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(catalog, "verify", lambda _: None)
    monkeypatch.setattr(sensevoice_models, "runtime_installed", lambda: True)


def events(capsys):
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


def config(tmp_path, text=""):
    path = tmp_path / "server.toml"
    path.write_text(text)
    return path


def test_catalog_lists_speech_models_by_engine_with_sensevoice_pinned():
    models = catalog.catalog()
    assert {m.id: m.engine for m in models.values() if m.kind == "speech"} == {
        "parakeet-v2": "mlx",
        "parakeet-v3": "mlx",
        SENSEVOICE: "sensevoice",
    }
    option = models[SENSEVOICE]
    assert (option.repository, option.revision) == (
        sensevoice_models.REPOSITORY,
        sensevoice_models.REVISION,
    )
    assert "Cantonese" in option.details and option.size_bytes > 900_000_000
    assert all(not m.engine for m in models.values() if m.kind == "cleanup")
    with pytest.raises(ValueError):
        catalog.Model("x", "cleanup", "x", "o/x", "a" * 40, engine="sensevoice")
    with pytest.raises(ValueError):
        catalog.Model("x", "speech", "x", "o/x", "a" * 40, engine="whisper")


def test_status_and_catalog_report_the_configured_engine(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(setup, "server_running", lambda _: False)
    monkeypatch.setattr(sensevoice_models, "discover", lambda *a: tmp_path)
    monkeypatch.setattr(catalog, "ready", lambda m: m.engine == "sensevoice")
    assert setup.run("status", None, config(tmp_path, 'engine = "sensevoice"\n'), 7899) == 0
    status, listing = events(capsys)
    assert status["models"][0] == {
        "id": "speech",
        "title": "SenseVoice · Speech recognition",
        "ready": True,
    }
    assert listing["active_models"]["speech"] == SENSEVOICE
    option = next(o for o in listing["options"] if o["id"] == SENSEVOICE)
    assert option["engine"] == "sensevoice" and option["ready"] and option["active"]


def test_switching_engines_both_ways_overrides_toml_without_editing_it(tmp_path):
    path = config(tmp_path, 'engine = "mlx"\n[sensevoice]\nnum_threads = 2\n')
    original = path.read_bytes()
    catalog.choose(SENSEVOICE, "speech")
    settings = Settings.read(path)
    assert (settings.engine, settings.speech_model, settings.model_dir) == (
        "sensevoice",
        SENSEVOICE,
        None,
    )
    assert settings.sensevoice_num_threads == 2  # Threads stay in server.toml.
    assert path.read_bytes() == original
    assert catalog.pending_restart() and catalog.active_ids(settings)["speech"] == SENSEVOICE
    catalog.choose("parakeet-v3", "speech")
    settings = Settings.read(path)
    assert (settings.engine, settings.speech_model) == ("mlx", "parakeet-v3")
    assert settings.model_dir.name == catalog.resolve("parakeet-v3").revision
    path.write_text('engine = "sensevoice"\n')
    assert Settings.read(path).engine == "mlx"  # The newer app choice wins over the file.
    catalog.choose(SENSEVOICE, "speech")
    path.write_text('engine = "mlx"\n')
    assert Settings.read(path).engine == "sensevoice"
    assert tomllib.loads(path.read_text()) == {"engine": "mlx"}


def test_selections_from_before_engine_switching_keep_the_toml_engine(tmp_path):
    state = catalog.root() / "model-selection.json"
    state.parent.mkdir(parents=True)
    legacy = {k: v for k, v in catalog.asdict(catalog.resolve("parakeet-v3")).items()}
    del legacy["engine"]
    state.write_text(json.dumps({"speech": legacy}))
    settings = Settings.read(config(tmp_path, 'engine = "sensevoice"\n'))
    assert (settings.engine, settings.speech_model, settings.model_dir) == (
        "sensevoice",
        SENSEVOICE,
        None,
    )
    assert Settings.read(config(tmp_path)).speech_model == "parakeet-v3"


def test_added_parakeet_repository_is_selected_as_mlx(tmp_path, monkeypatch):
    added = catalog.Model("o/p@" + "b" * 40, "speech", "p", "o/p", "b" * 40)
    monkeypatch.setattr(catalog, "catalog", lambda: {added.id: added})
    assert catalog.choose(added.id, "speech").engine == "mlx"
    settings = Settings.read(config(tmp_path, 'engine = "sensevoice"\n'))
    assert (settings.engine, settings.speech_model) == ("mlx", added.id)


def test_select_and_start_switch_engines_instead_of_refusing(tmp_path, monkeypatch, capsys):
    path = config(tmp_path, 'engine = "sensevoice"\n')
    assert setup.run("select", "speech", path, 7899, "parakeet-v3") == 0
    assert events(capsys)[1] == {"event": "selected", "model": "speech", "choice": "parakeet-v3"}
    started = []
    monkeypatch.setattr(setup, "start_server", lambda *a: started.append(a))
    assert setup.run("start", None, path, 7899) == 0
    assert started[-1][2] == "mlx"
    assert setup.run("select", "speech", path, 7899, SENSEVOICE) == 0
    assert setup.run("start", None, path, 7899) == 0
    assert started[-1] == (7899, None, "sensevoice")


def test_verify_loads_sensevoice_on_cpu_before_saving(tmp_path, monkeypatch):
    from chirp_server.engine import sensevoice

    monkeypatch.undo()
    monkeypatch.setenv("HOME", str(tmp_path))
    calls = []

    class Engine:
        def __init__(self, path, *a):
            calls.append(("init", path))

        def load(self):
            calls.append("load")

        def warm(self):
            calls.append("warm")

    monkeypatch.setattr(sensevoice, "SenseVoice", Engine)
    monkeypatch.setattr(sensevoice_models, "discover", lambda *a: tmp_path / "sv")
    monkeypatch.setattr(
        "chirp_server.engine.mlx.ParakeetMLX", lambda *a: pytest.fail("MLX for SenseVoice")
    )
    catalog.verify(catalog.resolve(SENSEVOICE))
    assert calls == [("init", tmp_path / "sv"), "load", "warm"]


def test_start_needs_the_sensevoice_runtime_and_files_not_mlx(monkeypatch, capsys):
    monkeypatch.setattr(setup.speech_models, "discover", lambda *a: pytest.fail("MLX model"))
    monkeypatch.setattr(sensevoice_models, "discover", lambda *a: Path("/sv"))
    monkeypatch.setattr(setup, "server_running", lambda _: True)
    monkeypatch.setattr(catalog, "pending_restart", lambda: False)
    setup.start_server(7899, None, "sensevoice")
    assert events(capsys) == [{"event": "started"}]
    monkeypatch.setattr(sensevoice_models, "runtime_installed", lambda: False)
    with pytest.raises(ValueError):
        setup.start_server(7899, None, "sensevoice")


def test_start_refuses_a_service_that_pins_the_engine(tmp_path, monkeypatch):
    import plistlib

    monkeypatch.setattr(setup.speech_models, "discover", lambda: "/cached/speech")
    monkeypatch.setattr(setup, "server_running", lambda _: False)
    monkeypatch.setattr(catalog, "pending_restart", lambda: True)
    monkeypatch.setattr(setup.subprocess, "run", lambda *a, **k: pytest.fail("launchctl"))
    path = tmp_path / "Library/LaunchAgents/dev.chirp.server.plist"
    path.parent.mkdir(parents=True)
    arguments = ["/managed/python", "-m", "chirp_server", "--engine", "mlx"]
    path.write_bytes(plistlib.dumps({"Label": "dev.chirp.server", "ProgramArguments": arguments}))
    with pytest.raises(ValueError, match="override"):
        setup.start_server(7821)


def sensevoice_download(monkeypatch, tmp_path, installed):
    import huggingface_hub

    state = {"installed": installed, "files": False}
    calls = []
    monkeypatch.setattr(setup, "configure_downloads", lambda: None)
    monkeypatch.setattr(sensevoice_models, "runtime_installed", lambda: state["installed"])

    def install():
        calls.append("install")
        state["installed"] = True

    monkeypatch.setattr(sensevoice_models, "install_runtime", install)
    monkeypatch.setattr(catalog, "ready", lambda m: state["installed"] and state["files"])
    plan = [
        SimpleNamespace(file_size=100, will_download=True, filename="model.onnx"),
        SimpleNamespace(file_size=10, will_download=False, filename="tokens.txt"),
    ]

    def dry_run(repository, **kwargs):
        assert repository == sensevoice_models.REPOSITORY
        assert kwargs["revision"] == sensevoice_models.REVISION
        assert kwargs["allow_patterns"] == sensevoice_models.HUB_FILES
        assert (
            kwargs["local_dir"]
            == tmp_path / "Library/Application Support/Chirp/models" / SENSEVOICE
        )
        return plan

    monkeypatch.setattr(huggingface_hub, "snapshot_download", dry_run)

    def fetch(repository, filename, **kwargs):
        calls.append(filename)
        with kwargs["tqdm_class"](total=100) as bar:
            bar.update(100)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", fetch)

    def vad(directory):
        calls.append("vad")
        state["files"] = True

    monkeypatch.setattr(sensevoice_models, "fetch_vad", vad)
    return calls


def test_sensevoice_download_installs_runtime_then_fetches_with_progress(
    tmp_path, monkeypatch, capsys
):
    calls = sensevoice_download(monkeypatch, tmp_path, installed=False)
    setup.download("speech", Settings(), SENSEVOICE)
    output = events(capsys)
    assert calls == ["install", "model.onnx", "vad"]
    phases = [e.get("phase") for e in output if e["event"] == "progress"]
    assert phases[:2] == ["preparing", "installing"] and "downloading" in phases
    downloading = [e for e in output if e.get("phase") == "downloading"]
    assert downloading[-1]["completed_bytes"] == downloading[-1]["total_bytes"] == 110
    assert output[-1] == {"event": "complete", "model": "speech"}


def test_sensevoice_download_skips_install_when_present(tmp_path, monkeypatch, capsys):
    calls = sensevoice_download(monkeypatch, tmp_path, installed=True)
    setup.download("speech", Settings(), SENSEVOICE)
    assert "install" not in calls
    assert "installing" not in {e.get("phase") for e in events(capsys)}


def test_runtime_that_cannot_be_installed_reports_how_to_fix(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(sensevoice_models, "runtime_installed", lambda: False)
    monkeypatch.setattr(sensevoice_models, "install_command", lambda: None)
    monkeypatch.setattr(setup, "configure_downloads", lambda: None)
    assert setup.run("download", "speech", config(tmp_path), 7899, SENSEVOICE) == 1
    error = events(capsys)[-1]
    assert error["event"] == "error" and error["model"] == "speech"
    assert "uv sync --extra sensevoice" in error["message"]


def test_install_command_uses_the_lock_or_pinned_requirements(tmp_path, monkeypatch):
    pyproject = tomllib.loads((Path(__file__).parents[1] / "pyproject.toml").read_text())
    assert (
        list(sensevoice_models.REQUIREMENTS)
        == pyproject["project"]["optional-dependencies"]["sensevoice"]
    )
    monkeypatch.setattr(sensevoice_models.shutil, "which", lambda _: "/bin/uv")
    project = tmp_path / "server"
    (project / ".venv").mkdir(parents=True)
    (project / "uv.lock").write_text("")
    monkeypatch.setattr(sys, "prefix", str(project / ".venv"))
    command = sensevoice_models.install_command()
    assert command[:2] == ["/bin/uv", "sync"] and "--locked" in command
    assert command[-2:] == ["--extra", "sensevoice"] and "--inexact" in command
    (project / "uv.lock").unlink()
    command = sensevoice_models.install_command()
    assert command[:3] == ["/bin/uv", "pip", "install"]
    assert command[-2:] == list(sensevoice_models.REQUIREMENTS)
    (project / ".venv").chmod(0o555)
    try:
        assert sensevoice_models.install_command() is None
    finally:
        (project / ".venv").chmod(0o755)


def test_installer_failure_hides_output_and_reports_a_generic_error(tmp_path, monkeypatch, capsys):
    import subprocess

    monkeypatch.setattr(sensevoice_models, "runtime_installed", lambda: False)
    monkeypatch.setattr(sensevoice_models, "install_command", lambda: ["/bin/uv", "pip"])

    def fail(*a, **k):
        raise subprocess.CalledProcessError(1, a[0], output=b"https://token@index.invalid")

    monkeypatch.setattr(sensevoice_models.subprocess, "run", fail)
    monkeypatch.setattr(setup, "configure_downloads", lambda: None)
    assert setup.run("download", "speech", config(tmp_path), 7899, SENSEVOICE) == 1
    output = json.dumps(events(capsys))
    assert "token@" not in output and "Could not finish setup" in output
