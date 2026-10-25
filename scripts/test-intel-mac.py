#!/usr/bin/env python3
"""Intel/Rosetta acceptance: real ONNX server, synthetic speech, and both Mac selftests.

Pass an x86_64 Python environment and Mac executable. Models must already be downloaded.
Everything writable belongs to a fresh temporary home; the installed server is never contacted.
"""

import argparse
import json
import os
import platform
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", type=Path, required=True)
    parser.add_argument("--mac", type=Path, required=True)
    parser.add_argument(
        "--model-dir", type=Path, default=Path.home() / ".koi/voice-models/parakeet-onnx"
    )
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("this acceptance check needs macOS (Intel or Apple Silicon with Rosetta)")
    python, mac, model = (p.absolute() for p in (args.python, args.mac, args.model_dir))
    subprocess.run(
        [
            "arch",
            "-x86_64",
            str(python),
            "-c",
            "import platform; assert platform.machine() == 'x86_64'",
        ],
        check=True,
    )
    work = Path(tempfile.mkdtemp(prefix="chirp-intel-", dir="/tmp"))
    print(f"Acceptance evidence: {work}", flush=True)
    home = work / "home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_CACHE_HOME": str(home / ".cache"),
    }
    env.pop("CHIRP_TOKEN", None)
    subprocess.run(
        [
            "say",
            "-o",
            str(work / "speech.aiff"),
            "Schedule the team review for Tuesday morning and invite the whole design group.",
        ],
        check=True,
    )
    wav = work / "speech.wav"
    subprocess.run(
        [
            "ffmpeg",
            "-loglevel",
            "error",
            "-i",
            str(work / "speech.aiff"),
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(wav),
        ],
        check=True,
    )
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    assert port != 7821
    base = f"http://127.0.0.1:{port}"
    log = work / "server.log"
    # No --engine override: this also verifies the Intel default.
    command = [
        "arch",
        "-x86_64",
        str(python),
        "-m",
        "chirp_server",
        "--model-dir",
        str(model),
        "--port",
        str(port),
    ]
    started = time.monotonic()
    with log.open("wb") as sink:
        server = subprocess.Popen(command, env=env, stdout=sink, stderr=subprocess.STDOUT)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    token_path = home / ".config/chirp/token"
    try:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            assert server.poll() is None, "server exited; inspect the private acceptance log"
            if token_path.is_file():
                token = token_path.read_text().strip()
                request = urllib.request.Request(
                    base + "/v1/health", headers={"Authorization": f"Bearer {token}"}
                )
                try:
                    with opener.open(request, timeout=2) as response:
                        health = json.load(response)
                    if health.get("ready"):
                        break
                except (OSError, urllib.error.URLError):
                    pass
            time.sleep(0.25)
        else:
            raise RuntimeError("server did not become ready")
        startup_ms = (time.monotonic() - started) * 1000
        assert health["engine"].startswith("parakeet-onnx")
        with wave.open(str(wav)) as clip:
            audio_seconds = clip.getnframes() / clip.getframerate()
        decodes = []
        for _ in range(3):
            request = urllib.request.Request(
                base + "/v1/transcribe",
                data=wav.read_bytes(),
                headers={"Authorization": f"Bearer {token}", "Content-Type": "audio/wav"},
            )
            started = time.monotonic()
            with opener.open(request, timeout=120) as response:
                result = json.load(response)
            decodes.append(round((time.monotonic() - started) * 1000))
            assert "tuesday" in result["text"].lower()
        for mode in ("--selftest", "--notes-selftest"):
            subprocess.run(
                [
                    "arch",
                    "-x86_64",
                    str(mac),
                    mode,
                    str(wav),
                    "--url",
                    base,
                    "--token-file",
                    str(token_path),
                    "--fast",
                    "--expect",
                    "tuesday",
                ],
                env=env,
                check=True,
                timeout=180,
            )
        assert not any(word in log.read_text().lower() for word in ("tuesday", "design group"))
        evidence = {
            "architecture": "x86_64",
            "rosetta": platform.machine() == "arm64",
            "engine": health["engine"],
            "audio_seconds": round(audio_seconds, 2),
            "startup_ms": round(startup_ms),
            "http_transcribe_ms": decodes,
            "app_selftest": "pass",
            "app_notes_selftest": "pass",
        }
        (work / "bench.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps(evidence, indent=2))
        print("INTEL MAC ACCEPTANCE: PASS")
    finally:
        server.terminate()
        try:
            server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()


if __name__ == "__main__":
    main()
