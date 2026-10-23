"""Live Notes segment boundaries on long synthetic speech. Metrics only, never text or audio.

The Mac Live Notes recorder cuts a long recording into segments
(mac/Sources/ChirpCore/NotesSegmenter.swift), each decoded on its own. This bench ports that
rule to Python and measures what a cut costs.

* Speech: macOS `say` renders a fixed, invented, seeded corpus (meeting/lecture-like sentences
  with numbers, names and negations), three sentences per clip. Each clip is trimmed of leading
  and trailing quiet (RMS < 0.015) and the clips are concatenated with no gap into 3/10/30
  minute recordings. Rendered clips are cached under the system temp dir, never in the repo.
  `--pause-cap S` shortens internal quiet runs to S seconds (pause-free speech).
* Segmenter port, per 50 ms frame (quiet = RMS < 0.015 on the int16/32768 scale): never cut
  before 12 s of segment audio; cut at 0.6 s of trailing quiet, 0.3 s from 30 s, 0.15 s from
  35 s (the "dip" rule); at 45 s hard-cut whatever is being said. Policies: `real` (that rule)
  and `forced` (a hard cut every 45 s, the worst case for boundaries).
* Overlap: at a hard cut only, the last 1.0 s sent to the old segment is also the start of the
  new one. Pause cuts have no overlap.
* Each segment is decoded standalone with `ParakeetMLX.transcribe_timed` in-process (what the
  server's `finish` does; no server is started). Modes, all from the same decodes:
    a  no overlap (baseline; segments abut at the cut)
    b  overlap + timing dedupe: with S = C - V/2, the old segment keeps words whose midpoint
       is < S and the new one words whose midpoint is >= S
    c  overlap + text-only dedupe: drop the new segment's first two words if they equal the
       old segment's last two (case/punctuation-insensitive), else its first word if it
       equals the old's last word
    d  b using each word's start time instead of its midpoint
    e  overlap + longest text match (the old's last k words == the new's first k, k <= 6)
    f  b, then c's text rule on whatever repeat is left
    g  anchor on the longest run of words both decodes heard in the overlap: keep the old
       segment through the run and the new one after it (b then c's rule when no run)
* Metrics. Texts are lowercased, hyphens spaced, apostrophes and other punctuation dropped,
  digits spelled out (the reference is spelled out). WER: jiwer over the joined text.
  Boundary WER: for each hard cut C, the reference words whose estimated time (clip start plus
  the word's character-proportional share of the clip) is within C +- 3 s form a window; the
  hypothesis is aligned to the whole reference with jiwer, and the substitutions, deletions and
  insertions inside the window are divided by the window's reference words. Drops are deleted
  reference words in a window; duplicates are inserted hypothesis words in a window that
  repeat the hypothesis words next to them (said once, written twice across the join).

Run (one process; loads the model from ~/.koi/voice-models/parakeet-mlx):
    cd server && uv run python scripts/bench_boundaries.py --minutes 3 10 30
"""

import argparse
import hashlib
import json
import os
import platform
import random
import re
import subprocess
import tempfile
import time
import wave
from pathlib import Path

import jiwer
import numpy as np

RATE = 16000
FRAME = 800  # 50 ms
MIN_SEGMENT, MAX_SEGMENT, QUIET_RMS, OVERLAP, WINDOW = 12.0, 45.0, 0.015, 1.0, 3.0
EPSILON = 1e-6
MODES = "abcdefg"

