"""Live Notes speaker labels for clients that stream their notes here (issue #187).

A client that sends `start.speakers = {"session": id}` gets `final.speakers`: the segment's
turns, each with the note's speaker slot. Per utterance, after the decode and beside clean-up:

1. 1.5 s windows (0.75 s hop) of voiced audio are embedded with the pinned WeSpeaker model;
2. the segment's windows are clustered (average linkage, cosine);
3. each cluster is matched one-to-one against the note's speakers, else becomes a new one;
4. words take the speaker of the windows they overlap (a port of the Mac's
   `SpeakerAttribution`), and the turns are carried onto the corrected text by a word
   alignment (the Mac's `WordDiff`).

The note's speakers (centroid sums and seconds of speech) live in this process's memory only,
keyed by the client's random session id, evicted when idle and lost on restart: a new
`generation` tells the client to start its slot map again. Nothing here is logged except
counts and timings: never a label, an embedding, a name or text.

Saved voices (issue #247, `voices.py`): when the library is on and holds voices of this model,
`final.speakers` also carries `matches`, the note's people recognised as saved voices. A client
remembers a person from the note's speaker in memory here (`from`), or from a clip of their
speech (`audio`, the Mac), and identifies people from clips.
"""

import asyncio
import logging
import time
import uuid
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field, replace

import numpy as np

from . import speakers_model, voices

log = logging.getLogger("chirp")

RATE = 16000
WINDOW = int(1.5 * RATE)
HOP = int(0.75 * RATE)
# Windows within one segment join while their average similarity is at least this. Tuned on
# `say` voices and two real two-person recordings (docs/bench.md): real voices' 1.5 s windows
# of one person score 0.35-0.85, of two people under 0.25; very similar voices merge.
LOCAL_THRESHOLD = 0.4
# A segment's cluster is the note's speaker when their centroids are at least this similar.
MATCH_THRESHOLD = 0.45
# A cluster that matches nobody needs this much speech to be a new person; less goes to the
# most similar one (a cough, a short noisy window).
NEW_SPEAKER_SECONDS = 1.5
MAX_SPEAKERS = 8
# A segment shorter than this has no speaker of its own: it is embedded whole.
MIN_EMBED = int(0.5 * RATE)
# A window needs this share of voiced frames (0.5 s of its 1.5 s) to be embedded.
VOICED_SHARE = 1 / 3

# Attribution (the Mac's `SpeakerAttribution` constants).
NEAREST_WITHIN = 1.0
MIN_TURN_WORDS = 2
MIN_TURN_SECONDS = 0.5
# A window span is at least one hop long, so "heard" needs more than a single window.
KEEP_DETECTED = 1.0
MIN_ALIGNED = 0.6
MAX_PAIRS = 90_000


# Features: Kaldi-compatible log-mel fbank (WeSpeaker's front end), NumPy only.


def _mel(f):
    return 1127.0 * np.log1p(np.asarray(f, dtype=np.float64) / 700.0)


