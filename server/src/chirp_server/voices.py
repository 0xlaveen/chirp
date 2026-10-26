"""Saved voices for Live Notes speaker labels (issue #247): one library per Chirp server, shared
by every client paired to it.

A saved voice is a name and a voiceprint: the unit mean of the pinned WeSpeaker model's
embeddings of that person's speech. It lives in one file on this machine,
`data_dir()/speakers/voices.json` (folder 0700, file 0600; owner-only ACL on Windows), next to
nothing else, and nowhere else: never logged, never returned to a client (the API lists names
and seconds only), never sent anywhere. Removing the speaker model keeps the voices; a voice
from another model is listed as incompatible and never compared.

`enabled` is the "Remember voices" switch: off, nothing is saved or recognised. Forget all
deletes the file (or, while off, empties it so the switch stays off).
"""

import base64
import contextlib
import json
import os
import re
import secrets
import stat
import unicodedata
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import paths, speakers_model
from .devices import STAMP, now
from .fsutil import NOFOLLOW, locked, private_mkdir

FILE = "voices.json"
MAX_VOICES = 50
# A name the notes accept as a speaker label (#212): one line, no colon, a letter, ≤ 60.
MAX_NAME = 60
# Recognition: a note's person is a saved voice when the voices are at least THRESHOLD alike and
# MARGIN ahead of the next saved voice (the Mac's `VoiceMatch`, benched for this model in
# docs/bench.md "Saved voices (server)").
THRESHOLD = 0.7
MARGIN = 0.10
# Seconds of a person's speech before they are matched, and before they can be remembered (the
# Mac's `VoiceMatch.minSeconds` / `enrolSeconds`): the clients' gates, on their turns' durations.
MATCH_SECONDS = 10.0
ENROL_SECONDS = 20.0
# A clip the Mac sends (its last 30 s of one person's settled turns).
MAX_CLIP_SECONDS = 30
MAX_DIMENSIONS = 1024
# Voiceprints another model made that compare with this one's: the Mac's `wespeaker_v2` is the
# same network, quantised (docs/bench.md "Saved voices (server)": cosine 0.98-0.99 on the same
# clips), so its saved voices (#18) can be imported once. Its voiceprints have this many numbers.
IMPORTABLE = {"wespeaker_v2@df2625a"}
DIMENSIONS = 256
VOICE_ID = re.compile(r"[0-9a-f]{16}")


def directory() -> Path:
    """Not the model folder (Remove model deletes that), and never roaming on Windows."""
    return paths.data_dir() / "speakers"


