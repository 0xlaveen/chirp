"""Saved voices (#247): recognition thresholds for the server's WeSpeaker ResNet34-LM, and the
`wespeaker_v2` agreement spike. Metrics only: never audio, names of real people or text.

* Synthetic voices: the six neural `say` voices that render on this macOS (Samantha, Daniel,
  Moira, Rishi, Karen, Tessa), as every pair's one-minute conversation from
  `mac/scripts/speaker-bench/make_voice_clips.py` (ground-truth RTTM). Each voice is remembered
  from a solo note of other sentences (about 30 s), as naming a person would.
  - phone path: the shipped `SpeakerLabels` (segments cut every 15 s, clustering, the note's
    people), then `voices.match` on the note's people, read 45 s in and at the end;
  - Mac path: each person's settled turns (>= 2 s, the last 30 s of them) as one clip, embedded
    as `POST /v1/speakers/voices` `identify` does.
* Real voices: four AMI meetings (headset mix, CC-BY-4.0, `fetch_ami.sh`), 16 people. Each is
  remembered from the first 30 s of their solo turns and tested on later, disjoint 30 s and 12 s
  stretches (Mac path; one-to-one within a meeting).
* Trials: for every rotation of saved voices (synthetic: every 3 of 6; AMI: 20 seeded draws of
  8 of 16) each person with enough speech is a trial. *true* = a saved person given their own
  name (of trials whose person is saved); *false* = any wrong name (of all trials).
* Spike: 8 s clips of every voice are embedded by both models; `VoiceAgreement` (the Mac's
  `WeSpeakerEmbedder`, `wespeaker_v2@df2625a`) writes its side. Agreement means cosine >= 0.9 per
  clip between the two models' embeddings of the same clip.

usage:
  uv run python scripts/bench_voices.py --model ONNX --clips B/voices --ami B/ami \\
      --spike B/spike [--mac-embeddings B/spike/mac.json] [--out B/voices-bench.json] [--spike-only]
"""

import argparse
import asyncio
import hashlib
import itertools
import json
import random
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

import numpy as np

from chirp_server import speakers as sp
from chirp_server import voices as vs

VOICES = ["Samantha", "Daniel", "Moira", "Rishi", "Karen", "Tessa"]
ENROL_LINES = [
    "Before we start, I want to go over what changed since last week.",
    "The release candidate is ready, and the installer passed every check on Monday.",
    "We still need someone to own the migration guide and the support article.",
    "If the numbers hold up, I would like to open the beta to everyone next month.",
    "Let me know by tomorrow if anything here looks wrong to you.",
    "I will send a short summary to the whole team after this call.",
]
SPIKE_LINES = [
    "The weather turned cold this morning, so I took the train instead of the bike.",
    "Please remember to water the plants on the balcony while I am away.",
    "Our team finished the quarterly report two days ahead of schedule.",
    "My brother is visiting next weekend, and we are planning a long walk by the river.",
    "The library closes early on public holidays, so check the hours before you go.",
    "I could not find the charger anywhere, so I borrowed one from a colleague.",
]
SEGMENT = 15  # seconds per Notes segment
CHECKPOINT = 45.0
THRESHOLDS = [0.45, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8]
MARGINS = [0.05, 0.10, 0.15]
RATE = sp.RATE


def read_wav(path) -> np.ndarray:
    with wave.open(str(path)) as clip:
        assert clip.getframerate() == RATE and clip.getsampwidth() == 2, path
        data = np.frombuffer(clip.readframes(clip.getnframes()), "<i2")
        if clip.getnchannels() > 1:
            data = data.reshape(-1, clip.getnchannels())[:, 0]
    return data.astype(np.float32) / 32768


def write_wav(path, audio):
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(pcm(audio))


