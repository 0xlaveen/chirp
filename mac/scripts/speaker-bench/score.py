"""Score SpeakerBench output (docs/bench.md, Speaker labels).

- DER over the diarizer's spans (10 ms frames, 0.25 s collar, optimal 1:1 mapping), split into miss, false alarm
  and confusion; confusion is what users see as wrong names.
- Word attribution: the labelled transcript's raw words (real Parakeet words, real Notes segments) are aligned to the
  reference words by text, and each aligned word scores if its Person maps to the reference speaker under the best
  one-to-one mapping. The reference is the clip script (synthetic) or the AMI word-level annotations.
- Speaker count, label lag p50/p95, diarizer time and process CPU as a share of the audio, added RSS, and the
  worst 10-minute window (an identity swap shows up there).

usage: uv run --no-project --with numpy --with scipy python score.py REF_DIR OUT_DIR [AMI_WORDS_DIR]
REF_DIR holds <clip>.rttm and either <clip>.json (synthetic script) or, for AMI clips named <meeting>.<mic>,
AMI_WORDS_DIR/<meeting>.<A-D>.words.xml.
"""

import bisect
import json
import re
import sys
import xml.etree.ElementTree as ET
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np
from scipy.optimize import linear_sum_assignment

STEP = 0.01
COLLAR = 0.25
WINDOW = 600.0
SLACK = 3.0


def rttm(path):
    out = []
    for line in Path(path).read_text().splitlines():
        p = line.split()
        if len(p) > 7 and p[0] == "SPEAKER":
            out.append((p[7], float(p[3]), float(p[3]) + float(p[4])))
    return out


def matrix(segs, labels, frames):
    m = np.zeros((frames, len(labels)), bool)
    index = {label: i for i, label in enumerate(labels)}
    for spk, start, end in segs:
        m[int(start / STEP) : int(end / STEP), index[spk]] = True
    return m


def der(ref, hyp, duration):
    frames = int(duration / STEP) + 1
    rl = sorted({s for s, _, _ in ref})
    hl = sorted({s for s, _, _ in hyp})
    r = matrix(ref, rl, frames)
    h = matrix(hyp, hl, frames)
    keep = np.ones(frames, bool)
    for _, start, end in ref:
        for edge in (start, end):
            keep[max(0, int((edge - COLLAR) / STEP)) : int((edge + COLLAR) / STEP)] = False
    r, h = r[keep], h[keep]
    overlap = r.T.astype(int) @ h.astype(int) if hl else np.zeros((len(rl), 0))
    ri, hi = linear_sum_assignment(-overlap) if hl else ([], [])
    correct = sum(overlap[i, j] for i, j in zip(ri, hi, strict=True))
    nr, nh = r.sum(1), h.sum(1)
    total = nr.sum()
    miss = np.maximum(nr - nh, 0).sum()
    fa = np.maximum(nh - nr, 0).sum()
    conf = np.minimum(nr, nh).sum() - correct
    return {
        "der": round((miss + fa + conf) / total * 100, 1),
        "miss": round(miss / total * 100, 1),
        "confusion": round(conf / total * 100, 1),
        "ref_speakers": len(rl),
    }


def key(word):
    return re.sub(r"[^a-z0-9]", "", word.lower())


def script_words(path):
    """(speaker, time, key) for every word of a synthetic clip's script, words spread over the turn."""
    out = []
    for turn in json.loads(path.read_text()):
        tokens = [t for t in turn["text"].split() if key(t)]
        for i, t in enumerate(tokens):
            out.append((turn["speaker"], turn["start"] + (turn["end"] - turn["start"]) * i / max(len(tokens), 1), key(t)))
    return out


def ami_words(words_dir, meeting):
    out = []
    for path in sorted(Path(words_dir).glob(f"{meeting}.*.words.xml")):
        speaker = path.name.split(".")[1]
        for w in ET.parse(path).getroot():
            if w.tag != "w" or w.get("punc") == "true" or not w.text or w.get("starttime") is None:
                continue
            k = key(w.text)
            if k:
                out.append((speaker, float(w.get("starttime")), k))
    return sorted(out, key=lambda x: x[1])


