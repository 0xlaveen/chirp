"""Operator-run Live Notes benchmark through the real supervised helper.

`--set clean` structures the written-style transcripts in tests/notes_eval.jsonl (about 800,
1600, 2400 and 4000 characters). `--set messy` uses tests/notes_messy_eval.jsonl, invented
filler-heavy speech (600-2100 characters), and also runs Live Notes segment correction on
each transcript cut into segment-sized pieces and on the whole transcript (the old 90 s
segment), with the `live_notes` style and, for comparison, `default`. Every run also checks
that the guards reject each case in tests/notes_negatives.jsonl. Reports latency, output
tokens and guard pass rates. Not run in CI: it needs the model weights.
"""

import argparse
import asyncio
import json
import math
import re
import statistics
import time
from collections import Counter
from pathlib import Path

from chirp_server import notes
from chirp_server.cleanup_models import DEFAULT_MODEL, MODELS, discover
from chirp_server.config import CorrectionConfig
from chirp_server.correction import HESITATIONS, WORD, Corrector, rejected
from chirp_server.profiles import LIVE_NOTES, LIVE_NOTES_ID

TESTS = Path(__file__).resolve().parents[1] / "tests"
SETS = {"clean": TESTS / "notes_eval.jsonl", "messy": TESTS / "notes_messy_eval.jsonl"}
NEGATIVES = TESTS / "notes_negatives.jsonl"
# About 15 characters per second of speech: a 45 s segment (the client's maximum).
SEGMENT_CHARS = 675


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


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def segments_of(transcript, limit=SEGMENT_CHARS):
    """Sentence-aligned pieces of at most `limit` characters, like pause-cut segments."""
    pieces, current = [], ""
    for sentence in re.split(r"(?<=[.!?])\s+", transcript):
        if current and len(current) + 1 + len(sentence) > limit:
            pieces.append(current)
            current = sentence
        else:
            current = f"{current} {sentence}".strip()
    return pieces + [current] if current else pieces


def negatives():
    """Every invented bad output must be rejected; deterministic, no model."""
    rows = []
    for case in read_jsonl(NEGATIVES):
        if case["kind"] == "structure":
            reason = notes.rejection_reason(case["transcript"], case["output"], "stop")
        else:
            reason = (
                "rejected"
                if rejected(case["transcript"], case["output"], "stop", LIVE_NOTES)
                else None
            )
        rows.append({"id": case["id"], "kind": case["kind"], "rejected_by": reason})
    missed = [row["id"] for row in rows if row["rejected_by"] is None]
    return {
        "cases": len(rows),
        "rejected": len(rows) - len(missed),
        "missed": missed,
        "by_kind": dict(Counter(row["kind"] for row in rows)),
        "structure_rejected_by": dict(
            Counter(row["rejected_by"] for row in rows if row["kind"] == "structure")
        ),
    }


def hesitations(text):
    return sum(1 for word in WORD.findall(text) if word.casefold() in HESITATIONS)


def correction_summary(rows):
    latency = [row["ms"] for row in rows]
    passed = [row for row in rows if row["error"] is None]
    return {
        "runs": len(rows),
        "chars_p50": round(statistics.median(row["chars"] for row in rows)),
        "chars_max": max(row["chars"] for row in rows),
        "p50_ms": round(statistics.median(latency)),
        "p95_ms": round(percentile(latency, 0.95)),
        "max_ms": round(max(latency)),
        "pass": len(passed),
        "pass_rate": round(len(passed) / len(rows), 3),
        "errors": dict(Counter(row["error"] for row in rows if row["error"])),
        # Hesitation fillers (um, uh, ...) left in accepted outputs, of those in their input.
        "hesitations_left": f"{sum(row['left'] for row in passed)}/"
        f"{sum(row['spoken'] for row in passed)}",
    }


async def bench_correction(corrector, cases):
    rows, outputs = {}, []
    for case in cases:
        pieces = [("segment", piece) for piece in segments_of(case["transcript"])]
        for size, raw in [*pieces, ("whole", case["transcript"])]:
            for profile in (LIVE_NOTES_ID, "default"):
                started = time.perf_counter()
                result = await corrector.process(raw, profile)
                ms = (time.perf_counter() - started) * 1000
                rows.setdefault(f"{profile}/{size}", []).append(
                    {
                        "chars": len(raw),
                        "ms": ms,
                        "error": result.error,
                        "spoken": hesitations(raw),
                        "left": hesitations(result.text),
                    }
                )
                outputs.append(
                    {"id": case["id"], "profile": profile, "size": size, "raw": raw}
                    | {"error": result.error, "text": result.text}
                )
    return {key: correction_summary(group) for key, group in rows.items()}, outputs


async def bench(model_id, repetitions, dump, fixtures):
    cases = read_jsonl(SETS[fixtures])
    config = CorrectionConfig(
        mode="managed", model=model_id, timeout=120, notes_timeout=120, structure_timeout=120
    )
    corrector = Corrector(config)
    count, counted = token_counter(model_id)
    rows, outputs = [], []
    correction = None
    try:
        started = time.perf_counter()
        await corrector.complete("Reply with OK.", "Notes JSON: {}", 8, priority="structure")
        cold_ms = (time.perf_counter() - started) * 1000
        if fixtures == "messy":
            correction, corrected = await bench_correction(corrector, cases)
            outputs.extend(corrected)
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
    # Group by size: the clean set's id suffix (launch-800, ...), else 600-character bands.
    by_size = {}
    for row in rows:
        suffix = row["id"].rsplit("-", 1)[1]
        size = int(suffix) if suffix.isdigit() else 600 * math.ceil(row["chars"] / 600)
        by_size.setdefault(size, []).append(row)
    by_size = {size: summary(group) for size, group in sorted(by_size.items())}
    result = {
        "model": model_id,
        "set": fixtures,
        "token_count": counted,
        "overlap_floor": notes.OVERLAP_FLOOR,
        "max_tokens": notes.NOTES_MAX_TOKENS,
        "cold_ms": round(cold_ms),
        "overall": summary(rows),
        "by_chars": by_size,
        "rejected_by": dict(Counter(row["reason"] for row in rows if row["reason"])),
        "failures": [{"id": row["id"], "reason": row["reason"]} for row in rows if row["reason"]],
        "negatives": negatives(),
    }
    if correction is not None:
        result["correction"] = correction
    return result


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=list(MODELS), default=DEFAULT_MODEL)
    parser.add_argument("--set", choices=list(SETS), default="clean", dest="fixtures")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--dump", help="write every output (synthetic text) to this JSONL file")
    arguments = parser.parse_args()
    try:
        discover(arguments.model)
    except ValueError:
        raise SystemExit(
            "cleanup weights missing; explicitly run `model fetch --cleanup`"
        ) from None
    result = await bench(arguments.model, arguments.repetitions, arguments.dump, arguments.fixtures)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
