"""Reproducible local benchmarks. Outputs only metrics, never recognized text or audio.

Run each engine in a separate process for independent peak RSS measurements.
"""

import argparse
import asyncio
import json
import os
import platform
import resource
import statistics
import subprocess
import sys
import time
from pathlib import Path

import jiwer

from chirp_server.audio import decode_wav, samples
from chirp_server.engine import EngineWorker
from chirp_server.engine.mlx import ParakeetMLX
from chirp_server.engine.onnx import ParakeetONNX


async def measure_stream(worker, session, audio, fast, normalize, reference):
    started = time.perf_counter()
    first = None
    arrivals, feed_costs = [], []
    previous = ""
    available = 0
    produced = False
    changed = asyncio.Event()
    stable_characters = 0

    async def consume():
        nonlocal previous, first, stable_characters
        cursor = 0
        while True:
            await changed.wait()
            changed.clear()
            end = min(available, cursor + 32000)
            if end > cursor:
                before = time.perf_counter()
                partial = await worker.call(session.feed, audio[cursor:end])
                cursor = end
                feed_costs.append((time.perf_counter() - before) * 1000)
                if partial:
                    stable_characters = max(stable_characters, len(partial.stable))
                if partial and partial.text and partial.text != previous:
                    previous = partial.text
                    elapsed = (time.perf_counter() - started) * 1000
                    arrivals.append(elapsed)
                    if first is None:
                        first = elapsed
            if produced and cursor == len(audio):
                return
            if available - cursor >= 3200 or (produced and available > cursor):
                changed.set()

    consumer = asyncio.create_task(consume())
    try:
        for offset in range(0, len(audio), 800):
            if not fast:
                deadline = started + min(offset + 800, len(audio)) / 16000
                await asyncio.sleep(max(0, deadline - time.perf_counter()))
            available = min(offset + 800, len(audio))
            if available % 3200 == 0:
                changed.set()
        stopped = time.perf_counter()
        produced = True
        changed.set()
        await consumer
        candidate_text, candidate_ms = None, None
        snapshot = getattr(session, "snapshot", None)
        if snapshot:
            snapshot_started = time.perf_counter()
            candidate_text = await worker.call(snapshot)
            candidate_ms = (time.perf_counter() - snapshot_started) * 1000
        final_text = await worker.call(session.finish)
        final_ms = (time.perf_counter() - stopped) * 1000
    finally:
        consumer.cancel()
        await worker.call(session.cancel)
    cadence = [b - a for a, b in zip(arrivals, arrivals[1:], strict=False)]
    return {
        "context_final_wer": jiwer.wer(normalize(reference), normalize(candidate_text))
        if candidate_text is not None
        else None,
        "context_snapshot_ms": candidate_ms,
        "stream_final_wer": jiwer.wer(normalize(reference), normalize(final_text)),
        "last_partial_wer": jiwer.wer(normalize(reference), normalize(previous)),
        "stable_characters": stable_characters,
        "segments": getattr(session, "segments", 0),
        "feed_count": len(feed_costs),
        "stream_wall_seconds": time.perf_counter() - started,
        "first_partial_ms": first,
        "partial_count": len(arrivals),
        "partial_cadence_ms": statistics.median(cadence) if cadence else None,
        "feed_ms_median": statistics.median(feed_costs),
        "stop_to_final_ms": final_ms,
    }


async def benchmark(args):
    engine = (
        ParakeetONNX(finalization=args.finalization)
        if args.engine == "onnx"
        else ParakeetMLX(
            precision=args.precision, streaming=args.streaming, finalization=args.finalization
        )
    )
    worker = EngineWorker(engine)
    started = time.perf_counter()
    load_begin = os.getloadavg()
    try:
        await worker.start()
        load = time.perf_counter() - started
        clips = []
        for entry in json.loads((args.fixtures / "manifest.json").read_text()):
            audio = samples(decode_wav((args.fixtures / entry["file"]).read_bytes()))
            durations = []
            text = ""
            for _ in range(args.repeats):
                started = time.perf_counter()
                text = await worker.call(engine.transcribe, audio)
                durations.append(time.perf_counter() - started)
            normalize = jiwer.Compose(
                [
                    jiwer.ToLowerCase(),
                    jiwer.RemovePunctuation(),
                    jiwer.RemoveMultipleSpaces(),
                    jiwer.Strip(),
                ]
            )
            wer = jiwer.wer(normalize(entry["reference"]), normalize(text))
            session = await worker.call(engine.open_stream)
            stream_metrics = await measure_stream(
                worker, session, audio, args.fast, normalize, entry["reference"]
            )
            clips.append(
                {
                    "target_seconds": entry["target_seconds"],
                    "audio_seconds": len(audio) / 16000,
                    "warm_decode_ms": statistics.median(durations) * 1000,
                    "rtfx": len(audio) / 16000 / statistics.median(durations),
                    "wer": wer,
                    **stream_metrics,
                }
            )
            print(json.dumps({"completed_target_seconds": entry["target_seconds"]}), flush=True)
        result = {
            "engine": engine.name,
            "precision": args.precision,
            "streaming": args.streaming,
            "finalization": args.finalization,
            "coalesced": True,
            "realtime": not args.fast,
            "load_and_warm_seconds": load,
            "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2,
            "platform": platform.platform(),
            "load_average_begin": load_begin,
            "load_average_end": os.getloadavg(),
            "logical_cpus": os.cpu_count(),
            "clips": clips,
        }
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2))
        print(json.dumps(result, indent=2))
    finally:
        await worker.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", choices=["mlx", "onnx"], default="mlx")
    parser.add_argument(
        "--precision", choices=["float32", "float16", "bfloat16"], default="float32"
    )
    parser.add_argument("--streaming", choices=["incremental", "rolling"], default="rolling")
    parser.add_argument(
        "--fixtures", type=Path, default=Path.home() / "Library/Caches/Chirp/fixtures"
    )
    parser.add_argument("--finalization", choices=["full", "segments"], default="full")
    parser.add_argument(
        "--with-fluidaudio",
        action="store_true",
        help="Explicitly download/build FluidAudio and acquire v2 CoreML models",
    )
    parser.add_argument(
        "--with-apple",
        action="store_true",
        help="Use already installed Apple speech assets; never request permissions",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--fast", action="store_true", help="Compute-only; not real-time latency")
    args = parser.parse_args()
    asyncio.run(benchmark(args))
    if args.with_fluidaudio or args.with_apple:
        command = [sys.executable, str(Path(__file__).with_name("run_swift_benches.py"))]
        if args.with_fluidaudio:
            command.append("--with-fluidaudio")
        if args.with_apple:
            command.append("--with-apple")
        subprocess.run(command, check=True)
