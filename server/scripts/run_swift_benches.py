"""Candidate runners capture library output in memory; persist only numeric/status JSON."""

import argparse
import json
import os
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--with-fluidaudio", action="store_true")
parser.add_argument("--with-apple", action="store_true")
args = parser.parse_args()
if not (args.with_fluidaudio or args.with_apple):
    print("Alternate engines skipped; pass --with-fluidaudio or --with-apple explicitly")
    raise SystemExit(0)

root = Path.home() / "Library/Caches/Chirp"
source = root / "FluidAudio-0.17.7"
script = Path(__file__).resolve().parent
env = {**os.environ, "OS_ACTIVITY_MODE": "disable"}
if args.with_fluidaudio:
    if not source.exists():
        subprocess.run(["sh", str(script / "prepare_fluid.sh")], check=True)
    manifest_path = source / "Package@swift-6.2.swift"
    manifest = manifest_path.read_text()
    if 'name: "chirp-fluid-bench"' not in manifest:
        manifest = manifest.replace(
            ".library(",
            '.executable(name: "chirp-fluid-bench", targets: ["ChirpFluidBench"]),\n'
            "        .library(",
            1,
        )
        manifest = manifest.replace(
            ".target(",
            '.executableTarget(name: "ChirpFluidBench", '
            'dependencies: ["FluidAudio"], path: "ChirpFluidBench"),\n'
            "        .target(",
            1,
        )
        manifest_path.write_text(manifest)
    target = source / "ChirpFluidBench"
    target.mkdir(exist_ok=True)
    (target / "Bench.swift").write_text((script / "fluid_bench.swift").read_text())
    subprocess.run(
        [
            "swift",
            "build",
            "--package-path",
            str(source),
            "--disable-default-traits",
            "-c",
            "release",
            "--product",
            "chirp-fluid-bench",
        ],
        check=True,
    )
    env = {**os.environ, "OS_ACTIVITY_MODE": "disable"}
    completed = subprocess.run(
        [
            str(source / ".build/release/chirp-fluid-bench"),
            str(root / "fixtures"),
            "--download-models",
        ],
        capture_output=True,
        text=True,
        timeout=300,
        env=env,
        check=True,
    )
    for line in completed.stdout.splitlines():
        if line.startswith('{"'):
            result = json.loads(line)
            if "engine" in result or "status" in result:
                (root / "bench-fluid.json").write_text(json.dumps(result, indent=2))
                print(json.dumps(result))
if args.with_apple:
    subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            "-O",
            str(script / "apple_bench.swift"),
            "-o",
            str(root / "apple-bench"),
        ],
        check=True,
    )
    apple = []
    for entry in json.loads((root / "fixtures/manifest.json").read_text()):
        completed = subprocess.run(
            [str(root / "apple-bench"), str(root / "fixtures" / entry["file"])],
            capture_output=True,
            text=True,
            timeout=30,
            env=env,
            check=True,
        )
        result = json.loads(completed.stdout)
        apple.append(result)
    (root / "bench-apple.json").write_text(json.dumps(apple, indent=2))
    print(json.dumps({"apple": apple}))