ONES = "zero one two three four five six seven eight nine ten eleven twelve".split()
ONES += "thirteen fourteen fifteen".split()
ONES += "sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def spell(number):
    if number < 20:
        return ONES[number]
    if number < 100:
        return TENS[number // 10] + (" " + ONES[number % 10] if number % 10 else "")
    if number < 1000:
        rest = number % 100
        return ONES[number // 100] + " hundred" + (" " + spell(rest) if rest else "")
    rest = number % 1000
    return spell(number // 1000) + " thousand" + (" " + spell(rest) if rest else "")


# --- corpus ---

NAMES = "Priya Raman|Tomas Hendrick|Marguerite Olsen|Dmitri Kovalenko|Aisha Bello|Wei Zhang"
NAMES += "|Lucia Ferreira"
NAMES += "|Jonas Eriksen|Noor Haddad|Callum Brody|Ingrid Svensson|Rafael Ortiz"
PLACES = "the Lisbon office|the warehouse in Leeds|the Denver site"
PLACES += "|the new lab|the east wing|the Osaka team"
THINGS = "the billing service|the onboarding flow|the cooling system|the quarterly budget"
THINGS += "|the pilot study"
THINGS += "|the supplier contract|the mobile release|the safety audit|the data migration"
THINGS += "|the grant proposal"
TEMPLATES = [
    "{name} said {thing} would take {n} days, not {m}.",
    "We do not expect {thing} to ship before the {ord} of next month.",
    "Last year {place} handled {big} orders, and this year it is already at {big2}.",
    "{name} did not agree with the estimate, because {thing} has {n} open issues.",
    "The first step is to measure {thing}; only then can we decide what to cut.",
    "Nobody on {place} has seen {thing} fail more than {n} times in a row.",
    "If the error rate stays under {n} percent, {name} will sign off on {thing}.",
    "It is not that {thing} is slow, it is that we never measured it before.",
    "Remember that {name} joined {place} in the spring, so ask about {thing} early.",
    "There were {big} participants, but only {big2} of them finished {thing}.",
    "We moved the review of {thing} from the {ord} to the {ord2}, which gives {name} {n} days.",
    "Do not forget that {place} closes at {n} on Fridays, so plan {thing} around it.",
    "The main risk is that {thing} depends on {name}, who is away for {n} weeks.",
    "Compared with last quarter, {thing} cost {n} percent less and took {m} fewer hours.",
]
ORDINALS = (
    "second third fourth fifth sixth seventh eighth ninth tenth twelfth fifteenth twentieth".split()
)


def sentence(rng):
    fills = {
        "name": rng.choice(NAMES.split("|")),
        "place": rng.choice(PLACES.split("|")),
        "thing": rng.choice(THINGS.split("|")),
        "n": spell(rng.randint(2, 48)),
        "m": spell(rng.randint(2, 48)),
        "big": spell(rng.randint(120, 9800)),
        "big2": spell(rng.randint(120, 9800)),
        "ord": rng.choice(ORDINALS),
        "ord2": rng.choice(ORDINALS),
    }
    return rng.choice(TEMPLATES).format(**fills)


def clip_texts(count, seed, per_clip=3):
    rng = random.Random(seed)
    return [" ".join(sentence(rng) for _ in range(per_clip)) for _ in range(count)]


def tokens_of(text):
    """Normalized tokens: lowercase, no punctuation, digits spelled out."""
    text = text.lower().replace("-", " ").replace("%", " percent ").replace("'", "")
    text = re.sub(r"(?<=\d),(?=\d)", "", text)
    text = re.sub(r"\d+", lambda m: " " + spell(int(m.group())) + " ", text)
    return re.sub(r"[^a-z ]+", " ", text).split()


# --- audio ---


def render(text, voice, cache):
    key = hashlib.sha1(f"{voice}|{text}".encode()).hexdigest()[:16]
    path = cache / f"{key}.wav"
    for _ in range(4):  # `say` occasionally hangs or writes silence on a loaded host
        if not path.exists():
            part = path.with_suffix(".part.wav")
            command = ["say", "-v", voice, "-o", str(part), "--data-format=LEI16@16000", text]
            try:
                subprocess.run(command, check=True, timeout=60)
            except subprocess.TimeoutExpired:
                continue
            part.rename(path)
        with wave.open(str(path), "rb") as audio:
            assert audio.getframerate() == RATE and audio.getnchannels() == 1
            pcm = np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2")
        audio = pcm.astype(np.float32) / 32768
        if len(audio) >= 320 and (frame_rms(audio, 320) >= QUIET_RMS).any():
            return audio
        path.unlink()
    raise SystemExit("`say` did not produce audio")


def frame_rms(audio, size):
    count = len(audio) // size
    frames = audio[: count * size].reshape(count, size)
    return np.sqrt(np.mean(frames * frames, axis=1))


def trim(audio):
    loud = np.flatnonzero(frame_rms(audio, 320) >= QUIET_RMS)
    if not loud.size:
        return audio[:0]
    return audio[loud[0] * 320 : (loud[-1] + 1) * 320]


def cap_quiet(audio, seconds):
    """Shorten every internal quiet run (below the segmenter threshold) to `seconds`."""
    size, keep = 320, max(1, round(seconds * RATE / 320))
    quiet = frame_rms(audio, size) < QUIET_RMS
    frames = audio[: len(quiet) * size].reshape(-1, size)
    out, run = [], 0
    for frame, is_quiet in zip(frames, quiet, strict=True):
        run = run + 1 if is_quiet else 0
        if run <= keep:
            out.append(frame)
    return np.concatenate(out)


def build_recording(minutes, voice, cache, seed, pause_cap):
    """Clips concatenated with no gap; returns the audio and (word, estimated time) pairs."""
    audio, reference, total, index = [], [], 0, 0
    texts = clip_texts(int(minutes * 60 / 8) + 40, seed)
    while total < minutes * 60 * RATE:
        clip = trim(render(texts[index], voice, cache))
        if pause_cap is not None:
            clip = cap_quiet(clip, pause_cap)
        words = tokens_of(texts[index])
        weights = np.array([len(w) + 1 for w in words], dtype=float)
        edges = np.r_[0, np.cumsum(weights)] / weights.sum()
        start, duration = total / RATE, len(clip) / RATE
        reference += [
            (w, start + duration * (edges[i] + edges[i + 1]) / 2) for i, w in enumerate(words)
        ]
        audio.append(clip)
        total += len(clip)
        index += 1
    length = int(minutes * 60 * RATE)
    return np.concatenate(audio)[:length], [(w, t) for w, t in reference if t < length / RATE]


# --- segmenter port (mac/Sources/ChirpCore/NotesSegmenter.swift) ---


def segment(audio, policy):
    """Cut positions as (sample, 'hard' | 'pause'), counting 50 ms frames like the Swift struct."""
    rms = frame_rms(audio, FRAME)
    cuts, elapsed, quiet = [], 0, 0
    for index, level in enumerate(rms):
        elapsed += 1
        quiet = quiet + 1 if level < QUIET_RMS else 0
        end = (index + 1) * FRAME
        if elapsed >= round(MAX_SEGMENT * 20):
            cuts.append((end, "hard"))
        elif policy == "real" and elapsed >= round(MIN_SEGMENT * 20):
            need = 12 if elapsed < 600 else 6 if elapsed < 700 else 3
            if quiet < need:
                continue
            cuts.append((end, "pause"))
        else:
            continue
        elapsed = quiet = 0
    # A cut exactly at the end of the recording is just the recording stopping.
    return [cut for cut in cuts if cut[0] < len(audio)]


def plan(total, cuts, overlap):
    """Segments as dicts: audio span, and the document time of hard cuts at either end."""
    segments, start = [], 0
    previous = None
    for end, kind in [*cuts, (total, None)]:
        begin = start - int(OVERLAP * RATE) if overlap and previous == "hard" else start
        segments.append(
            {
                "begin": begin,
                "end": end,
                "hard_start": start / RATE if overlap and previous == "hard" else None,
                "hard_end": end / RATE if overlap and kind == "hard" else None,
            }
        )
        start, previous = end, kind
    return segments


def decode_all(engine, audio, segments, memo):
    """Fill each segment's words (document time) with a standalone timed decode."""
    for seg in segments:
        key = (seg["begin"], seg["end"])
        if key not in memo:
            began = time.perf_counter()
            timed = engine.transcribe_timed(audio[seg["begin"] : seg["end"]])
            if timed.words is None:
                raise SystemExit("engine returned no word timings")
            offset = seg["begin"] / RATE
            memo[key] = (
                [(w.text, w.start + offset, w.end + offset) for w in timed.words],
                time.perf_counter() - began,
            )
        seg["words"], seg["seconds"] = memo[key]


# --- dedupe ---


def key(word):
    return "".join(tokens_of(word[0]))


def text_rule(out, words):
    """Drop the first two words if they equal the last two kept, else the first if equal."""
    if (
        len(out) >= 2
        and len(words) >= 2
        and [key(w) for w in out[-2:]] == [key(w) for w in words[:2]]
    ):
        return words[2:]
    if out and words and key(out[-1]) == key(words[0]):
        return words[1:]
    return words


def longest_rule(out, words):
    for k in range(min(6, len(out), len(words)), 0, -1):
        if [key(w) for w in out[-k:]] == [key(w) for w in words[:k]]:
            return words[k:]
    return words


def trimmed(seg, words, at):
    half = OVERLAP / 2
    if seg["hard_end"] is not None:
        words = [w for w in words if at(w) < seg["hard_end"] - half]
    if seg["hard_start"] is not None:
        words = [w for w in words if at(w) >= seg["hard_start"] - half]
    return words


def middle(word):
    return (word[1] + word[2]) / 2


def start(word):
    return word[1]


def anchor(out, words, cut):
    """Longest run of equal words in both decodes of the overlap: (old index, new index, length).

    Runs of one word need both decodes to time it within 0.3 s of each other."""
    old = [i for i in range(len(out)) if out[i][2] > cut - OVERLAP - 0.5]
    new = [j for j in range(len(words)) if words[j][1] < cut + 0.5]
    best = None
    for oi in old:
        for nj in new:
            size = 0
            while (
                oi + size < len(out)
                and nj + size < len(words)
                and key(out[oi + size]) == key(words[nj + size])
                and key(out[oi + size])
            ):
                size += 1
            if size == 1 and abs(out[oi][1] - words[nj][1]) > 0.3:
                size = 0
            if size and (best is None or size > best[2]):
                best = (oi, nj, size)
    return best


def assemble(segments, mode):
    at = start if mode == "d" else middle
    out = []
    for seg in segments:
        words = seg["words"]
        if mode in "bdf":
            words = trimmed(seg, words, at)
        if mode == "g" and seg["hard_start"] is not None:
            cut = seg["hard_start"]
            found = anchor(out, words, cut)
            if found:
                oi, nj, size = found
                del out[oi + size :]
                words = words[nj + size :]
            else:
                while out and middle(out[-1]) >= cut - OVERLAP / 2:
                    out.pop()
                words = text_rule(out, [w for w in words if middle(w) >= cut - OVERLAP / 2])
        elif seg["hard_start"] is not None:
            if mode in "cf":
                words = text_rule(out, words)
            elif mode == "e":
                words = longest_rule(out, words)
        out += words
    return [t for w in out for t in tokens_of(w[0])]


# --- metrics ---


def score(reference, hyp, hard_cuts):
    """Overall WER and the aligned errors, drops and duplicates inside +-3 s of each hard cut."""
    ref = [w for w, _ in reference]
    times = np.array([t for _, t in reference])
    result = jiwer.process_words(" ".join(ref), " ".join(hyp))
    row = {
        "wer": round(result.wer, 4),
        "boundary_wer": None,
        "dups": 0,
        "drops": 0,
        "window_words": 0,
    }
    if not hard_cuts:
        return row
    windows = [
        (int(np.searchsorted(times, c - WINDOW)), int(np.searchsorted(times, c + WINDOW, "right")))
        for c in hard_cuts
    ]
    errors = 0
    for lo, hi in windows:
        row["window_words"] += hi - lo
        for chunk in result.alignments[0]:
            rs, re_, hs, he = (
                chunk.ref_start_idx,
                chunk.ref_end_idx,
                chunk.hyp_start_idx,
                chunk.hyp_end_idx,
            )
            if chunk.type == "equal":
                continue
            if chunk.type == "insert":
                if not lo <= rs <= hi:
                    continue
                size = he - hs
                errors += size
                words = hyp[hs:he]
                if words == hyp[hs - size : hs] or words == hyp[he : he + size]:
                    row["dups"] += size
                else:
                    row["dups"] += sum(
                        (j > 0 and hyp[j] == hyp[j - 1])
                        or (j + 1 < len(hyp) and hyp[j] == hyp[j + 1])
                        for j in range(hs, he)
                    )
                continue
            inside = max(0, min(re_, hi) - max(rs, lo))
            errors += inside
            if chunk.type == "delete":
                row["drops"] += inside
    row["boundary_wer"] = round(errors / max(1, row["window_words"]), 4)
    return row


def table(rows):
    header = ["min", "policy", "mode", "cuts", "hard", "WER %", "boundary WER %", "dups", "drops"]
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    for r in rows:
        boundary = "-" if r["boundary_wer"] is None else f"{r['boundary_wer'] * 100:.1f}"
        cells = [r["minutes"], r["policy"], r["mode"], r["cuts"], r["hard"]]
        cells += [f"{r['wer'] * 100:.2f}", boundary, r["dups"], r["drops"]]
        lines.append("| " + " | ".join(str(c) for c in cells) + " |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--minutes", type=float, nargs="+", default=[3, 10, 30])
    parser.add_argument(
        "--policies", nargs="+", choices=["real", "forced"], default=["real", "forced"]
    )
    parser.add_argument("--modes", default=MODES, help="subset of abcdef")
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument(
        "--pause-cap",
        type=float,
        help="shorten internal quiet runs to this many seconds; default natural",
    )
    parser.add_argument(
        "--cache", type=Path, default=Path(tempfile.gettempdir()) / "chirp-bench-boundaries"
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)

    from chirp_server.engine.mlx import ParakeetMLX

    engine = ParakeetMLX()
    engine.load()
    engine.warm()
    rows, notes = [], []
    for minutes in args.minutes:
        audio, reference = build_recording(
            minutes, args.voice, args.cache, args.seed, args.pause_cap
        )
        memo = {}
        for policy in args.policies:
            cuts = segment(audio, policy)
            hard = [c for c, kind in cuts if kind == "hard"]
            base = plan(len(audio), cuts, overlap=False)
            lapped = plan(len(audio), cuts, overlap=True)
            began = time.perf_counter()
            decode_all(engine, audio, base, memo)
            decode_all(engine, audio, lapped, memo)
            notes.append(
                {
                    "minutes": minutes,
                    "policy": policy,
                    "decode_wall_s": round(time.perf_counter() - began, 1),
                    "segments": len(base),
                }
            )
            for mode in args.modes:
                hyp = assemble(base if mode == "a" else lapped, mode)
                row = score(reference, hyp, [c / RATE for c in hard])
                rows.append(
                    {
                        "minutes": minutes,
                        "policy": policy,
                        "mode": mode,
                        "cuts": len(cuts),
                        "hard": len(hard),
                        "pause": len(cuts) - len(hard),
                        "ref_words": len(reference),
                        **row,
                    }
                )
            print(json.dumps(notes[-1]), flush=True)
    result = {
        "platform": platform.platform(),
        "engine": engine.name,
        "load_average": os.getloadavg(),
        "logical_cpus": os.cpu_count(),
        "voice": args.voice,
        "seed": args.seed,
        "pause_cap": args.pause_cap,
        "runs": notes,
        "rows": rows,
    }
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2))
    print(table(rows))
    print(json.dumps({k: v for k, v in result.items() if k != "rows"}))


if __name__ == "__main__":
    main()
