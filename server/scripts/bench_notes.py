"""Operator-run Notes structuring benchmark through the real supervised helper.

Structures the synthetic transcripts in tests/notes_eval.jsonl (about 800, 1600, 2400 and
4000 characters) with a cached managed model and reports latency, output tokens and how
many outputs pass the guards. Not run in CI: it needs the model weights.
"""

import argparse
import asyncio
import json
import math
import statistics
import time
from collections import Counter
from pathlib import Path

from chirp_server import notes
from chirp_server.cleanup_models import DEFAULT_MODEL, MODELS, discover
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector

FIXTURES = Path(__file__).resolve().parents[1] / "tests/notes_eval.jsonl"


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1)]


def token_counter(model_id):
    """Exact output tokens from the model's own tokenizer; a chars/3.5 estimate otherwise."""
    try:
        from transformers import AutoTokenizer

        tokenizer = AutoTokenizer.from_pretrained(str(discover(model_id)), local_files_only=True)
        return (lambda text: len(tokenizer.encode(text, add_special_tokens=False))), "tokenizer"
    except Exception:
        return (lambda text: round(len(text) / 3.5)), "estimate (chars / 3.5)"


def write_dump(path, outputs):
    Path(path).write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in outputs))


def summary(rows):
    latency = [row["ms"] for row in rows]
    tokens = [row["tokens"] for row in rows]
    passed = sum(row["reason"] is None for row in rows)
    return {
        "runs": len(rows),
        "p50_ms": round(statistics.median(latency)),
        "p95_ms": round(percentile(latency, 0.95)),
        "max_ms": round(max(latency)),
        "tokens_p50": round(statistics.median(tokens)),
        "tokens_p95": round(percentile(tokens, 0.95)),
        "tokens_max": max(tokens),
        "pass": passed,
        "fail": len(rows) - passed,
        "pass_rate": round(passed / len(rows), 3),
    }


async def bench(model_id, repetitions, dump):
    cases = [json.loads(line) for line in FIXTURES.read_text().splitlines() if line.strip()]
    config = CorrectionConfig(mode="managed", model=model_id, timeout=120, structure_timeout=120)
    corrector = Corrector(config)
    count, counted = token_counter(model_id)
    rows, outputs = [], []
    try:
        started = time.perf_counter()
        await corrector.complete("Reply with OK.", "Notes JSON: {}", 8, priority="structure")
        cold_ms = (time.perf_counter() - started) * 1000
        for _ in range(repetitions):
            for case in cases:
                transcript, outline = case["transcript"], case.get("outline", [])
                started = time.perf_counter()
                text, finish = await corrector.complete(
                    notes.notes_system_prompt(),
                    notes.notes_user_message(outline, transcript),
                    notes.NOTES_MAX_TOKENS,
                    priority="structure",
                )
                ms = (time.perf_counter() - started) * 1000
                reason = notes.rejection_reason(transcript, text, finish)
                rows.append(
                    {
                        "id": case["id"],
                        "chars": len(transcript),
                        "ms": ms,
                        "tokens": count(text),
                        "finish": finish,
                        "reason": reason,
                    }
                )
                outputs.append({"id": case["id"], "reason": reason, "markdown": text})
    finally:
        await corrector.close()
    if dump:
        write_dump(dump, outputs)
    # Group by the fixture's nominal size (the id suffix: launch-800, budget-2400, ...).
    by_size = {}
    for row in rows:
        by_size.setdefault(int(row["id"].rsplit("-", 1)[1]), []).append(row)
    by_size = {size: summary(group) for size, group in sorted(by_size.items())}
    return {
        "model": model_id,
        "token_count": counted,
        "novel_threshold": notes.NOVEL_THRESHOLD,
        "max_tokens": notes.NOTES_MAX_TOKENS,
        "cold_ms": round(cold_ms),
        "overall": summary(rows),
        "by_chars": by_size,
        "rejected_by": dict(Counter(row["reason"] for row in rows if row["reason"])),
        "failures": [{"id": row["id"], "reason": row["reason"]} for row in rows if row["reason"]],
    }


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=list(MODELS), default=DEFAULT_MODEL)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--dump", help="write every output (synthetic text) to this JSONL file")
    arguments = parser.parse_args()
    try:
        discover(arguments.model)
    except ValueError:
        raise SystemExit(
            "cleanup weights missing; explicitly run `model fetch --cleanup`"
        ) from None
    print(json.dumps(await bench(arguments.model, arguments.repetitions, arguments.dump), indent=2))


if __name__ == "__main__":
    asyncio.run(main())
