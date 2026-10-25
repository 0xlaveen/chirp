"""Exercise standalone server installation with a fake uv and isolated HOME."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

# install-mac.sh is a POSIX shell script.
pytestmark = pytest.mark.skipif(sys.platform == "win32", reason="POSIX shell installer")


@pytest.mark.parametrize("machine", ["arm64", "x86_64"])
def test_server_install_requires_no_dotfiles_and_preserves_configuration(tmp_path, machine):
    home = tmp_path / "home with spaces"
    config = home / ".config/chirp/server.toml"
    config.parent.mkdir(parents=True)
    config.write_text('[correction]\nmode = "off"\n')
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text(
        f'#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo {machine};; esac\n'
    )
    (fake_bin / "uv").write_text(
        '#!/bin/sh\nprintf "%s\\n" "$@" > "$TRACE"\nprintf "%s" "$CMAKE_ARGS" > "$CMAKE_TRACE"\n'
    )
    for tool in fake_bin.iterdir():
        tool.chmod(0o755)
    trace = tmp_path / "trace"
    cmake_trace = tmp_path / "cmake-trace"
    script = Path(__file__).resolve().parents[2] / "scripts/install-mac.sh"
    result = subprocess.run(
        [str(script), "--server-only"],
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "HOME": str(home),
            "TRACE": str(trace),
            "CMAKE_TRACE": str(cmake_trace),
            "CMAKE_ARGS": "-DUSER_OPTION=ON",
            "CHIRP_PORT": "1",  # never look at, or restart, the real server on 7821
            "PATH": str(fake_bin) + ":" + os.environ["PATH"],
        },
    )
    assert result.returncode == 0, result.stderr
    server = home / "Library/Application Support/Chirp/server"
    assert (server / "src/chirp_server/model_catalog.py").is_file()
    assert (server / "uv.lock").is_file()
    assert trace.read_text().splitlines() == [
        "sync",
        "--project",
        str(server),
        "--locked",
        "--no-dev",
        *(["--extra", "onnx", "--extra", "cleanup"] if machine == "x86_64" else []),
    ]
    assert cmake_trace.read_text() == "-DUSER_OPTION=ON" + (
        " -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF" if machine == "x86_64" else ""
    )
    assert config.read_text() == '[correction]\nmode = "off"\n'
    assert not (home / ".dotfiles").exists()


def test_reinstall_keeps_the_sensevoice_runtime_the_app_added(tmp_path):
    home = tmp_path / "home"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text(
        '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n'
    )
    (fake_bin / "uv").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TRACE"\n')
    python = home / "Library/Application Support/Chirp/server/.venv/bin/python"
    python.parent.mkdir(parents=True)
    python.write_text("#!/bin/sh\nexit 0\n")  # find_spec("sherpa_onnx") succeeds.
    for tool in [*fake_bin.iterdir(), python]:
        tool.chmod(0o755)
    trace = tmp_path / "trace"
    script = Path(__file__).resolve().parents[2] / "scripts/install-mac.sh"
    result = subprocess.run(
        [str(script), "--server-only"],
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "HOME": str(home),
            "TRACE": str(trace),
            "CHIRP_PORT": "1",
            "PATH": str(fake_bin) + ":" + os.environ["PATH"],
        },
    )
    assert result.returncode == 0, result.stderr
    assert trace.read_text().splitlines()[-2:] == ["--extra", "sensevoice"]