class VoiceError(Exception):
    """A request the library refuses: `code` is the protocol's error code."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def clean_name(name) -> str:
    """One line, no colon, at least one letter, at most MAX_NAME characters; spaces collapse."""
    if not isinstance(name, str) or any(unicodedata.category(c)[0] == "C" for c in name):
        raise VoiceError("bad_speakers")
    name = re.sub(r"\s+", " ", name).strip()
    if not 0 < len(name) <= MAX_NAME or ":" in name or not any(c.isalpha() for c in name):
        raise VoiceError("bad_speakers")
    return name


def encode(vector: np.ndarray) -> str:
    return base64.b64encode(np.asarray(vector, dtype="<f4").tobytes()).decode("ascii")


def decode(text: str) -> np.ndarray:
    raw = base64.b64decode(text, validate=True)
    if not raw or len(raw) % 4 or len(raw) > 4 * MAX_DIMENSIONS:
        raise ValueError("embedding")
    vector = np.frombuffer(raw, dtype="<f4").astype(np.float32)
    if not np.isfinite(vector).all() or not np.linalg.norm(vector) > 0:
        raise ValueError("embedding")
    return vector


def unit(vector: np.ndarray) -> np.ndarray:
    return (vector / max(float(np.linalg.norm(vector)), 1e-9)).astype(np.float32)


def _valid(voice) -> bool:
    if not isinstance(voice, dict) or set(voice) != {
        "id",
        "name",
        "model",
        "embedding",
        "seconds",
        "created",
        "updated",
    }:
        return False
    try:
        clean_name(voice["name"])
        decode(voice["embedding"])
    except (VoiceError, ValueError, TypeError):
        return False
    return (
        isinstance(voice["id"], str)
        and VOICE_ID.fullmatch(voice["id"]) is not None
        and isinstance(voice["model"], str)
        and 0 < len(voice["model"]) <= 128
        and isinstance(voice["seconds"], int | float)
        and not isinstance(voice["seconds"], bool)
        and 0 <= voice["seconds"] < 1e7
        and all(
            isinstance(voice[key], str) and STAMP.fullmatch(voice[key]) is not None
            for key in ("created", "updated")
        )
    )


class VoiceStore:
    """`voices.json` and its lock. Writers hold `voices.lock` and replace the file atomically
    (the `DeviceStore` pattern), so readers never need the lock. Reading never creates anything:
    a server whose user never saved a voice writes nothing."""

    def __init__(self, folder: Path):
        self.directory = Path(folder)
        self.path = self.directory / FILE

    @contextlib.contextmanager
    def locked(self):
        private_mkdir(self.directory)
        fd = os.open(self.directory / "voices.lock", os.O_CREAT | os.O_RDWR | NOFOLLOW, 0o600)
        try:
            with locked(fd):
                yield
        finally:
            os.close(fd)

    def signature(self):
        try:
            info = os.stat(self.path)
        except FileNotFoundError:
            return None
        except OSError:
            return "unreadable"
        return (info.st_ino, info.st_mtime_ns, info.st_size)

    def read(self) -> dict:
        """`{"enabled", "voices"}`; the default (on, no voices) when there is no file. A file
        that is not a valid library raises ValueError and is never overwritten by a write that
        read it (Forget all deletes it)."""
        if not NOFOLLOW and self.path.is_symlink():
            raise ValueError("Saved voices file must be a regular file")
        try:
            fd = os.open(self.path, os.O_RDONLY | NOFOLLOW)
        except FileNotFoundError:
            return {"enabled": True, "voices": []}
        except OSError:
            raise ValueError("Saved voices file must be a regular file") from None
        with os.fdopen(fd) as stream:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("Saved voices file must be a regular file")
            if os.name == "posix" and stat.S_IMODE(info.st_mode) != 0o600:
                os.fchmod(fd, 0o600)
            try:
                data = json.loads(stream.read())
            except ValueError:
                raise ValueError("Saved voices file is invalid") from None
        if (
            not isinstance(data, dict)
            or not isinstance(data.get("enabled"), bool)
            or not isinstance(data.get("voices"), list)
            or len(data["voices"]) > MAX_VOICES
            or not all(_valid(voice) for voice in data["voices"])
            or len({voice["id"] for voice in data["voices"]}) != len(data["voices"])
        ):
            raise ValueError("Saved voices file is invalid")
        return {"enabled": data["enabled"], "voices": data["voices"]}

    def write(self, library: dict):
        private_mkdir(self.directory)
        temporary = self.directory / f".{FILE}.{secrets.token_hex(4)}.tmp"
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(
                    {"version": 1, "enabled": library["enabled"], "voices": library["voices"]},
                    stream,
                    indent=2,
                )
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise

    def delete(self):
        self.path.unlink(missing_ok=True)


def public(voice: dict, model: str) -> dict:
    """What a client sees of a voice: never its voiceprint."""
    return {
        "id": voice["id"],
        "name": voice["name"],
        "seconds": round(float(voice["seconds"]), 1),
        "created": voice["created"],
        "updated": voice["updated"],
        "compatible": voice["model"] == model,
    }


@dataclass(frozen=True)
class Candidate:
    """A compatible saved voice, ready to compare."""

    id: str
    name: str
    embedding: np.ndarray


def match(
    people: dict[int, tuple[np.ndarray, float]],
    voices: list[Candidate],
    threshold: float = THRESHOLD,
    margin: float = MARGIN,
    min_seconds: float = MATCH_SECONDS,
) -> dict[int, Candidate]:
    """For each person (centroid, seconds) with enough speech, the voice at least `threshold`
    alike and `margin` ahead of every other voice. A voice goes to at most one person, the
    closest: the Mac's `VoiceMatch.suggest`."""
    best: dict[str, tuple[int, float]] = {}
    for person, (centroid, seconds) in sorted(people.items()):
        if seconds < min_seconds or not voices:
            continue
        centroid = unit(centroid)
        scores = sorted(
            (
                (float(centroid @ voice.embedding), voice.id)
                for voice in voices
                if voice.embedding.shape == centroid.shape
            ),
            reverse=True,
        )
        if not scores or scores[0][0] < threshold:
            continue
        if len(scores) > 1 and scores[0][0] - scores[1][0] < margin:
            continue
        top, voice = scores[0]
        if voice in best and best[voice][1] >= top:
            continue
        best[voice] = (person, top)
    by_id = {voice.id: voice for voice in voices}
    return {person: by_id[voice] for voice, (person, _) in best.items()}


