"""Exercise standalone server installation with a fake uv and isolated HOME."""

import os
import subprocess
from pathlib import Path


def test_server_install_requires_no_dotfiles_and_preserves_configuration(tmp_path):
    home = tmp_path / "home with spaces"
    config = home / ".config/chirp/server.toml"
    config.parent.mkdir(parents=True)
    config.write_text('[correction]\nmode = "off"\n')
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text(
        '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n'
    )
    (fake_bin / "uv").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TRACE"\n')
    for tool in fake_bin.iterdir():
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
    ]
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
            "PATH": str(fake_bin) + ":" + os.environ["PATH"],
        },
    )
    assert result.returncode == 0, result.stderr
    assert trace.read_text().splitlines()[-2:] == ["--extra", "sensevoice"]
