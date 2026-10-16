"""Paired, back-to-back short-utterance finalization measurements, one loaded model."""

import asyncio
import json
import os
import time
from pathlib import Path

import jiwer
from bench import measure_stream

from chirp_server.audio import decode_wav, samples
from chirp_server.engine import EngineWorker
from chirp_server.engine.mlx import ParakeetMLX


async def run():
    root = Path.home() / "Library/Caches/Chirp"
    engine = ParakeetMLX()
    worker = EngineWorker(engine)
    started = time.perf_counter()
    await worker.start()
    startup = time.perf_counter() - started
    rows = []
    normalize = jiwer.Compose([jiwer.ToLowerCase(), jiwer.RemovePunctuation(), jiwer.Strip()])
    try:
        for dataset in ["fixtures", "fixtures-paused"]:
            directory = root / dataset
            for entry in json.loads((directory / "manifest.json").read_text())[:2]:
                audio = samples(decode_wav((directory / entry["file"]).read_bytes()))
                for repeat in range(2):
                    # Alternate order to limit thermal/load ordering effects.
                    modes = ["full", "segments"] if repeat == 0 else ["segments", "full"]
                    for mode in modes:
                        engine.finalization = mode
                        session = await worker.call(engine.open_stream)
                        load = os.getloadavg()
                        metrics = await measure_stream(
                            worker, session, audio, False, normalize, entry["reference"]
                        )
                        rows.append(
                            {
                                "dataset": dataset,
                                "target_seconds": entry["target_seconds"],
                                "mode": mode,
                                "repeat": repeat,
                                "load_average": load,
                                **metrics,
                            }
                        )
                        print(
                            json.dumps(
                                {
                                    k: rows[-1][k]
                                    for k in [
                                        "dataset",
                                        "target_seconds",
                                        "mode",
                                        "stop_to_final_ms",
                                        "stream_final_wer",
                                        "segments",
                                    ]
                                }
                            ),
                            flush=True,
                        )
        result = {"load_and_decode_warm_seconds": startup, "paired": rows}
        (root / "bench-paired-finalization.json").write_text(json.dumps(result, indent=2))
    finally:
        await worker.close()


if __name__ == "__main__":
    asyncio.run(run())
