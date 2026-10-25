"""Portable locks and owner-only files. The SDDL rules are pure and run on every host; the real
ACL round trip runs on Windows only."""

import os
import stat
import sys
import threading

import pytest

from chirp_server import fsutil
from chirp_server.config import load_token

USER = "S-1-5-21-1111111111-2222222222-3333333333-1001"


def test_private_sddl_grants_only_the_user_and_system():
    assert fsutil.private_sddl(USER, directory=False) == f"D:P(A;;FA;;;{USER})(A;;FA;;;SY)"
    # Directory ACEs are inherited by the files created inside.
    assert fsutil.private_sddl(USER, directory=True) == (f"D:P(A;OICI;FA;;;{USER})(A;OICI;FA;;;SY)")
    assert fsutil.sddl_is_private(fsutil.private_sddl(USER, directory=True), USER)


@pytest.mark.parametrize(
    ("sddl", "private"),
    [
        (f"D:P(A;;FA;;;{USER})(A;;FA;;;SY)", True),
        (f"D:AI(A;ID;FA;;;{USER})(A;ID;FA;;;SY)(A;ID;FA;;;BA)", True),
        ("D:P", True),
        (f"D:P(A;;FA;;;{USER})(A;;FR;;;BU)", False),
        (f"D:P(A;;FA;;;{USER})(A;;0x1200a9;;;WD)", False),
        (f"D:(A;;FA;;;{USER})(A;;FA;;;S-1-5-21-1111111111-2222222222-3333333333-1002)", False),
        (f"D:P(D;;FA;;;WD)(A;;FA;;;{USER})", True),
        # The built-in Administrator's SID is printed as the alias LA.
        ("D:PAI(A;;FA;;;LA)(A;;FA;;;SY)", False),
        ("D:NO_ACCESS_CONTROL", False),
        ("O:BAG:SY", False),
    ],
)
def test_sddl_is_private(sddl, private):
    assert fsutil.sddl_is_private(sddl, USER) is private


def test_sddl_accepts_every_form_of_the_user():
    assert fsutil.sddl_is_private("D:PAI(A;;FA;;;LA)(A;;FA;;;SY)", {USER, "LA"})
    assert not fsutil.sddl_is_private("D:PAI(A;;FA;;;LA)(A;;FA;;;BU)", {USER, "LA"})


def test_lock_excludes_a_second_holder(tmp_path):
    path = tmp_path / "x.lock"
    first = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    second = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        with fsutil.locked(first):
            with pytest.raises(BlockingIOError), fsutil.locked(second, blocking=False):
                pass
        with fsutil.locked(second, blocking=False):
            pass
    finally:
        os.close(first)
        os.close(second)


def test_blocking_lock_waits_for_the_holder(tmp_path):
    path = tmp_path / "x.lock"
    first = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    second = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    order = []
    held = threading.Event()

    def holder():
        with fsutil.locked(first):
            held.set()
            threading.Event().wait(0.2)
            order.append("released")

    thread = threading.Thread(target=holder)
    thread.start()
    held.wait(5)
    try:
        with fsutil.locked(second):
            order.append("acquired")
    finally:
        thread.join()
        os.close(first)
        os.close(second)
    assert order == ["released", "acquired"]


def test_private_mkdir_and_token_are_owner_only(tmp_path):
    directory = fsutil.private_mkdir(tmp_path / "a/config")
    token = load_token(directory)
    assert token and fsutil.is_private(directory / "token")
    assert fsutil.is_private(directory)
    if os.name == "posix":
        assert stat.S_IMODE((directory / "token").stat().st_mode) == 0o600
        assert stat.S_IMODE(directory.stat().st_mode) == 0o700


@pytest.mark.skipif(sys.platform != "win32", reason="Windows ACLs")
def test_windows_acl_round_trip(tmp_path):
    from chirp_server import _win_acl

    path = tmp_path / "secret"
    path.write_text("x")
    # A fresh file under the temp directory inherits a broader DACL than owner-only.
    fsutil.make_private(path)
    sddl = _win_acl.get_dacl(str(path))
    assert sddl.startswith("D:P")
    assert any(form in sddl for form in _win_acl.user_sid_forms())
    assert fsutil.is_private(path)
    # A file created inside a private directory inherits owner-only access.
    directory = fsutil.private_mkdir(tmp_path / "private")
    (directory / "child").write_text("y")
    assert fsutil.is_private(directory / "child")


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX modes")
def test_posix_make_private_tightens_modes(tmp_path):
    path = tmp_path / "f"
    path.write_text("x")
    path.chmod(0o644)
    assert not fsutil.is_private(path)
    fsutil.make_private(path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
