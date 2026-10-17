"""Cached cleanup comparison. Prints only metrics; input and output stay in memory."""

import argparse
import asyncio
import json
import os
import statistics
import time

from chirp_server.cleanup_models import MODELS
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector

# Synthetic dictation only. Never accept user transcript files or log model output.
SAMPLES = [
    (
        "um please send the project schedule tomorrow "
        "we need to review the API changes before lunch",
        ("schedule", "API"),
    ),
    (
        "please book the review for monday no wait make that tuesday "
        "send the kubernetes notes before the meeting",
        ("Tuesday", "Kubernetes"),
    ),
    (
        "can you explain how the database migration works "
        "please include the postgres rollback steps",
        ("?", "Postgres"),
    ),
]


async def bench(model_id, repetitions):
    corrector = Corrector(CorrectionConfig(mode="managed", model=model_id, timeout=120))
    times = []
    accepted = 0
    checks = 0
    repairs = 0
    questions = 0
    started = time.perf_counter()
    try:
        cold = await corrector.process(SAMPLES[0][0])
        cold_ms = (time.perf_counter() - started) * 1000
        for _ in range(repetitions):
            for raw, keywords in SAMPLES:
                started = time.perf_counter()
                result = await corrector.process(raw)
                times.append((time.perf_counter() - started) * 1000)
                accepted += result.error is None
                if "no wait" in raw:
                    repairs += (
                        result.error is None
                        and "tuesday" in result.text.lower()
                        and "monday" not in result.text.lower()
                        and "wait" not in result.text.lower()
                    )
                if raw.startswith("can you"):
                    questions += (
                        result.error is None
                        and result.text.lower().startswith("can you explain")
                        and "rollback" in result.text.lower()
                        and "?" in result.text
                    )
                checks += result.error is None and all(
                    k.lower() in result.text.lower() for k in keywords
                )
        return {
            "model": model_id,
            "cold_ms": round(cold_ms, 1),
            "cold_error": cold.error,
            "warm_median_ms": round(statistics.median(times), 1),
            "warm_min_ms": round(min(times), 1),
            "warm_max_ms": round(max(times), 1),
            "accepted": accepted,
            "keyword_checks": checks,
            "runs": len(times),
            "self_correction_checks": repairs,
            "question_checks": questions,
            "loadavg": list(os.getloadavg()),
        }
    finally:
        await corrector.close()


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=list(MODELS), action="append")
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args()
    for model_id in args.model or MODELS:
        print(json.dumps(await bench(model_id, args.repetitions)), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