def hyp_segments(run):
    """(start, end, [(person, key)]) per transcribed segment, in document seconds."""
    segs = [s for s in run["segments"] if not s.get("gap")]
    offsets = [s["offset"] for s in run["segments"]] + [run["audioSeconds"]]
    out = []
    for seg in segs:
        end = min(o for o in offsets if o > seg["offset"]) if any(o > seg["offset"] for o in offsets) else run["audioSeconds"]
        if seg.get("turns"):
            words = [(f"P{t['person']}", key(w)) for t in seg["turns"] for w in t["raw"].split() if key(w)]
        else:
            words = [("none", key(w)) for w in seg["raw"].split() if key(w)]
        out.append((seg["offset"], end, words))
    return out


def attribution(ref, run):
    # Each segment's words align only to the reference words spoken in its own stretch of audio (with slack), so
    # repeated lines in a long session never pair with the wrong occurrence.
    times = [r[1] for r in ref]
    used, pairs = set(), []
    for start, end, words in hyp_segments(run):
        lo, hi = bisect.bisect_left(times, start - SLACK), bisect.bisect_right(times, end + SLACK)
        idx = [i for i in range(lo, hi) if i not in used]
        matcher = SequenceMatcher(None, [ref[i][2] for i in idx], [w[1] for w in words], autojunk=False)
        for b in matcher.get_matching_blocks():
            for k in range(b.size):
                used.add(idx[b.a + k])
                pairs.append((ref[idx[b.a + k]], words[b.b + k][0]))
    rl = sorted({r[0] for r in ref})
    hl = sorted({p for _, p in pairs if p != "none"})
    counts = np.zeros((len(rl), max(len(hl), 1)))
    for r, p in pairs:
        if p != "none":
            counts[rl.index(r[0]), hl.index(p)] += 1
    ri, hi = linear_sum_assignment(-counts) if hl else ([], [])
    mapping = {hl[j]: rl[i] for i, j in zip(ri, hi, strict=True)}
    good = [mapping.get(p) == r[0] for r, p in pairs]
    worst = 100.0
    if pairs:
        end = max(r[1] for r, _ in pairs)
        for start in np.arange(0, end, WINDOW):
            inside = [g for (r, _), g in zip(pairs, good, strict=True) if start <= r[1] < start + WINDOW]
            if len(inside) >= 50:
                worst = min(worst, 100 * sum(inside) / len(inside))
    return {
        "words": round(100 * sum(good) / max(len(pairs), 1), 1),
        "aligned": round(100 * len(pairs) / max(len(ref), 1), 1),
        "worst_10min": round(worst, 1),
    }


def pct(values, q):
    return round(float(np.percentile(values, q)), 2) if values else ""


def main():
    refs, outs = Path(sys.argv[1]), Path(sys.argv[2])
    words_dir = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    rows = []
    for path in sorted(outs.glob("*.json")):
        run = json.loads(path.read_text())
        clip = run["clip"]
        meeting = clip.split(".")[0]
        rttm_path = refs / f"{clip}.rttm"
        if not rttm_path.exists():
            rttm_path = refs / f"{meeting}.rttm"
        ref_segs = rttm(rttm_path)
        hyp = [(s["spk"], s["start"], s["end"]) for s in run["spans"]]
        row = {"run": path.stem, **der(ref_segs, hyp, run["audioSeconds"])}
        if (refs / f"{clip}.json").exists():
            row.update(attribution(script_words(refs / f"{clip}.json"), run))
        elif words_dir:
            row.update(attribution(ami_words(words_dir, meeting), run))
        row["persons"] = run["speakers"]
        row["lag_p50"] = pct(run["lags"], 50)
        row["lag_p95"] = pct(run["lags"], 95)
        row["tentative"] = f"{run['tentative']}/{len(run['lags'])}"
        row["diar_%"] = round(100 * run["diarizerSeconds"] / run["audioSeconds"], 1)
        row["cpu_%"] = round(100 * run["cpuSeconds"] / run["wallSeconds"], 1)
        row["rss_add_MiB"] = round(run.get("rssEndMiB", run["rssPeakMiB"]) - run["rssBeforeMiB"])
        row["rss_peak_MiB"] = round(run["rssPeakMiB"])
        row["load_s"] = round(run["modelLoadSeconds"], 2)
        row["min"] = round(run["audioSeconds"] / 60, 1)
        rows.append(row)
    cols = ["run", "min", "der", "miss", "confusion", "ref_speakers", "persons", "words", "aligned", "worst_10min",
            "lag_p50", "lag_p95", "tentative", "diar_%", "cpu_%", "rss_add_MiB", "rss_peak_MiB", "load_s"]
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    for row in rows:
        print("| " + " | ".join(str(row.get(c, "")) for c in cols) + " |")


if __name__ == "__main__":
    main()
