import pytest
from conftest import use_home

from chirp_server import platforms
from chirp_server.config import Settings


@pytest.fixture(autouse=True)
def isolated_home(monkeypatch, tmp_path):
    use_home(monkeypatch, tmp_path)


@pytest.mark.parametrize(
    "system,machine,expected",
    [
        ("darwin", "arm64", "mlx"),
        ("darwin", "aarch64", "mlx"),
        ("darwin", "x86_64", "onnx"),
        ("darwin", "AMD64", "onnx"),
        ("linux", "aarch64", "onnx"),
        ("linux", "x86_64", "onnx"),
        ("win32", "AMD64", "onnx"),
        ("win32", "ARM64", "onnx"),
    ],
)
def test_hardware_defaults(system, machine, expected, monkeypatch, tmp_path):
    monkeypatch.setattr(platforms.sys, "platform", system)
    monkeypatch.setattr(platforms.platform, "machine", lambda: machine)
    assert platforms.default_engine() == expected
    assert Settings().engine == expected
    config = tmp_path / "server.toml"
    config.write_text('[correction]\nmode = "off"\n')
    assert Settings.read(config).engine == expected
    assert platforms.default_cleanup_backend() == ("mlx" if expected == "mlx" else "llama_cpp")


def test_explicit_engine_is_preserved(monkeypatch, tmp_path):
    monkeypatch.setattr(platforms.sys, "platform", "darwin")
    monkeypatch.setattr(platforms.platform, "machine", lambda: "arm64")
    config = tmp_path / "server.toml"
    config.write_text('engine = "onnx"\n')
    assert Settings.read(config).engine == "onnx"


def test_portable_model_discovery_and_selection(monkeypatch, tmp_path):
    from chirp_server import model_catalog, setup
    from chirp_server.engine import models

    monkeypatch.setattr(model_catalog, "root", lambda: tmp_path / "config")
    monkeypatch.setattr(model_catalog, "verify", lambda _: None)
    monkeypatch.setattr(models, "model_root", lambda: tmp_path / "models")
    directory = models.model_root() / "parakeet-onnx"
    directory.mkdir(parents=True)
    for filename in models.ONNX_FILES:
        (directory / filename).write_bytes(b"synthetic model fixture")
    settings = Settings(engine="onnx")
    assert setup.discover_speech(settings) == directory
    assert model_catalog.active_ids(settings)["speech"] == models.ONNX_MODEL_ID
    choice = model_catalog.choose(models.ONNX_MODEL_ID, "speech")
    model_catalog.apply_settings(settings)
    assert settings.engine == "onnx" and settings.model_dir == directory
    assert settings.speech_model == choice.id
    (directory / "nemo128.onnx").unlink()
    with pytest.raises(ValueError, match="missing or incomplete"):
        setup.discover_speech(settings)
