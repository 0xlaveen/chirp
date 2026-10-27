"""Recent request metadata: which device used this server, when, for what, how it ended.

It stays on this machine: an owner-only (0600) file beside the server state, read only through the
owner-token endpoint, and never logged or sent anywhere. An event holds the time, who (kind +
device id), the client kind, the kind of request, the style (profile) id, how long it took, the
audio length for audio requests and an outcome code. It never holds text, audio, prompts, learned
items, outlines, selections, session ids, character counts, addresses, `Tailscale-User-*`
identities or tokens and their digests. `[activity] keep = false` in server.toml, or the Mac's
"Keep device activity" switch, stops recording and deletes what is stored. See docs/privacy.md."""

import contextlib
import json
import os
import re
import secrets
import stat
import time
from collections import deque
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .fsutil import NOFOLLOW, private_mkdir

MAX_EVENTS = 5000
MAX_DAYS = 30
FLUSH_SECONDS = 5.0
STAMP = "%Y-%m-%dT%H:%M:%SZ"
MAX_FILE = 16 * 1024 * 1024
WORD = re.compile(r"[a-z_]{1,32}")
IDENT = re.compile(r"[0-9a-f]{8}")
PROFILE = re.compile(r"[A-Za-z0-9_-]{1,64}")

AUDIO_KINDS = {"dictation", "notes_segment", "notes_retranscribe", "transcribe"}


def wall() -> datetime:
    return datetime.now(UTC)


def stamp(moment: datetime) -> str:
    return moment.strftime(STAMP)


def parse_stamp(value) -> datetime:
    return datetime.strptime(value, STAMP).replace(tzinfo=UTC)


@dataclass
class Token:
    """One request in flight; `Activity.end` turns it into an event."""

    source: tuple
    client: str | None
    kind: str
    started: float
    since: datetime
    outcome: str = "disconnected"
    audio_ms: int | None = None
    profile: str | None = None
    corrected: bool | None = None
    done: bool = False