def _banks(bins=80, fft=512, rate=RATE, low=20.0, high=RATE / 2):
    lo, hi = _mel(low), _mel(high)
    delta = (hi - lo) / (bins + 1)
    freqs = _mel(np.arange(fft // 2) * rate / fft)
    out = np.zeros((bins, fft // 2))
    for m in range(bins):
        left, centre, right = lo + m * delta, lo + (m + 1) * delta, lo + (m + 2) * delta
        rising = (freqs - left) / (centre - left)
        falling = (right - freqs) / (right - centre)
        out[m] = np.maximum(0.0, np.minimum(rising, falling)) * ((freqs > left) & (freqs < right))
    return out


_BANKS = _banks()
_POVEY = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(400) / 399)) ** 0.85


def fbank(audio: np.ndarray) -> np.ndarray:
    """80 log-mel bins per 10 ms (25 ms Povey windows, pre-emphasis 0.97, no dither), with the
    mean over time removed: WeSpeaker's input for float audio in [-1, 1]."""
    x = np.asarray(audio, dtype=np.float64) * 32768.0
    count = 1 + (len(x) - 400) // 160
    if count < 1:
        return np.zeros((0, 80), dtype=np.float32)
    frames = x[np.arange(400)[None, :] + 160 * np.arange(count)[:, None]]
    frames = frames - frames.mean(axis=1, keepdims=True)
    frames = np.concatenate(
        [frames[:, :1] * (1 - 0.97), frames[:, 1:] - 0.97 * frames[:, :-1]], axis=1
    )
    power = np.abs(np.fft.rfft(frames * _POVEY, 512)) ** 2
    energies = power[:, :256] @ _BANKS.T
    out = np.log(np.maximum(energies, np.finfo(np.float32).eps)).astype(np.float32)
    return out - out.mean(axis=0)


class OnnxEmbedder:
    """The pinned WeSpeaker model on onnxruntime's CPU provider. Owned by one thread."""

    def __init__(self, path=None, threads=2):
        import onnxruntime

        options = onnxruntime.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        options.log_severity_level = 3
        self.session = onnxruntime.InferenceSession(
            str(path or speakers_model.path()), options, providers=["CPUExecutionProvider"]
        )
        self.input = self.session.get_inputs()[0].name

    def embed(self, clips: list[np.ndarray]) -> np.ndarray:
        """One L2-normalised embedding per clip (float audio, 16 kHz)."""
        out = []
        for clip in clips:
            features = fbank(clip)
            vector = self.session.run(None, {self.input: features[None]})[0][0]
            out.append(vector / max(float(np.linalg.norm(vector)), 1e-9))
        return np.asarray(out, dtype=np.float32)


# Windows and clustering (pure, tested with synthetic embeddings).


def voiced(audio: np.ndarray) -> np.ndarray:
    """Per 10 ms: whether the frame is speech-loud, relative to this segment's loud part."""
    frames = len(audio) // 160
    if frames == 0:
        return np.zeros(0, dtype=bool)
    power = (audio[: frames * 160].reshape(frames, 160).astype(np.float64) ** 2).mean(axis=1)
    db = 10 * np.log10(power + 1e-12)
    floor = max(-55.0, float(np.percentile(db, 95)) - 30.0)
    return db > floor


def windows(audio: np.ndarray) -> list[tuple[int, int]]:
    """Sample ranges to embed: 1.5 s windows every 0.75 s with at least a third voiced
    (0.5 s of speech). A segment shorter than a window is one window (if it is long enough to
    say anything)."""
    if len(audio) < MIN_EMBED:
        return []
    if len(audio) < WINDOW + HOP // 2:
        return [(0, len(audio))]
    loud = voiced(audio)
    out = []
    for start in range(0, len(audio) - WINDOW + 1, HOP):
        frames = loud[start // 160 : (start + WINDOW) // 160]
        if frames.size and frames.mean() >= VOICED_SHARE:
            out.append((start, start + WINDOW))
    # The tail past the last full window, when it holds speech of its own.
    last = out[-1][1] if out else 0
    if len(audio) - last >= HOP // 2 and (tail := loud[(len(audio) - WINDOW) // 160 :]).size:
        if tail.mean() >= VOICED_SHARE:
            out.append((len(audio) - WINDOW, len(audio)))
    return out


def speech(audio: np.ndarray, start: int, end: int) -> np.ndarray:
    """A window's voiced 10 ms frames only: silence and the pause between two people would
    otherwise pull windows together that share nothing but quiet."""
    loud = voiced(audio[start:end])
    frames = audio[start : start + len(loud) * 160].reshape(-1, 160)[loud].reshape(-1)
    return frames if len(frames) >= MIN_EMBED else audio[start:end]


def cluster(embeddings: np.ndarray, threshold: float = LOCAL_THRESHOLD) -> list[int]:
    """Average-linkage agglomerative clustering by cosine similarity: a label per row, in order
    of first appearance."""
    n = len(embeddings)
    if n == 0:
        return []
    similarity = embeddings @ embeddings.T
    groups = [[i] for i in range(n)]
    while len(groups) > 1:
        best, pair = -2.0, None
        for a in range(len(groups)):
            for b in range(a + 1, len(groups)):
                value = float(similarity[np.ix_(groups[a], groups[b])].mean())
                if value > best:
                    best, pair = value, (a, b)
        if best < threshold or pair is None:
            break
        a, b = pair
        groups[a] = sorted(groups[a] + groups[b])
        del groups[b]
    labels = [0] * n
    for index, group in enumerate(sorted(groups, key=min)):
        for i in group:
            labels[i] = index
    return labels


def _unit(vector):
    return vector / max(float(np.linalg.norm(vector)), 1e-9)


@dataclass
class Speaker:
    total: np.ndarray
    seconds: float

    @property
    def centroid(self):
        return _unit(self.total)


@dataclass
class NoteSpeakers:
    """One note's speakers, in this server's memory only. A slot is an index into `speakers`."""

    generation: str = field(default_factory=lambda: uuid.uuid4().hex[:16])
    speakers: list[Speaker] = field(default_factory=list)
    used: float = field(default_factory=time.monotonic)
    # The slot of the note's last labelled word: a segment with no voiced window continues it.
    last: int | None = None

    def learn(self, slot: int, rows: np.ndarray, seconds: float):
        speaker = self.speakers[slot]
        speaker.total = speaker.total + rows.sum(axis=0)
        speaker.seconds += len(rows) * seconds

    def assign(self, embeddings: np.ndarray, labels: list[int], seconds: float) -> list[int]:
        """Each local cluster's slot: one-to-one matches best first, then new speakers for
        clusters with enough speech (up to `MAX_SPEAKERS`), else the most similar speaker.
        Every window's slot, in order; the matched speakers learn the new windows."""
        count = max(labels) + 1 if labels else 0
        members = [[i for i, label in enumerate(labels) if label == c] for c in range(count)]
        centroids = [_unit(embeddings[m].sum(axis=0)) for m in members]
        slots: dict[int, int] = {}
        pairs = sorted(
            (
                (float(centroids[c] @ speaker.centroid), c, s)
                for c in range(count)
                for s, speaker in enumerate(self.speakers)
            ),
            reverse=True,
        )
        taken = set()
        for value, c, s in pairs:
            if value < MATCH_THRESHOLD:
                break
            if c not in slots and s not in taken:
                slots[c] = s
                taken.add(s)
        # Unmatched clusters in order of first appearance, so the first voice heard is numbered
        # first; one too short to be somebody then goes to the most similar voice, new or not.
        unmatched = [c for c in range(count) if c not in slots]
        for c in unmatched:
            enough = len(members[c]) * seconds >= NEW_SPEAKER_SECONDS or not self.speakers
            if enough and len(self.speakers) < MAX_SPEAKERS:
                self.speakers.append(Speaker(np.zeros_like(centroids[c]), 0.0))
                slots[c] = len(self.speakers) - 1
                self.learn(slots[c], embeddings[members[c]], seconds)
        for c in unmatched:
            if c not in slots:
                slots[c] = max(
                    range(len(self.speakers)),
                    key=lambda s: float(centroids[c] @ self.speakers[s].centroid),
                )
                self.learn(slots[c], embeddings[members[c]], seconds)
        for c in range(count):
            if c not in unmatched:
                self.learn(slots[c], embeddings[members[c]], seconds)
        return [slots[label] for label in labels]


@dataclass(frozen=True)
class Span:
    slot: int
    start: float
    end: float

    @property
    def duration(self):
        return self.end - self.start


def spans(ranges: list[tuple[int, int]], slots: list[int], length: int) -> list[Span]:
    """Window labels as speaker spans in seconds. Overlapping windows split at the midpoint of
    their centres; a window with no neighbour keeps its whole stretch (the first and last reach
    the segment's edges, a silent gap stays unlabelled), and runs of one slot merge."""
    out: list[Span] = []
    for i, ((start, end), slot) in enumerate(zip(ranges, slots, strict=True)):
        lo, hi = start, end
        if i == 0:
            lo = 0
        elif ranges[i - 1][1] > start:
            lo = (sum(ranges[i - 1]) + start + end) / 4
        if i == len(ranges) - 1:
            hi = length
        elif ranges[i + 1][0] < end:
            hi = (start + end + sum(ranges[i + 1])) / 4
        if out and out[-1].slot == slot and abs(lo / RATE - out[-1].end) < 1e-9:
            out[-1] = Span(slot, out[-1].start, hi / RATE)
        else:
            out.append(Span(slot, lo / RATE, hi / RATE))
    return out


# Attribution: the Mac's `SpeakerAttribution` and `WordDiff.alignment`, in Python.


@dataclass
class Turn:
    slot: int
    start: float
    end: float
    text: str
    raw: str
    approximate: bool = False
    kept_original: bool = False

    def payload(self) -> dict:
        return {
            "speaker": self.slot,
            "start": round(self.start, 3),
            "end": round(self.end, 3),
            "text": self.text,
            "raw": self.raw,
            "approximate": self.approximate,
            "kept_original": self.kept_original,
        }


def _key(word: str) -> str:
    letters = "".join(c for c in word.lower() if c.isalnum())
    return letters or word


def alignment(raw: list[str], cleaned: list[str]) -> list[int | None] | None:
    """For each cleaned word, the raw word it matches (up to case and punctuation), or None
    for an added word; None when the texts are too long to compare cheaply."""
    a, b = [_key(w) for w in raw], [_key(w) for w in cleaned]
    if a == b:
        return list(range(len(cleaned)))
    if len(a) * len(b) > MAX_PAIRS:
        return None
    table = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) - 1, -1, -1):
        for j in range(len(b) - 1, -1, -1):
            table[i][j] = (
                table[i + 1][j + 1] + 1 if a[i] == b[j] else max(table[i + 1][j], table[i][j + 1])
            )
    out: list[int | None] = [None] * len(b)
    i = j = 0
    while i < len(a) or j < len(b):
        if i < len(a) and j < len(b) and a[i] == b[j]:
            out[j] = i
            i, j = i + 1, j + 1
        elif j < len(b) and (i == len(a) or table[i][j + 1] >= table[i + 1][j]):
            j += 1
        else:
            i += 1
    return out


def _slot_for(word, all_spans):
    best = None
    for s in all_spans:
        overlap = min(word[1], s.end) - max(word[0], s.start)
        if overlap > 0 and overlap > (best[1] if best else 0):
            best = (s.slot, overlap)
    if best:
        return best[0]
    nearest = None
    for s in all_spans:
        distance = max(s.start - word[1], word[0] - s.end, 0)
        if distance <= NEAREST_WITHIN and distance < (nearest[1] if nearest else float("inf")):
            nearest = (s.slot, distance)
    return nearest[0] if nearest else None


def dominant(start: float, end: float, all_spans: list[Span]) -> int | None:
    totals: dict[int, float] = {}
    for s in all_spans:
        overlap = min(end, s.end) - max(start, s.start)
        if overlap > 0:
            totals[s.slot] = totals.get(s.slot, 0.0) + overlap
    if totals:
        return max(totals.items(), key=lambda item: (item[1], -item[0]))[0]
    return _slot_for((start, end), all_spans)


def _runs(slots: list[int]) -> list[range]:
    out, start = [], 0
    for i in range(1, len(slots) + 1):
        if i == len(slots) or slots[i] != slots[start]:
            out.append(range(start, i))
            start = i
    return out if slots else []


def assign_words(times, all_spans, previous=None) -> list[int] | None:
    slots = [_slot_for(t, all_spans) for t in times]
    last = None
    for i, s in enumerate(slots):
        if s is not None:
            last = s
        elif last is not None:
            slots[i] = last
    following = None
    for i in range(len(slots) - 1, -1, -1):
        if slots[i] is not None:
            following = slots[i]
        elif following is not None:
            slots[i] = following
    if all(s is None for s in slots) and previous is not None:
        return [previous] * len(slots)
    return None if any(s is None for s in slots) else slots


def smooth(slots: list[int], times, all_spans) -> None:
    runs = _runs(slots)
    if len(runs) < 3:
        return
    for r in range(1, len(runs) - 1):
        before, run, after = runs[r - 1], runs[r], runs[r + 1]
        if slots[before.start] != slots[after.start]:
            continue
        slot = slots[run.start]
        start, end = times[run.start][0], times[run.stop - 1][1]
        if len(run) >= MIN_TURN_WORDS or end - start >= MIN_TURN_SECONDS:
            continue
        heard = any(
            s.slot == slot
            and s.end > start - 0.05
            and s.start < end + 0.05
            and s.duration >= KEEP_DETECTED
            for s in all_spans
        )
        if not heard:
            for i in run:
                slots[i] = slots[before.start]


def project(raw_words: list[str], times, slots: list[int], text: str) -> list[Turn]:
    runs = _runs(slots)
    raw_turns = [
        Turn(
            slots[r.start],
            times[r.start][0],
            times[r.stop - 1][1],
            " ".join(raw_words[r.start : r.stop]),
            " ".join(raw_words[r.start : r.stop]),
        )
        for r in runs
    ]
    cleaned = text.split()
    if not cleaned:
        return raw_turns
    if len(runs) == 1:
        return [replace(raw_turns[0], text=text)]
    aligned = alignment(raw_words, cleaned)
    if aligned is None or sum(a is not None for a in aligned) < MIN_ALIGNED * len(cleaned):
        return [replace(t, kept_original=True) for t in raw_turns]
    run_of = [index for index, r in enumerate(runs) for _ in r]
    first = next((run_of[a] for a in aligned if a is not None), 0)
    groups: list[list] = []
    for j, word in enumerate(cleaned):
        a = aligned[j]
        run = run_of[a] if a is not None else (groups[-1][0] if groups else first)
        # A word aligned to an earlier run than the one before it (a reordering) stays put.
        if groups and run <= groups[-1][0]:
            groups[-1][1].append(word)
        else:
            groups.append([run, [word]])
    # Each raw run's text goes with the last group at or before it.
    raws: list[list[int]] = [[] for _ in groups]
    for r in range(len(raw_turns)):
        g = max((g for g, (run, _) in enumerate(groups) if run <= r), default=0)
        raws[g].append(r)
    turns: list[Turn] = []
    for g, (run, words) in enumerate(groups):
        said = " ".join(words)
        raw = " ".join(raw_turns[r].raw for r in raws[g])
        end = max((raw_turns[r].end for r in raws[g]), default=raw_turns[run].end)
        slot = raw_turns[run].slot
        if turns and turns[-1].slot == slot:
            last = turns[-1]
            last.text += " " + said
            last.raw += (" " + raw) if raw else ""
            last.end = max(last.end, end)
        else:
            turns.append(Turn(slot, raw_turns[run].start, end, said, raw))
    return turns


def attribute(
    words, raw: str, text: str, duration: float, all_spans, previous: int | None = None
) -> list[Turn] | None:
    """The segment's turns over `text` (`words` are the raw decode's timings, or None from an
    engine without them); None when no speaker can be told at all."""
    words = [w for w in (words or ()) if w.text.strip()]
    if not words:
        slot = dominant(0.0, max(duration, 0.0), all_spans)
        slot = previous if slot is None else slot
        if slot is None:
            return None
        return [Turn(slot, 0.0, duration, text, raw, approximate=True)]
    times = [(w.start, max(w.end, w.start)) for w in words]
    slots = assign_words(times, all_spans, previous)
    if slots is None:
        return None
    smooth(slots, times, all_spans)
    return project([w.text for w in words], times, slots, text)


# The service.


class Sessions:
    """Notes' speakers by the client's session id: LRU-capped, evicted after idling."""

    def __init__(self, limit=32, idle=6 * 3600, clock=time.monotonic):
        self.limit, self.idle, self.clock = limit, idle, clock
        self.notes: OrderedDict[str, NoteSpeakers] = OrderedDict()
        self.locks: dict[str, asyncio.Lock] = {}

    def get(self, session: str) -> NoteSpeakers:
        now = self.clock()
        for key in [k for k, v in self.notes.items() if now - v.used > self.idle]:
            self.drop(key)
        note = self.notes.pop(session, None) or NoteSpeakers(used=now)
        note.used = now
        self.notes[session] = note
        while len(self.notes) > self.limit:
            self.drop(next(iter(self.notes)))
        return note

    def drop(self, session):
        self.notes.pop(session, None)
        lock = self.locks.get(session)
        if lock is not None and not lock.locked():
            del self.locks[session]

    def lock(self, session: str) -> asyncio.Lock:
        return self.locks.setdefault(session, asyncio.Lock())

    def clear(self):
        self.notes.clear()
        self.locks.clear()


class SpeakerLabels:
    """Labels for notes: the model (loaded on first use, on its own thread), the notes'
    speakers, and the model's download state for health."""

    def __init__(self, embedder_factory=None, fetch=None, downloaded=None, library=None):
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="chirp-speakers")
        self.factory = embedder_factory or OnnxEmbedder
        self.fetch = fetch or speakers_model.fetch
        self.downloaded = downloaded or speakers_model.is_downloaded
        self.embedder = None
        self.sessions = Sessions()
        self.download: asyncio.Task | None = None
        self.failed = False
        self.library = library if library is not None else voices.VoiceLibrary()

    @property
    def state(self) -> str:
        if self.download is not None and not self.download.done():
            return "downloading"
        if self.downloaded():
            return "ready"
        return "failed" if self.failed else "not_downloaded"

    def health(self) -> dict:
        return {"state": self.state, "size_bytes": speakers_model.SIZE}

    async def call(self, method, *args):
        return await asyncio.get_running_loop().run_in_executor(self.executor, method, *args)

    def start_download(self):
        """The client's consented Download: fetch in the background; health reports it."""
        if self.state in {"downloading", "ready"}:
            return

        async def run():
            try:
                await asyncio.get_running_loop().run_in_executor(None, self.fetch)
                self.failed = False
            except Exception:
                self.failed = True
                log.warning("speakers model download failed")

        self.failed = False
        self.download = asyncio.create_task(run())

    async def remove(self) -> bool:
        if self.state == "downloading":
            return False
        self.embedder = None
        await self.call(speakers_model.remove)
        self.failed = False
        self.sessions.clear()
        return True

    def _embed(self, clips):
        if self.embedder is None:
            self.embedder = self.factory()
        return self.embedder.embed(clips)

    async def spans(self, session: str, pcm: bytes) -> tuple[NoteSpeakers, list[Span]] | None:
        """Embed and cluster one segment into the note's speakers: the note and the segment's
        spans, or None without the model. Segments of one note update it one at a time."""
        if not self.downloaded():
            return None
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        ranges = windows(audio)
        async with self.sessions.lock(session):
            note = self.sessions.get(session)
            if not ranges:
                return note, []
            clips = [speech(audio, a, b) for a, b in ranges]
            embeddings = await self.call(self._embed, clips)
            labels = cluster(embeddings)
            seconds = (ranges[0][1] - ranges[0][0]) / RATE if len(ranges) == 1 else HOP / RATE
            slots = note.assign(embeddings, labels, seconds)
            return note, spans(ranges, slots, len(audio))

    async def measure(self, session: str, pcm: bytes):
        """The segment's (note, spans), else the error payload; never raises."""
        try:
            found = await self.spans(session, pcm)
        except Exception:
            log.warning("speakers code=failed")
            return {"error": "failed"}
        return {"error": "unavailable"} if found is None else found

    def payload(self, measured, words, raw: str, text: str, duration: float, started=None) -> dict:
        """`final.speakers` from `measure`: the turns over `text`, the final's text (the raw
        text again when clean-up was off or failed)."""
        if isinstance(measured, dict):
            return measured
        note, all_spans = measured
        turns = None
        if text.strip():
            turns = attribute(words, raw, text, duration, all_spans, note.last)
            if turns:
                note.last = turns[-1].slot
        payload = {"generation": note.generation, "turns": [t.payload() for t in turns or []]}
        matches = self.matches(note)
        if matches is not None:
            payload["matches"] = matches
        log.info(
            "speakers turns=%d people=%d ms=%.1f",
            len(payload["turns"]),
            len({t["speaker"] for t in payload["turns"]}),
            (time.perf_counter() - (started or time.perf_counter())) * 1000,
        )
        return payload

    def matches(self, note: NoteSpeakers) -> list[dict] | None:
        """The note's people recognised as saved voices; None (no field at all) while the library
        is off, holds no voice of this model, or is unreadable."""
        try:
            candidates = self.library.candidates()
        except (OSError, ValueError):
            log.warning("speakers voices code=unreadable")
            return None
        if not candidates:
            return None
        people = {slot: (s.total, s.seconds) for slot, s in enumerate(note.speakers)}
        found = voices.match(people, candidates)
        log.info("speakers voices count=%d matched=%d", len(candidates), len(found))
        return [
            {"speaker": slot, "voice": voice.id, "name": voice.name}
            for slot, voice in sorted(found.items())
        ]

    def person(self, session: str, generation: str, slot: int) -> tuple[np.ndarray, float]:
        """A note's speaker as (voiceprint, seconds of speech), without touching the note's place
        in the LRU; `gone` when the server no longer holds that note (or that generation)."""
        note = self.sessions.notes.get(session)
        if note is None or note.generation != generation or not 0 <= slot < len(note.speakers):
            raise voices.VoiceError("gone")
        speaker = note.speakers[slot]
        return speaker.centroid, speaker.seconds

    async def clip(self, pcm: bytes) -> tuple[np.ndarray, float]:
        """One person's clip as (voiceprint, seconds of speech covered by embedded windows). The
        clip is held only for this call."""
        if not self.downloaded():
            raise voices.VoiceError("unavailable")
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        ranges = windows(audio)
        if not ranges:
            return np.zeros(1, dtype=np.float32), 0.0
        clips = [speech(audio, a, b) for a, b in ranges]
        try:
            embeddings = await self.call(self._embed, clips)
        except Exception:
            log.warning("speakers voices code=failed")
            raise voices.VoiceError("failed") from None
        covered, end = 0, 0
        for a, b in ranges:
            covered += b - max(a, end)
            end = b
        return _unit(embeddings.sum(axis=0)), covered / RATE

    async def label(self, session, pcm, words, raw, text) -> dict:
        started = time.perf_counter()
        measured = await self.measure(session, pcm)
        return self.payload(measured, words, raw, text, len(pcm) / 2 / RATE, started)

    def close(self):
        self.executor.shutdown(wait=False, cancel_futures=True)
