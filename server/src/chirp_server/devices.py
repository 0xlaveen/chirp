"""Per-device pairing tokens. Only SHA-256 digests are stored; tokens and digests are never
logged or printed (pairing prints a new token once, locally)."""

import contextlib
import hashlib
import ipaddress
import json
import logging
import math
import os
import re
import secrets
import stat
import time
import unicodedata
from datetime import UTC, datetime
from pathlib import Path

from .fsutil import NOFOLLOW, locked, private_mkdir

log = logging.getLogger("chirp")
FILE = "devices.json"
MAX_NAME = 64
SEEN_INTERVAL = 60.0  # seconds between persisted last-seen updates for one device
DIGEST = re.compile(r"[0-9a-f]{64}")
STAMP = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
# A request that came through `tailscale serve` (or any proxy) carries at least one of these.
PROXY_HEADERS = {
    b"x-forwarded-for",
    b"x-forwarded-host",
    b"forwarded",
    b"x-real-ip",
    b"tailscale-user-login",
    b"tailscale-user-name",
}


def direct_loopback(scope) -> bool:
    """The peer is this machine itself and no proxy header is present. A label, not a security
    boundary for the shared token; the owner token adds the boundary for activity."""
    client = scope.get("client")
    try:
        address = ipaddress.ip_address(client[0]) if client else None
    except ValueError:
        address = None
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    if address is None or not address.is_loopback:
        return False
    return not any(name in PROXY_HEADERS for name, _ in scope.get("headers", ()))


def encode(token: str) -> bytes:
    # JSON auth frames may carry lone surrogates; they must fail the comparison, not raise.
    return token.encode("utf-8", "surrogatepass")


def digest(token: str) -> bytes:
    return hashlib.sha256(encode(token)).digest()


def now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def clean_name(name) -> str:
    name = name.strip() if isinstance(name, str) else ""
    if not 0 < len(name) <= MAX_NAME or any(unicodedata.category(c)[0] == "C" for c in name):
        raise ValueError(f"Device name must be 1-{MAX_NAME} printable characters")
    return name


def public(device: dict) -> dict:
    return {key: device[key] for key in ("id", "name", "created", "last_seen", "revoked")}


def _valid(device) -> bool:
    return (
        isinstance(device, dict)
        and isinstance(device.get("id"), str)
        and re.fullmatch(r"[0-9a-f]{8}", device["id"]) is not None
        and isinstance(device.get("name"), str)
        and isinstance(device.get("sha256"), str)
        and DIGEST.fullmatch(device["sha256"]) is not None
        and isinstance(device.get("created"), str)
        and STAMP.fullmatch(device["created"]) is not None
        and all(
            device.get(key) is None
            or (isinstance(device[key], str) and STAMP.fullmatch(device[key]) is not None)
            for key in ("last_seen", "revoked")
        )
    )