class VoiceLibrary:
    """The library's operations. Reads are cached by the file's identity, so a change made with
    `chirp-server voices` applies to the next note without a restart."""

    def __init__(self, store: VoiceStore | None = None, model: str = speakers_model.MODEL_ID):
        self.store = store or VoiceStore(directory())
        self.model = model
        self.cached = None
        self.signature = object()

    def read(self) -> dict:
        signature = self.store.signature()
        if signature != self.signature or self.cached is None:
            self.cached = self.store.read()
            self.signature = signature
        return self.cached

    def listing(self) -> dict:
        library = self.read()
        return {
            "enabled": library["enabled"],
            "model": self.model,
            "voices": [public(voice, self.model) for voice in library["voices"]],
        }

    def health(self) -> dict:
        try:
            library = self.read()
        except (OSError, ValueError):
            return {"enabled": False, "count": 0, "model": self.model, "error": "unreadable"}
        return {"enabled": library["enabled"], "count": len(library["voices"]), "model": self.model}

    def candidates(self) -> list[Candidate]:
        """The voices recognition compares (none while the switch is off)."""
        library = self.read()
        if not library["enabled"]:
            return []
        return [
            Candidate(voice["id"], voice["name"], unit(decode(voice["embedding"])))
            for voice in library["voices"]
            if voice["model"] == self.model
        ]

    def _change(self, edit):
        with self.store.locked():
            library = self.store.read()
            result = edit(library)
            self.store.write(library)
        return result

    def _find(self, library: dict, ident) -> dict:
        found = next((v for v in library["voices"] if v["id"] == ident), None)
        if found is None:
            raise VoiceError("no_voice")
        return found

    def remember(self, name, embedding: np.ndarray, seconds: float, voice=None) -> dict:
        """Save a new voice, or with `voice` update that one: a seconds-weighted mean of the
        two voiceprints (a voice from another model is replaced). Returns the voice's listing."""
        name = clean_name(name)
        embedding = unit(np.asarray(embedding, dtype=np.float32))
        if seconds < ENROL_SECONDS:
            raise VoiceError("too_short")

        def edit(library):
            if not library["enabled"]:
                raise VoiceError("disabled")
            stamp = now()
            if voice is not None:
                found = self._find(library, voice)
                old = decode(found["embedding"])
                if found["model"] == self.model and old.shape == embedding.shape:
                    weight = float(found["seconds"])
                    embedding_out = unit(old * weight + embedding * seconds)
                    total = weight + seconds
                else:
                    embedding_out, total = embedding, seconds
                found.update(
                    name=name,
                    model=self.model,
                    embedding=encode(embedding_out),
                    seconds=round(total, 1),
                    updated=stamp,
                )
                return public(found, self.model)
            if len(library["voices"]) >= MAX_VOICES:
                raise VoiceError("full")
            taken = {v["id"] for v in library["voices"]}
            while (ident := secrets.token_hex(8)) in taken:
                pass
            saved = {
                "id": ident,
                "name": name,
                "model": self.model,
                "embedding": encode(embedding),
                "seconds": round(float(seconds), 1),
                "created": stamp,
                "updated": stamp,
            }
            library["voices"].append(saved)
            return public(saved, self.model)

        return self._change(edit)

    def rename(self, voice, name) -> None:
        name = clean_name(name)

        def edit(library):
            found = self._find(library, voice)
            found["name"] = name
            found["updated"] = now()

        self._change(edit)

    def forget(self, voice) -> None:
        def edit(library):
            self._find(library, voice)
            library["voices"] = [v for v in library["voices"] if v["id"] != voice]

        self._change(edit)

    def forget_all(self) -> None:
        """Delete the file; while the switch is off, keep an empty library so it stays off. An
        unreadable file is deleted too: this is the way out of it."""
        with self.store.locked():
            try:
                enabled = self.store.read()["enabled"]
            except ValueError:
                enabled = True
            if enabled:
                self.store.delete()
            else:
                self.store.write({"enabled": False, "voices": []})

    def enable(self) -> None:
        def edit(library):
            library["enabled"] = True

        self._change(edit)

    def disable(self, forget: bool = False) -> None:
        def edit(library):
            library["enabled"] = False
            if forget:
                library["voices"] = []

        self._change(edit)
