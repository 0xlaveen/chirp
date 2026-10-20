"""Operator-run Live Notes benchmark through the real supervised helper.

`--set clean` structures the written-style transcripts in tests/notes_eval.jsonl (about 800,
1600, 2400 and 4000 characters). `--set messy` uses tests/notes_messy_eval.jsonl, invented
filler-heavy speech (600-2100 characters), and also runs Live Notes segment correction on
each transcript cut into segment-sized pieces and on the whole transcript (the old 90 s
segment), with the `live_notes` style and, for comparison, `default`. `--set labelled` uses
tests/notes_labelled_eval.jsonl, invented meetings with speaker labels (`Person 2: ...`).
Every run also checks
that the guards reject each case in tests/notes_negatives.jsonl. Reports latency, output
tokens and guard pass rates. Not run in CI: it needs the model weights.

`--mode reorganize` instead sends each document in tests/notes_reorganize_eval.jsonl (invented
messy notes of about 1000, 2000, 3000 and 3500 characters) through the reorganize prompt and
guards, checks tests/notes_reorganize_negatives.jsonl, and measures a dictation correction and a
Live Notes segment correction that arrive while a reorganize is running. `--mode both` runs both
and prints `{"structure": ..., "reorganize": ...}`.
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
SETS = {
    "clean": TESTS / "notes_eval.jsonl",
    "messy": TESTS / "notes_messy_eval.jsonl",
    "talk": TESTS / "notes_talk_eval.jsonl",
    # Mac Live Notes speaker labels (#18): invented meetings, one `Person N:` or name per line.
    "labelled": TESTS / "notes_labelled_eval.jsonl",
}
NEGATIVES = TESTS / "notes_negatives.jsonl"
REORGANIZE_SET = TESTS / "notes_reorganize_eval.jsonl"
REORGANIZE_NEGATIVES = TESTS / "notes_reorganize_negatives.jsonl"
CONTEXT = 4096
# Invented dictation and Live Notes segment sent while a reorganize runs (priority check).
DICTATION = "um can you send the updated schedule to the team before friday"
SEGMENT = (
    "Okay so, um, the next thing is the venue. We, uh, we looked at two halls and the bigger one "
    "is like twelve hundred for the day, which is, yeah, it's over budget, so we're not booking it."
)
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


async def corrected_windows(corrector, cases):
    """`--set talk`: each ASR segment through `live_notes` clean-up first (raw text when it
    fails closed, as the app keeps it), then the window joined with newlines, as the app sends."""
    windows, errors = [], Counter()
    for case in cases:
        texts = []
        for raw in case["segments"]:
            result = await corrector.process(raw, LIVE_NOTES_ID)
            errors[result.error or "corrected"] += 1
            texts.append(result.text if result.corrected else raw)
        windows.append(case | {"transcript": "\n".join(texts)})
    return windows, dict(errors)


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
        if fixtures == "talk":
            cases, segment_errors = await corrected_windows(corrector, cases)
            correction = {"live_notes_segments": segment_errors}
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
                reason = notes.rejection_reason(transcript, text, finish, outline)
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
                if fixtures == "talk":
                    outputs[-1]["transcript"] = transcript
    finally:
        await corrector.close()
    if dump:
        write_dump(dump, outputs)
    # Group by size: the clean set's id suffix (launch-800, ...), else 600-character bands.
    by_size = {}
    for row in rows:
        suffix = row["id"].rsplit("-", 1)[1]
        sized = suffix.isdigit() and int(suffix) >= 100
        size = int(suffix) if sized else 600 * math.ceil(row["chars"] / 600)
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


def prompt_counter(model_id):
    """Prompt tokens as the helper counts them (chat template); None without a tokenizer."""
    try:
        from transformers import AutoTokenizer

        tokenizer = AutoTokenizer.from_pretrained(str(discover(model_id)), local_files_only=True)
    except Exception:
        return None

    def count(system, user):
        tokens = tokenizer.apply_chat_template(
            [{"role": "system", "content": system}, {"role": "user", "content": user}],
            tokenize=True,
            add_generation_prompt=True,
            enable_thinking=False,
        )
        # transformers returns a BatchEncoding; the helper's MLX wrapper returns the ids.
        return len(tokens["input_ids"] if hasattr(tokens, "keys") else tokens)

    return count


SECTION = re.compile(r"^#{1,3} \S")


def client_scope(text, limit):
    """(scope, outline) as the Mac sends it: the longest suffix of whole sections within `limit`
    characters, and the headings before it (newest 24) as the outline; None if none fits."""
    lines = text.split("\n")
    starts = [0] + [
        sum(len(line) + 1 for line in lines[:i])
        for i, line in enumerate(lines)
        if i and SECTION.match(line)
    ]
    for start in starts:
        if len(text) - start <= limit:
            before = text[:start].split("\n")
            headings = [line.lstrip("#").strip() for line in before if SECTION.match(line)]
            return text[start:].strip(), headings[-24:]
    return None


def reorganize_negatives():
    rows = [
        {
            "id": case["id"],
            "why": case["why"],
            "rejected_by": notes.reorganize_rejection_reason(case["notes"], case["output"], "stop"),
        }
        for case in read_jsonl(REORGANIZE_NEGATIVES)
    ]
    return {
        "cases": len(rows),
        "rejected": sum(row["rejected_by"] is not None for row in rows),
        "missed": [row["id"] for row in rows if row["rejected_by"] is None],
        "rejected_by": dict(Counter(row["rejected_by"] for row in rows)),
        "cases_by_why": {row["id"]: [row["why"], row["rejected_by"]] for row in rows},
    }


def kept(markdown, case):
    """(every expected keyword survives, every expected task survives with its state)."""
    lowered = markdown.lower()
    lines = lowered.splitlines()
    # A client scope holds only the trailing sections: check what it actually sent.
    source = case["notes"].lower()
    keywords = all(
        word.lower() in lowered for word in case["expect_keywords"] if word.lower() in source
    )
    tasks = all(
        any(
            ("- [x] " if task["checked"] else "- [ ] ") in line
            and all(word.lower() in line for word in task["keywords"])
            for line in lines
        )
        for task in case["expect_tasks"]
        if any(
            ("- [x] " if task["checked"] else "- [ ] ") in line
            and all(word.lower() in line for word in task["keywords"])
            for line in source.splitlines()
        )
    )
    return keywords, tasks


def reorganize_summary(rows):
    result = summary(rows)
    result["finish"] = dict(Counter(str(row["finish"]) for row in rows))
    result["changed"] = sum(row["changed"] for row in rows)
    result["rejected_by"] = dict(Counter(row["reason"] for row in rows if row["reason"]))
    result["chars_max"] = max(row["chars"] for row in rows)
    if all(row["prompt_tokens"] is not None for row in rows):
        result["prompt_tokens_max"] = max(row["prompt_tokens"] for row in rows)
        result["context_max"] = result["prompt_tokens_max"] + notes.REORGANIZE_MAX_TOKENS
    accepted = [row for row in rows if row["reason"] is None]
    result["keywords_kept"] = f"{sum(row['keywords'] for row in accepted)}/{len(accepted)}"
    result["tasks_kept"] = f"{sum(row['tasks'] for row in accepted)}/{len(accepted)}"
    return result


async def reorganize_once(corrector, case):
    text, outline = case["notes"], case.get("outline", [])
    started = time.perf_counter()
    markdown, finish = await corrector.complete(
        notes.reorganize_system_prompt(),
        notes.reorganize_user_message(outline, text),
        notes.REORGANIZE_MAX_TOKENS,
        priority="reorganize",
        timeout=120,
    )
    ms = (time.perf_counter() - started) * 1000
    markdown = notes.clean_output(markdown)
    unchanged = finish in {"stop", "eos"} and notes._unchanged(text, markdown)
    reason = (
        None if unchanged else notes.reorganize_rejection_reason(text, markdown, finish, outline)
    )
    return markdown, finish, ms, reason, not unchanged


async def bench_priority(corrector, cases, repetitions=3, delay=1.0):
    """A dictation correction and a Live Notes segment arriving `delay` s into a reorganize."""
    rows = []
    for _ in range(repetitions):
        for case in cases:
            for profile, raw, budget in (
                ("default", DICTATION, corrector.config.timeout),
                (LIVE_NOTES_ID, SEGMENT, corrector.config.notes_timeout),
            ):
                running = asyncio.create_task(reorganize_once(corrector, case))
                await asyncio.sleep(delay)
                started = time.perf_counter()
                result = await corrector.process(raw, profile)
                ms = (time.perf_counter() - started) * 1000
                # A queued correction preempts the running reorganize (it fails closed as timeout).
                (reorganized,) = await asyncio.gather(running, return_exceptions=True)
                preempted = isinstance(reorganized, TimeoutError)
                rows.append(
                    {
                        "id": case["id"],
                        "profile": profile,
                        "budget_ms": budget * 1000,
                        "ms": round(ms),
                        "error": result.error,
                        "reorganize": "preempted" if preempted else round(reorganized[2]),
                    }
                )
    return {
        profile: {
            "runs": len(group),
            "budget_ms": group[0]["budget_ms"],
            "p50_ms": round(statistics.median(row["ms"] for row in group)),
            "max_ms": max(row["ms"] for row in group),
            "within_budget": sum(row["error"] is None for row in group),
            "errors": dict(Counter(row["error"] for row in group if row["error"])),
            "reorganize_preempted": sum(row["reorganize"] == "preempted" for row in group),
        }
        for profile in ("default", LIVE_NOTES_ID)
        for group in [[row for row in rows if row["profile"] == profile]]
    } | {"rows": rows}


def reorganize_cases(limit):
    """Every eval document whole (sizes above `limit` show why the cap is where it is), plus,
    for those above it, the trailing sections the client would send (`scope-<chars>` rows)."""
    cases = []
    for case in read_jsonl(REORGANIZE_SET):
        cases.append(case | {"size": case["id"].rsplit("-", 1)[1]})
        if len(case["notes"]) > limit and (scope := client_scope(case["notes"], limit)):
            text, outline = scope
            size = f"scope-{limit}"
            outline = (case["outline"] + outline)[-24:]
            cases.append(case | {"notes": text, "outline": outline, "size": size, "scoped": True})
    return cases


async def bench_reorganize(
    model_id, repetitions, dump, limit=notes.MAX_REORGANIZE_CHARS, priority_check=True
):
    cases = reorganize_cases(limit)
    # Dictation and segment budgets as shipped; the reorganize calls pass their own 120 s.
    config = CorrectionConfig(mode="managed", model=model_id, structure_timeout=120)
    corrector = Corrector(config)
    count, counted = token_counter(model_id)
    prompt_tokens = prompt_counter(model_id)
    system = notes.reorganize_system_prompt()
    rows, outputs = [], []
    try:
        started = time.perf_counter()
        await corrector.complete("Reply with OK.", "Notes JSON: {}", 8, priority="structure")
        cold_ms = (time.perf_counter() - started) * 1000
        for _ in range(repetitions):
            for case in cases:
                markdown, finish, ms, reason, changed = await reorganize_once(corrector, case)
                keywords, tasks = kept(markdown, case)
                user = notes.reorganize_user_message(case.get("outline", []), case["notes"])
                rows.append(
                    {
                        "id": case["id"] + (" (scope)" if case.get("scoped") else ""),
                        "size": case["size"],
                        "chars": len(case["notes"]),
                        "ms": ms,
                        "prompt_tokens": prompt_tokens(system, user) if prompt_tokens else None,
                        "tokens": count(markdown),
                        "finish": finish,
                        "reason": reason,
                        "changed": changed,
                        "keywords": keywords,
                        "tasks": tasks,
                    }
                )
                outputs.append(
                    {"id": case["id"], "size": case["size"], "reason": reason}
                    | {"changed": changed, "markdown": markdown}
                )
        # The largest documents the client sends: the longest reorganize a correction waits on.
        within = [case for case in cases if len(case["notes"]) <= limit]
        largest = sorted(within, key=lambda case: -len(case["notes"]))[:3]
        priority = await bench_priority(corrector, largest) if priority_check else None
    finally:
        await corrector.close()
    if dump:
        write_dump(dump, outputs)
    by_size = {}
    for row in rows:
        by_size.setdefault(row["size"], []).append(row)

    def order(item):
        size = item[0]
        return (size.startswith("scope"), int(size.rsplit("-", 1)[-1]))

    return {
        "model": model_id,
        "set": "reorganize",
        "token_count": counted,
        "max_tokens": notes.REORGANIZE_MAX_TOKENS,
        "max_chars": notes.MAX_REORGANIZE_CHARS,
        "scope_chars": limit,
        "system_prompt_chars": len(system),
        "system_prompt_tokens": prompt_tokens(system, "") if prompt_tokens else None,
        "context": CONTEXT,
        "cold_ms": round(cold_ms),
        "overall": reorganize_summary(rows),
        "by_size": {
            size: reorganize_summary(group) for size, group in sorted(by_size.items(), key=order)
        },
        "failures": [{"id": row["id"], "reason": row["reason"]} for row in rows if row["reason"]],
        "rows": [
            {key: row[key] for key in ("id", "chars", "prompt_tokens", "tokens", "finish")}
            | {"ms": round(row["ms"]), "reason": row["reason"], "changed": row["changed"]}
            for row in rows
        ],
        "negatives": reorganize_negatives(),
        "priority": priority,
    }


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=list(MODELS), default=DEFAULT_MODEL)
    parser.add_argument("--set", choices=list(SETS), default="clean", dest="fixtures")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--dump", help="write every output (synthetic text) to this JSONL file")
    parser.add_argument("--mode", choices=["structure", "reorganize", "both"], default="structure")
    parser.add_argument(
        "--no-priority",
        action="store_true",
        help="reorganize: skip the correction-behind-reorganize latency check",
    )
    parser.add_argument(
        "--max-chars",
        type=int,
        default=notes.MAX_REORGANIZE_CHARS,
        help="reorganize: client scope limit for documents above it (default: the server cap)",
    )
    arguments = parser.parse_args()
    try:
        discover(arguments.model)
    except ValueError:
        raise SystemExit(
            "cleanup weights missing; explicitly run `model fetch --cleanup`"
        ) from None
    if arguments.mode == "reorganize":
        result = await bench_reorganize(
            arguments.model,
            arguments.repetitions,
            arguments.dump,
            arguments.max_chars,
            not arguments.no_priority,
        )
    else:
        result = await bench(
            arguments.model, arguments.repetitions, arguments.dump, arguments.fixtures
        )
    if arguments.mode == "both":
        dump = arguments.dump and arguments.dump + ".reorganize"
        result = {
            "structure": result,
            "reorganize": await bench_reorganize(
                arguments.model,
                arguments.repetitions,
                dump,
                arguments.max_chars,
                not arguments.no_priority,
            ),
        }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
