import pytest

from chirp_server import platforms
from chirp_server.config import Settings


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