class Activity:
    """Bounded lists in memory, saved to `path` (when given) shortly after they change, so a
    restart keeps them. Pass `keep=False` to record nothing."""

    def __init__(
        self,
        path=None,
        keep=True,
        max_events=MAX_EVENTS,
        max_days=MAX_DAYS,
        clock=time.monotonic,
        now=wall,
    ):
        self.path = Path(path) if path is not None else None
        self.config_keep = keep
        self.max_events, self.max_age = max_events, timedelta(days=max_days)
        self.clock, self.now = clock, now
        self.started = now()
        self.active: list[Token] = []
        self.events: deque = deque(maxlen=max_events)
        # (reason, device id or None) -> [count, last time]
        self.counters: dict[tuple, list] = {}
        # The Mac switch's choice; it wins over server.toml and is saved with the data.
        self.override: bool | None = None
        self.dirty = False
        self.load()

    @property
    def keep(self) -> bool:
        return self.config_keep if self.override is None else self.override

    def begin(self, source, client, kind) -> Token:
        token = Token(source, client, kind, self.clock(), self.now())
        if self.keep:
            self.active.append(token)
        else:
            token.done = True  # records nothing
        return token

    def end(self, token, outcome=None, audio_ms=None):
        if token.done:
            return
        token.done = True
        if outcome is not None:
            token.outcome = outcome
        if audio_ms is not None:
            token.audio_ms = audio_ms
        with contextlib.suppress(ValueError):
            self.active.remove(token)
        if not self.keep:
            return
        self.events.append(
            {
                "at": self.now(),
                "source": token.source,
                "client": token.client,
                "kind": token.kind,
                "duration_ms": max(0, round((self.clock() - token.started) * 1000)),
                "audio_ms": token.audio_ms if token.kind in AUDIO_KINDS else None,
                "outcome": token.outcome,
                "profile": token.profile,
                "corrected": token.corrected,
            }
        )
        self.dirty = True

    @contextlib.contextmanager
    def track(self, source, client, kind):
        """A request whose outcome the caller sets on the token; an escaping exception or a
        cancelled handler leaves it `disconnected`."""
        token = self.begin(source, client, kind)
        try:
            yield token
        finally:
            self.end(token)

    def refused(self, reason, device=None):
        if not self.keep:
            return
        entry = self.counters.setdefault((reason, device), [0, None])
        entry[0] += 1
        entry[1] = self.now()
        self.dirty = True

    def set_keep(self, keep: bool):
        """The Mac switch. Turning it off deletes everything stored, in memory and on disk."""
        self.override = keep
        if not keep:
            self.active.clear()
            self.events.clear()
            self.counters.clear()
        self.dirty = True
        self.flush()

    def prune(self):
        cutoff = self.now() - self.max_age
        while self.events and self.events[0]["at"] < cutoff:
            self.events.popleft()
            self.dirty = True
        for key in [key for key, (_, last) in self.counters.items() if last < cutoff]:
            del self.counters[key]
            self.dirty = True

    def snapshot(self, devices) -> dict:
        """`devices` maps a device id to its current (name, revoked); joined here so a rename
        or revoke shows correctly. Anything past the retention age is dropped first."""
        self.prune()

        def who(source):
            kind, ident = source
            if kind != "device":
                return {"kind": kind}
            name, revoked = devices.get(ident, (None, False))
            return {"kind": "device", "id": ident, "name": name, "revoked": revoked}

        def refusal(reason, device, count, last):
            entry = {"reason": reason}
            if device is not None:
                entry["device"] = {"id": device, "name": devices.get(device, (None, False))[0]}
            return entry | {"count": count, "last": stamp(last)}

        return {
            "started": stamp(self.started),
            "keep": self.keep,
            "retention": {"max_events": self.max_events, "max_age_days": self.max_age.days},
            "active": [
                {
                    "source": who(token.source),
                    "client": token.client,
                    "kind": token.kind,
                    "profile": token.profile,
                    "since": stamp(token.since),
                }
                for token in self.active
            ],
            "events": [
                {
                    "at": stamp(event["at"]),
                    "source": who(event["source"]),
                    "client": event["client"],
                    "kind": event["kind"],
                    "profile": event["profile"],
                    "corrected": event["corrected"],
                    "duration_ms": event["duration_ms"],
                    "audio_ms": event["audio_ms"],
                    "outcome": event["outcome"],
                }
                for event in reversed(self.events)
            ],
            "refused": [
                refusal(reason, device, count, last)
                for (reason, device), (count, last) in sorted(
                    self.counters.items(), key=lambda item: item[1][1], reverse=True
                )
            ],
        }

    # Persistence: one JSON file, replaced atomically, written at most every few seconds.

    def payload(self) -> dict:
        data = {"version": 1}
        if self.override is not None:
            data["keep"] = self.override
        if self.keep:
            data["events"] = [
                [
                    stamp(event["at"]),
                    *event["source"],
                    event["client"],
                    event["kind"],
                    event["duration_ms"],
                    event["audio_ms"],
                    event["outcome"],
                    event["profile"],
                    event["corrected"],
                ]
                for event in self.events
            ]
            data["refused"] = [
                [reason, device, count, stamp(last)]
                for (reason, device), (count, last) in self.counters.items()
            ]
        return data

    def pending(self) -> dict | None:
        """The data to save if anything changed since the last save, else None."""
        if not self.dirty or self.path is None:
            return None
        self.prune()
        self.dirty = False
        return self.payload()

    def write(self, data: dict):
        if self.path is None:
            return
        if not data.get("events") and not data.get("refused") and "keep" not in data:
            self.path.unlink(missing_ok=True)
            return
        private_mkdir(self.path.parent)
        temporary = self.path.with_name(f".{self.path.name}.{secrets.token_hex(4)}.tmp")
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(data, stream, separators=(",", ":"))
                stream.write("\n")
            os.replace(temporary, self.path)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise

    def flush(self):
        data = self.pending()
        if data is None:
            return
        try:
            self.write(data)
        except OSError:
            self.dirty = True  # try again at the next flush

    def load(self):
        """Read what an earlier run saved. A missing, unreadable or malformed file starts empty;
        a malformed entry is skipped, never raised."""
        if self.path is None:
            return
        try:
            fd = os.open(self.path, os.O_RDONLY | NOFOLLOW)
            with os.fdopen(fd, "rb") as stream:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    return
                data = json.loads(stream.read(MAX_FILE))
        except (OSError, ValueError):
            return
        if not isinstance(data, dict):
            return
        if isinstance(data.get("keep"), bool):
            self.override = data["keep"]
        if not self.keep:
            self.dirty = True  # turned off in server.toml: delete what an earlier run saved
            return
        for row in data.get("events", ()) if isinstance(data.get("events"), list) else ():
            with contextlib.suppress(Exception):
                self.events.append(self.event(row))
        for row in data.get("refused", ()) if isinstance(data.get("refused"), list) else ():
            with contextlib.suppress(Exception):
                reason, device, count, last = row
                if (
                    not WORD.fullmatch(reason)
                    or not (device is None or IDENT.fullmatch(device))
                    or type(count) is not int
                    or count < 1
                ):
                    continue
                self.counters[(reason, device)] = [count, parse_stamp(last)]
        self.prune()

    @staticmethod
    def event(row) -> dict:
        at, source, ident, client, kind, duration, audio, outcome, profile, corrected = row
        if (
            source not in {"device", "local", "shared"}
            or not (ident is None or IDENT.fullmatch(ident))
            or not (client is None or WORD.fullmatch(client))
            or not WORD.fullmatch(kind)
            or not WORD.fullmatch(outcome)
            or not (profile is None or PROFILE.fullmatch(profile))
            or type(duration) is not int
            or not (audio is None or type(audio) is int)
            or not (corrected is None or type(corrected) is bool)
        ):
            raise ValueError("invalid event")
        return {
            "at": parse_stamp(at),
            "source": (source, ident),
            "client": client,
            "kind": kind,
            "duration_ms": duration,
            "audio_ms": audio,
            "outcome": outcome,
            "profile": profile,
            "corrected": corrected,
        }
