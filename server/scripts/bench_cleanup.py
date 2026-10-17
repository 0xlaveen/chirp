"""Cached-only synthetic cleanup evaluation through the actual supervised helper."""

import argparse
import asyncio
import json
import os
import statistics
import time
from pathlib import Path

from chirp_server.cleanup_eval import load_cases, score
from chirp_server.cleanup_models import MODELS
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector

FIXTURES = Path(__file__).resolve().parents[1] / "tests/cleanup_eval.jsonl"


async def bench(model_id, repetitions, *, label="current"):
    cases = load_cases(FIXTURES)
    corrector = Corrector(CorrectionConfig(mode="managed", model=model_id, timeout=120))
    times = []
    profiles = {}
    totals = dict.fromkeys(("passed", "exact", "near", "must_keep", "must_drop", "unchanged"), 0)
    rejected = 0
    failures = []
    loads = []
    started = time.perf_counter()
    try:
        cold = await corrector.process(cases[0]["raw"])
        cold_ms = (time.perf_counter() - started) * 1000
        for _ in range(repetitions):
            for case in cases:
                started = time.perf_counter()
                profile = case.get("profile", "default")
                result = await corrector.process(case["raw"], profile, case.get("instructions", ""))
                times.append((time.perf_counter() - started) * 1000)
                loads.append(os.getloadavg()[0])
                measured = score(case, result.text)
                group = profiles.setdefault(
                    profile, {"runs": 0, "passed": 0, "rejected": 0, "times": []}
                )
                group["runs"] += 1
                group["passed"] += measured.passed
                group["rejected"] += result.error is not None
                group["times"].append(times[-1])
                rejected += result.error is not None
                for name in totals:
                    totals[name] += getattr(measured, name)
                if not measured.passed:
                    failures.append({"id": case["id"], "error": result.error})
        for group in profiles.values():
            timings = group.pop("times")
            group["median_ms"] = round(statistics.median(timings), 1)
            group["min_ms"] = round(min(timings), 1)
            group["max_ms"] = round(max(timings), 1)
        return {
            "profiles": profiles,
            "label": label,
            "model": model_id,
            "cold_ms": round(cold_ms, 1),
            "cold_error": cold.error,
            "warm_median_ms": round(statistics.median(times), 1),
            "warm_min_ms": round(min(times), 1),
            "warm_max_ms": round(max(times), 1),
            "runs": len(times),
            **totals,
            "rejected": rejected,
            "failures": failures,
            "loadavg_min_max": [round(min(loads), 1), round(max(loads), 1)],
        }
    finally:
        await corrector.close()


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=list(MODELS), action="append")
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--label", default="current")
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("repetitions must be positive")
    for model_id in args.model or MODELS:
        print(json.dumps(await bench(model_id, args.repetitions, label=args.label)), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
