"""Portable file locks and owner-only files.

POSIX uses `flock` and mode bits (0600 files, 0700 directories). Windows has neither: a lock is a
`msvcrt` byte-range lock, and "owner-only" is a protected DACL that grants full control to the
current user and SYSTEM only. A private directory's ACEs are inheritable, so files created inside
it are private too. The SDDL helpers are pure so every platform's tests cover them.
"""

import contextlib
import os
import re
import stat
import sys
import time
from pathlib import Path

# Windows has no O_NOFOLLOW; callers still reject non-regular files after fstat.
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)

# Trustees allowed on a private Windows file besides the user: SYSTEM, Administrators (like root
# on POSIX, they can always take ownership) and OWNER RIGHTS.
_TRUSTED = {"SY", "S-1-5-18", "BA", "S-1-5-32-544", "OW", "S-1-3-4"}
_ACE = re.compile(r"\(([^;()]*);[^;()]*;[^;()]*;[^;()]*;[^;()]*;([^;()]*)(?:;[^()]*)?\)")


@contextlib.contextmanager
def locked(fd: int, blocking: bool = True):
    """Hold an exclusive lock on `fd`; non-blocking contention raises BlockingIOError."""
    if sys.platform == "win32":
        import msvcrt

        while True:
            os.lseek(fd, 0, os.SEEK_SET)
            try:
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                break
            except OSError:
                if not blocking:
                    raise BlockingIOError("locked by another process") from None
                time.sleep(0.05)
        try:
            yield
        finally:
            os.lseek(fd, 0, os.SEEK_SET)
            with contextlib.suppress(OSError):
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    else:
        import fcntl

        fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)


def private_sddl(user_sid: str, directory: bool) -> str:
    """A protected DACL: full control for the user and SYSTEM, inherited by a directory's
    children."""
    flags = "OICI" if directory else ""
    return f"D:P(A;{flags};FA;;;{user_sid})(A;{flags};FA;;;SY)"


def sddl_is_private(sddl: str, user) -> bool:
    """True when no allow ACE in the DACL names anyone but the user or a trusted system SID.
    `user` is the user's SID, or every form SDDL may print it in (a well-known account such as
    the built-in Administrator appears as an alias like LA)."""
    users = {user} if isinstance(user, str) else set(user)
    dacl = sddl.partition("D:")[2].split("S:", 1)[0]
    if not sddl.count("D:") or dacl.startswith("NO_ACCESS_CONTROL"):
        return False
    return all(
        trustee in _TRUSTED or trustee in users
        for kind, trustee in _ACE.findall(dacl)
        if kind in {"A", "OA", "XA", "ZA"}
    )


def make_private(path: Path) -> None:
    """Restrict `path` to the current user (0600 files, 0700 directories on POSIX)."""
    path = Path(path)
    if sys.platform == "win32":
        _windows().set_dacl(str(path), private_sddl(_windows().user_sid(), path.is_dir()))
    else:
        path.chmod(0o700 if path.is_dir() else 0o600)


def is_private(path: Path) -> bool:
    path = Path(path)
    if sys.platform == "win32":
        windows = _windows()
        return sddl_is_private(windows.get_dacl(str(path)), windows.user_sid_forms())
    return not stat.S_IMODE(path.stat().st_mode) & 0o077


def private_mkdir(path: Path) -> Path:
    """Create `path` (and parents) if missing, owner-only. On Windows an existing directory is
    made owner-only too, because files inherit their access from it; POSIX leaves an existing
    directory's mode alone."""
    path = Path(path)
    if not path.is_dir():
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        if sys.platform == "win32":
            make_private(path)
    elif sys.platform == "win32" and not is_private(path):
        make_private(path)
    return path


def _windows():
    from . import _win_acl

    return _win_acl