class DeviceStore:
    """`devices.json` (0600) next to the shared token. Writers hold `devices.lock` and replace
    the file atomically, so readers never need the lock."""

    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.path = self.directory / FILE

    @contextlib.contextmanager
    def locked(self, blocking=True):
        private_mkdir(self.directory)
        fd = os.open(self.directory / "devices.lock", os.O_CREAT | os.O_RDWR | NOFOLLOW, 0o600)
        try:
            with locked(fd, blocking):
                yield
        finally:
            os.close(fd)

    def read(self) -> list[dict]:
        # Without O_NOFOLLOW (Windows), refuse a symlink explicitly, as the open would on POSIX.
        if not NOFOLLOW and self.path.is_symlink():
            raise ValueError("Device token file must be a regular file")
        try:
            fd = os.open(self.path, os.O_RDONLY | NOFOLLOW)
        except FileNotFoundError:
            return []
        except OSError:
            raise ValueError("Device token file must be a regular file") from None
        with os.fdopen(fd) as stream:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("Device token file must be a regular file")
            # Windows has no mode bits; the private config directory's ACL covers the file.
            if os.name == "posix" and stat.S_IMODE(info.st_mode) != 0o600:
                os.fchmod(fd, 0o600)
            try:
                data = json.loads(stream.read())
            except ValueError:
                raise ValueError("Device token file is invalid") from None
        devices = data.get("devices") if isinstance(data, dict) else None
        if not isinstance(devices, list) or not all(_valid(device) for device in devices):
            raise ValueError("Device token file is invalid")
        return devices

    def write(self, devices: list[dict]):
        temporary = self.directory / f".{FILE}.{secrets.token_hex(4)}.tmp"
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump({"version": 1, "devices": devices}, stream, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise

    def entries(self, include_revoked=False) -> list[dict]:
        return [
            public(device) for device in self.read() if include_revoked or device["revoked"] is None
        ]

    def mint(self, name) -> tuple[dict, str]:
        name = clean_name(name)
        with self.locked():
            devices = self.read()
            if any(
                device["revoked"] is None and device["name"].casefold() == name.casefold()
                for device in devices
            ):
                raise ValueError("A device with that name is already paired; revoke it first")
            taken = {device["id"] for device in devices}
            while (ident := secrets.token_hex(4)) in taken:
                pass
            token = secrets.token_urlsafe(32)
            device = {
                "id": ident,
                "name": name,
                "sha256": digest(token).hex(),
                "created": now(),
                "last_seen": None,
                "revoked": None,
            }
            self.write([*devices, device])
        return public(device), token

    def revoke(self, key: str) -> dict:
        key = key.strip()
        with self.locked():
            devices = self.read()
            active = [device for device in devices if device["revoked"] is None]
            matches = [device for device in active if device["id"] == key] or [
                device for device in active if device["name"].casefold() == key.casefold()
            ]
            if not matches:
                raise LookupError("No paired device has that name or id")
            device = matches[0]
            # The digest stays as a tombstone so the device is told it was revoked.
            device["revoked"] = now()
            self.write(devices)
        return public(device)

    def touch(self, seen: dict[str, str]):
        # Never waits on a CLI writer: contention raises BlockingIOError and the caller retries.
        with self.locked(blocking=False):
            devices = self.read()
            for device in devices:
                if device["revoked"] is None and device["id"] in seen:
                    device["last_seen"] = seen[device["id"]]
            self.write(devices)


class Credentials:
    """The shared legacy token plus device tokens. `devices.json` is re-read when it changes,
    so a revoke applies to the next request without a restart."""

    def __init__(self, legacy: str, directory: Path):
        self.legacy = encode(legacy)
        self.store = DeviceStore(directory)
        self.signature = None
        self.devices: list[tuple[bytes, str, bool, str]] = []
        self.seen: dict[str, float] = {}

    def refresh(self):
        try:
            info = os.stat(self.store.path)
            signature = (info.st_ino, info.st_mtime_ns, info.st_size)
        except FileNotFoundError:
            signature = None
        except OSError:
            signature = "unreadable"
        if signature == self.signature:
            return
        self.signature = signature
        try:
            devices = self.store.read()
        except (OSError, ValueError):
            # Fail closed for device tokens only; the shared token keeps working.
            log.warning("Device token file unreadable; only the shared token is accepted")
            devices = []
        self.devices = [
            (
                bytes.fromhex(device["sha256"]),
                device["id"],
                device["revoked"] is not None,
                device["name"],
            )
            for device in devices
        ]

    def match(self, value: str):
        """(id, revoked) for a device token, comparing against every digest in constant time."""
        self.refresh()
        presented = digest(value)
        found = None
        for stored, ident, revoked, _ in self.devices:
            if secrets.compare_digest(stored, presented) and found is None:
                found = (ident, revoked)
        return found

    def name(self, value) -> str | None:
        """The name an active device token was paired under; None for anything else."""
        if not isinstance(value, str) or not (found := self.match(value)) or found[1]:
            return None
        return next((name for _, ident, _, name in self.devices if ident == found[0]), None)

    def check(self, value) -> bool:
        if not isinstance(value, str):
            return False
        legacy = secrets.compare_digest(self.legacy, encode(value))
        found = self.match(value)
        if legacy:
            return True
        if found is None or found[1]:
            return False
        self.saw(found[0])
        return True

    def source(self, value, scope) -> tuple:
        """Who an authorized request is, for the activity list: ("device", id), ("local",) for
        the shared token used directly on this machine, else ("shared",)."""
        found = self.match(value) if isinstance(value, str) else None
        if found is not None and not found[1] and not self.is_legacy(value):
            return ("device", found[0])
        return ("local", None) if direct_loopback(scope) else ("shared", None)

    def is_legacy(self, value) -> bool:
        return isinstance(value, str) and secrets.compare_digest(self.legacy, encode(value))

    def refusal(self, value) -> tuple:
        """(reason, device id) for a refused credential: counted per revoked device, otherwise
        only as unknown or missing."""
        if not isinstance(value, str) or not value:
            return ("no_token", None)
        found = self.match(value)
        if found is not None and found[1]:
            return ("revoked", found[0])
        return ("unknown_token", None)

    def roster(self) -> dict:
        """Device id -> (current name, revoked) for every device ever paired."""
        self.refresh()
        return {ident: (name, revoked) for _, ident, revoked, name in self.devices}

    def revoked(self, value) -> bool:
        return isinstance(value, str) and bool((found := self.match(value)) and found[1])

    def saw(self, ident: str):
        moment = time.monotonic()
        if moment - self.seen.get(ident, -math.inf) < SEEN_INTERVAL:
            return
        self.seen[ident] = moment
        try:
            self.store.touch({ident: now()})
        except (OSError, ValueError):
            self.seen.pop(ident, None)
