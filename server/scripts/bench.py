"""Reproducible local benchmarks. Outputs only metrics, never recognized text or audio.

Run each engine in a separate process for independent peak RSS measurements.
"""

import argparse
import asyncio
import json
import platform
import resource
import statistics
import time
from pathlib import Path

import jiwer

from chirp_server.audio import decode_wav, samples
from chirp_server.engine import EngineWorker
from chirp_server.engine.mlx import ParakeetMLX
from chirp_server.engine.onnx import ParakeetONNX


async def benchmark(args):
    engine = (
        ParakeetONNX()
        if args.engine == "onnx"
        else ParakeetMLX(precision=args.precision, streaming=args.streaming)
    )
    worker = EngineWorker(engine)
    started = time.perf_counter()
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
            started = time.perf_counter()
            first = None
            arrivals, feed_costs = [], []
            previous = ""
            try:
                for offset in range(0, len(audio), 3200):
                    if not args.fast:
                        deadline = started + min(offset + 3200, len(audio)) / 16000
                        await asyncio.sleep(max(0, deadline - time.perf_counter()))
                    before = time.perf_counter()
                    partial = await worker.call(session.feed, audio[offset : offset + 3200])
                    feed_costs.append((time.perf_counter() - before) * 1000)
                    if partial and partial.text and partial.text != previous:
                        previous = partial.text
                        elapsed = (time.perf_counter() - started) * 1000
                        arrivals.append(elapsed)
                        if first is None:
                            first = elapsed
                stopped = time.perf_counter()
                await worker.call(session.finish)
                final_ms = (time.perf_counter() - stopped) * 1000
            finally:
                await worker.call(session.cancel)
            cadence = [b - a for a, b in zip(arrivals, arrivals[1:], strict=False)]
            clips.append(
                {
                    "target_seconds": entry["target_seconds"],
                    "audio_seconds": len(audio) / 16000,
                    "warm_decode_ms": statistics.median(durations) * 1000,
                    "rtfx": len(audio) / 16000 / statistics.median(durations),
                    "wer": wer,
                    "first_partial_ms": first,
                    "partial_count": len(arrivals),
                    "partial_cadence_ms": statistics.median(cadence) if cadence else None,
                    "feed_ms_median": statistics.median(feed_costs),
                    "stop_to_final_ms": final_ms,
                }
            )
            print(json.dumps({"completed_target_seconds": entry["target_seconds"]}), flush=True)
        result = {
            "engine": engine.name,
            "precision": args.precision,
            "streaming": args.streaming,
            "realtime": not args.fast,
            "load_and_warm_seconds": load,
            "peak_rss_mib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024**2,
            "platform": platform.platform(),
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
    parser.add_argument("--streaming", choices=["incremental", "rolling"], default="incremental")
    parser.add_argument(
        "--fixtures", type=Path, default=Path.home() / "Library/Caches/Chirp/fixtures"
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--fast", action="store_true", help="Compute-only; not real-time latency")
    asyncio.run(benchmark(parser.parse_args()))