def pcm(audio) -> bytes:
    return (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()


def rttm(path) -> list[tuple[str, float, float]]:
    turns = []
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if parts and parts[0] == "SPEAKER":
            start, length = float(parts[3]), float(parts[4])
            turns.append((parts[7], start, start + length))
    return sorted(turns, key=lambda t: t[1])


def solo(turns, minimum=2.0):
    """Turns at least `minimum` long that overlap nobody else's."""
    out = []
    for i, (who, start, end) in enumerate(turns):
        clash = any(
            other != who and s < end and e > start
            for j, (other, s, e) in enumerate(turns)
            if j != i
        )
        if not clash and end - start >= minimum:
            out.append((who, start, end))
    return out


def say(voice, text, cache: Path) -> np.ndarray:
    out = cache / f"{voice}-{hashlib.sha256(text.encode()).hexdigest()[:12]}.wav"
    if not out.exists():
        subprocess.run(
            ["say", "-v", voice, "-o", str(out), "--data-format=LEI16@16000", text], check=True
        )
    return read_wav(out)


def speech_of(voice, lines, cache) -> np.ndarray:
    gap = np.zeros(int(0.4 * RATE), dtype=np.float32)
    return np.concatenate([np.concatenate([say(voice, line, cache), gap]) for line in lines])


class Bench:
    def __init__(self, model):
        self.labels = sp.SpeakerLabels(
            embedder_factory=lambda: sp.OnnxEmbedder(model),
            downloaded=lambda: True,
            library=vs.VoiceLibrary(vs.VoiceStore(Path(tempfile.mkdtemp()))),
        )
        self.notes = 0

    def run(self, coroutine):
        return asyncio.run(coroutine)

    def note(self, audio, checkpoints=()):
        """Feed `audio` through the server's labels as one note: the people (slot -> centroid,
        seconds) at each checkpoint (seconds into the note) and at the end, and every span."""
        self.notes += 1
        session = f"bench-{self.notes:012d}"

        async def go():
            readings, spans, offset = [], [], 0
            marks = sorted(checkpoints)
            for start in range(0, len(audio), SEGMENT * RATE):
                piece = audio[start : start + SEGMENT * RATE]
                note, segment = await self.labels.spans(session, pcm(piece))
                spans += [(s.slot, s.start + offset, s.end + offset) for s in segment]
                offset += len(piece) / RATE
                while marks and offset >= marks[0]:
                    readings.append(people(note))
                    marks.pop(0)
            readings.append(people(note))
            return readings, spans

        def people(note):
            return {i: (s.centroid.copy(), s.seconds) for i, s in enumerate(note.speakers)}

        return self.run(go())

    def clip(self, audio):
        return self.run(self.labels.clip(pcm(audio[: vs.MAX_CLIP_SECONDS * RATE])))

    def whole(self, audio):
        return self.labels._embed([audio])[0]


def turns_audio(audio, turns, until, seconds=30.0):
    """The Mac's clip: a person's settled turns (>= 2 s) before `until`, the last `seconds`."""
    pieces = [audio[int(s * RATE) : int(min(e, until) * RATE)] for _, s, e in turns if e <= until]
    if not pieces:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(pieces)[-int(seconds * RATE) :]


def truth_of(spans, truth):
    """Each slot's person: the reference speaker it overlaps most, if that is >= 80 % of it."""
    overlap: dict[int, dict[str, float]] = {}
    for slot, s, e in spans:
        for who, ts, te in truth:
            both = min(e, te) - max(s, ts)
            if both > 0:
                overlap.setdefault(slot, {}).setdefault(who, 0.0)
                overlap[slot][who] += both
    out = {}
    for slot, by in overlap.items():
        who, most = max(by.items(), key=lambda item: item[1])
        out[slot] = who if most >= 0.8 * sum(by.values()) else "mixed"
    return out


def score(notes, profiles, rotations, threshold, margin):
    """notes: [[(truth, centroid, seconds)]]; profiles: name -> voiceprint."""
    true = true_n = false = total = 0
    for saved in rotations:
        candidates = [
            vs.Candidate(f"{i:016x}", name, profiles[name]) for i, name in enumerate(saved)
        ]
        for people in notes:
            heard = {i: (c, s) for i, (_, c, s) in enumerate(people)}
            found = vs.match(heard, candidates, threshold, margin)
            for i, (who, _, seconds) in enumerate(people):
                if seconds < vs.MATCH_SECONDS:
                    continue
                total += 1
                got = found.get(i)
                if who in saved:
                    true_n += 1
                    true += got is not None and got.name == who
                if got is not None and got.name != who:
                    false += 1
    return {"true": true, "true_of": true_n, "false": false, "false_of": total}


def wrong(notes, profiles, rotations, threshold, margin):
    """Every wrong name at one setting: whose voice it was, the name given, and the score."""
    out = []
    for saved in rotations:
        candidates = [vs.Candidate(f"{i:016x}", n, profiles[n]) for i, n in enumerate(saved)]
        for people in notes:
            heard = {i: (c, s) for i, (_, c, s) in enumerate(people)}
            for i, got in vs.match(heard, candidates, threshold, margin).items():
                who, centroid, seconds = people[i]
                if got.name != who:
                    score = float(vs.unit(centroid) @ got.embedding)
                    out.append((who, got.name, round(score, 2), round(seconds, 1)))
    return sorted(set(out))


def scores(notes, profiles):
    """Each trial's similarity to its own saved voice, and its highest to anyone else's."""
    same, other = [], []
    for people in notes:
        for who, centroid, seconds in people:
            if seconds < vs.MATCH_SECONDS:
                continue
            c = vs.unit(centroid)
            if who in profiles:
                same.append(float(c @ profiles[who]))
            rest = [float(c @ v) for name, v in profiles.items() if name != who]
            if rest:
                other.append(max(rest))
    return {"same": percentiles(same), "other_max": percentiles(other)}


def percentiles(values):
    if not values:
        return {}
    v = np.asarray(values)
    return {
        "n": len(values),
        "min": round(float(v.min()), 3),
        "p5": round(float(np.percentile(v, 5)), 3),
        "median": round(float(np.median(v)), 3),
        "p95": round(float(np.percentile(v, 95)), 3),
        "max": round(float(v.max()), 3),
    }


def sweep(notes, profiles, rotations):
    return {
        f"{t:.2f}/{m:.2f}": score(notes, profiles, rotations, t, m)
        for t in THRESHOLDS
        for m in MARGINS
    }


def rate(r, kind):
    of = r[f"{kind}_of"]
    return f"{100 * r[kind] / of:.1f}% ({r[kind]}/{of})" if of else "-"


def table(title, results):
    print(f"\n{title}")
    keys = list(results)
    print("τ/margin   " + "   ".join(f"{k:>34}" for k in keys))
    for setting in results[keys[0]]:
        cells = [
            f"true {rate(results[k][setting], 'true')} false {rate(results[k][setting], 'false')}"
            for k in keys
        ]
        print(f"{setting:10} " + "   ".join(f"{c:>34}" for c in cells))


def synthetic(bench, clips: Path, cache: Path, out: dict):
    cache.mkdir(parents=True, exist_ok=True)
    rotations = [set(r) for r in itertools.combinations(VOICES, 3)]
    phone_profiles, mac_profiles = {}, {}
    for voice in VOICES:
        audio = speech_of(voice, ENROL_LINES, cache)
        (people,), _ = bench.note(audio)
        slot = max(people, key=lambda s: people[s][1])
        phone_profiles[voice] = vs.unit(people[slot][0])
        out.setdefault("enrol_seconds", {})[voice] = round(people[slot][1], 1)
        mac_profiles[voice] = vs.unit(bench.clip(audio)[0])
    phone = {"45s": [], "end": []}
    mac = {"45s": [], "end": []}
    people_found = []
    for path in sorted(clips.glob("pair_*.wav")):
        a, b = path.stem.split("_")[1:3]
        names = {"spk0": a, "spk1": b}
        truth = [(names[w], s, e) for w, s, e in rttm(path.with_suffix(".rttm"))]
        audio = read_wav(path)
        readings, spans = bench.note(audio, [CHECKPOINT])
        who = truth_of(spans, truth)
        people_found.append(len(readings[-1]))
        for key, reading in zip(("45s", "end"), readings, strict=True):
            phone[key].append([(who.get(slot, "none"), c, s) for slot, (c, s) in reading.items()])
        settled = solo(truth)
        for key, until in (("45s", CHECKPOINT), ("end", len(audio) / RATE)):
            note = []
            for voice in (a, b):
                mine = [t for t in settled if t[0] == voice]
                emb, seconds = bench.clip(turns_audio(audio, mine, until))
                note.append((voice, emb, seconds))
            mac[key].append(note)
    out["synthetic_people_per_note"] = people_found
    out["synthetic_phone"] = {k: sweep(v, phone_profiles, rotations) for k, v in phone.items()}
    out["synthetic_scores"] = {
        "phone_end": scores(phone["end"], phone_profiles),
        "mac_end": scores(mac["end"], mac_profiles),
    }
    out["synthetic_phone_wrong"] = {
        f"{t}": wrong(phone["end"], phone_profiles, rotations, t, vs.MARGIN) for t in (0.6, 0.7)
    }
    out["synthetic_mac_wrong"] = {
        f"{t}": wrong(mac["end"], mac_profiles, rotations, t, vs.MARGIN) for t in (0.6, 0.65)
    }
    out["synthetic_mac"] = {k: sweep(v, mac_profiles, rotations) for k, v in mac.items()}
    table("Synthetic, phone path (server diarization)", out["synthetic_phone"])
    table("Synthetic, Mac path (clips of settled turns)", out["synthetic_mac"])
    # Same-voice and different-voice similarity of the remembered voiceprints.
    names = list(phone_profiles)
    pairs = [
        float(phone_profiles[x] @ phone_profiles[y]) for x, y in itertools.combinations(names, 2)
    ]
    out["synthetic_profile_similarity"] = {"min": min(pairs), "max": max(pairs)}


def ami(bench, folder: Path, out: dict):
    meetings = sorted(p.name.split(".")[0] for p in folder.glob("*.Mix-Headset.wav"))
    if not meetings:
        print(f"\nNo AMI meetings in {folder} (mac/scripts/speaker-bench/fetch_ami.sh)")
        return
    profiles, long_notes, short_notes = {}, [], []
    for meeting in meetings:
        audio = read_wav(folder / f"{meeting}.Mix-Headset.wav")
        settled = solo(rttm(folder / f"{meeting}.rttm"))
        people = sorted({w for w, _, _ in settled})
        stretches = {}
        for who in people:
            mine = [audio[int(s * RATE) : int(e * RATE)] for w, s, e in settled if w == who]
            stretches[who] = np.concatenate(mine)
            enrol = stretches[who][: 30 * RATE]
            profiles[f"{meeting}/{who}"] = vs.unit(bench.clip(enrol)[0])
        for i in range(3):
            for length, notes in ((30, long_notes), (12, short_notes)):
                note = []
                for who in people:
                    start = (30 + 30 * i) * RATE
                    piece = stretches[who][start : start + length * RATE]
                    if len(piece) >= length * RATE * 0.9:
                        emb, seconds = bench.clip(piece)
                        note.append((f"{meeting}/{who}", emb, seconds))
                if note:
                    notes.append(note)
    names = sorted(profiles)
    draw = random.Random(247)
    rotations = [set(draw.sample(names, len(names) // 2)) for _ in range(20)]
    out["ami_people"] = len(names)
    out["ami"] = {
        "30s": sweep(long_notes, profiles, rotations),
        "12s": sweep(short_notes, profiles, rotations),
    }
    table("AMI real voices, Mac path", out["ami"])
    out["ami_scores"] = {"30s": scores(long_notes, profiles), "12s": scores(short_notes, profiles)}
    out["ami_wrong"] = {
        f"{t}": wrong(long_notes + short_notes, profiles, rotations, t, vs.MARGIN)
        for t in (0.5, 0.6, 0.7)
    }
    same_meeting = [
        float(profiles[x] @ profiles[y])
        for x, y in itertools.combinations(names, 2)
        if x.split("/")[0] == y.split("/")[0]
    ]
    out["ami_profile_similarity_same_meeting"] = {
        "min": min(same_meeting),
        "max": max(same_meeting),
    }


def spike(bench, spike_dir: Path, cache: Path, ami_dir: Path, mac: Path | None, out: dict):
    """Writes the spike's clips (once); with the Mac's embeddings, compares the two models."""
    clips_dir = spike_dir / "clips"
    if not clips_dir.exists():
        clips_dir.mkdir(parents=True)
        for voice in VOICES:
            audio = speech_of(voice, SPIKE_LINES, cache)
            for i in range(3):
                piece = audio[i * 8 * RATE : (i + 1) * 8 * RATE]
                if len(piece) == 8 * RATE:
                    write_wav(clips_dir / f"say_{voice}_{i}.wav", piece)
        for path in sorted(ami_dir.glob("*.Mix-Headset.wav")):
            meeting = path.name.split(".")[0]
            audio = read_wav(path)
            settled = solo(rttm(ami_dir / f"{meeting}.rttm"))
            for who in sorted({w for w, _, _ in settled}):
                mine = np.concatenate(
                    [audio[int(s * RATE) : int(e * RATE)] for w, s, e in settled if w == who]
                )
                for i in range(3):
                    piece = mine[(10 + i * 8) * RATE : (18 + i * 8) * RATE]
                    if len(piece) == 8 * RATE:
                        write_wav(clips_dir / f"ami_{meeting}-{who}_{i}.wav", piece)
    if mac is None or not mac.exists():
        print(f"\nSpike clips in {clips_dir}; embed them with the Mac's model:")
        print(
            "  (cd mac/scripts/speaker-bench && swift run -c release VoiceAgreement "
            f"--clips {clips_dir} --out {spike_dir}/mac.json)"
        )
        return
    theirs = {k: np.asarray(v, dtype=np.float32) for k, v in json.loads(mac.read_text()).items()}
    whole, windowed, speakers = {}, {}, {}
    for name in sorted(theirs):
        audio = read_wav(clips_dir / name)
        whole[name] = vs.unit(bench.whole(audio))
        embedding, seconds = bench.clip(audio)
        # A clip too quiet for any window (the server would not remember it) counts as whole.
        windowed[name] = vs.unit(embedding) if seconds else whole[name]
        speakers[name] = name.rsplit("_", 1)[0]
    cos_whole = [float(vs.unit(theirs[n]) @ whole[n]) for n in theirs]
    cos_windowed = [float(vs.unit(theirs[n]) @ windowed[n]) for n in theirs]
    # Whether the Mac's embedding of a clip is nearest to the server's embedding of the same
    # speaker (another clip of theirs) among every speaker's.
    right = 0
    for n in theirs:
        others = [m for m in theirs if m != n]
        nearest = max(others, key=lambda m: float(vs.unit(theirs[n]) @ windowed[m]))
        right += speakers[nearest] == speakers[n]
    # The same check within one model (the server's), for comparison.
    right_server = 0
    for n in theirs:
        others = [m for m in theirs if m != n]
        nearest = max(others, key=lambda m: float(windowed[n] @ windowed[m]))
        right_server += speakers[nearest] == speakers[n]
    # Import: the Mac's embedding of each speaker's first clip as their saved voice, matched
    # against the server's own voiceprints of their other clips (one person at a time), next to
    # the server's own first-clip voiceprints as saved voices.
    first = {}
    for n in sorted(theirs):
        first.setdefault(speakers[n], n)
    imported = {who: vs.unit(theirs[n]) for who, n in first.items()}
    native = {who: windowed[n] for who, n in first.items()}
    trials = [n for n in sorted(theirs) if first[speakers[n]] != n]

    def recognised(saved, threshold):
        candidates = [vs.Candidate(f"{i:016x}", w, v) for i, (w, v) in enumerate(saved.items())]
        right = wrong_ = 0
        for n in trials:
            found = vs.match({0: (windowed[n], 30.0)}, candidates, threshold, vs.MARGIN).get(0)
            right += found is not None and found.name == speakers[n]
            wrong_ += found is not None and found.name != speakers[n]
        return {"right": right, "wrong": wrong_, "of": len(trials)}

    summary = {
        "clips": len(theirs),
        "cosine_whole": stats(cos_whole),
        "cosine_windowed": stats(cos_windowed),
        "agree_0.9_whole": sum(c >= 0.9 for c in cos_whole),
        "agree_0.9_windowed": sum(c >= 0.9 for c in cos_windowed),
        "cross_model_nearest_same_speaker": right,
        "server_nearest_same_speaker": right_server,
        "import": {
            f"{t}": {"imported": recognised(imported, t), "native": recognised(native, t)}
            for t in (0.6, 0.7)
        },
        "same_speaker_imported_vs_windowed": percentiles(
            [float(imported[speakers[n]] @ windowed[n]) for n in trials]
        ),
        "same_speaker_native_vs_windowed": percentiles(
            [float(native[speakers[n]] @ windowed[n]) for n in trials]
        ),
    }
    out["spike"] = summary
    print("\nwespeaker_v2 (Mac) vs ResNet34-LM (server), same clips")
    print(json.dumps(summary, indent=2))


def stats(values):
    v = np.asarray(values)
    return {
        "min": round(float(v.min()), 3),
        "median": round(float(np.median(v)), 3),
        "max": round(float(v.max()), 3),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--clips", type=Path, required=True)
    parser.add_argument("--ami", type=Path, required=True)
    parser.add_argument("--spike", type=Path, required=True)
    parser.add_argument("--mac-embeddings", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--spike-only", action="store_true", help="only the agreement spike")
    args = parser.parse_args()
    if shutil.which("say") is None:
        sys.exit("needs macOS say")
    bench = Bench(args.model)
    cache = args.spike.parent / "say-cache"
    cache.mkdir(parents=True, exist_ok=True)
    out: dict = {}
    started = time.perf_counter()
    if not args.spike_only:
        synthetic(bench, args.clips, cache, out)
        ami(bench, args.ami, out)
    spike(bench, args.spike, cache, args.ami, args.mac_embeddings, out)
    for key in (
        "synthetic_scores",
        "ami_scores",
        "synthetic_profile_similarity",
        "ami_profile_similarity_same_meeting",
        "synthetic_people_per_note",
        "synthetic_phone_wrong",
        "synthetic_mac_wrong",
        "ami_wrong",
    ):
        print(f"\n{key}: " + json.dumps(out.get(key)))
    out["seconds"] = round(time.perf_counter() - started, 1)
    print(f"\n{out['seconds']} s")
    if args.out:
        args.out.write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
