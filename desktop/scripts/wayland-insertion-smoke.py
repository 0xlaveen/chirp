#!/usr/bin/env python3
"""A real GTK Wayland field under headless Sway, plus wl-copy fallback. No /dev/input."""
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

BINARY = os.path.abspath(os.environ.get("CHIRP_PLATFORM_SMOKE", "/cargo-target/debug/examples/platform-smoke"))
TEXT = "Chirp Wayland — café, 日本語.\nA second line."
work = Path(tempfile.mkdtemp(prefix="chirp-wayland-"))
print(f"Wayland evidence: {work}", flush=True)
runtime = work / "runtime"
runtime.mkdir(mode=0o700)
os.environ.update({"XDG_RUNTIME_DIR": str(runtime), "WLR_BACKENDS": "headless", "WLR_HEADLESS_OUTPUTS": "1", "WLR_RENDERER": "pixman", "WLR_LIBINPUT_NO_DEVICES": "1", "GDK_BACKEND": "wayland", "NO_AT_BRIDGE": "1", "LANG": "C.UTF-8"})
config = work / "sway.conf"
config.write_text("xwayland disable\noutput HEADLESS-1 resolution 1000x800\nseat seat0 fallback true\n")
log = (work / "sway.log").open("w")
sway = subprocess.Popen(["sway", "-c", str(config)], stdout=log, stderr=log)
try:
    deadline = time.monotonic() + 8
    while True:
        sockets = [path for path in runtime.glob("wayland-*") if not path.name.endswith(".lock")]
        if sockets:
            os.environ["WAYLAND_DISPLAY"] = sockets[0].name
            break
        assert sway.poll() is None and time.monotonic() < deadline, f"headless Sway did not start; evidence={work}"
        time.sleep(0.05)

    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk

    window = Gtk.Window(title="Chirp Wayland insertion test")
    view = Gtk.TextView()
    window.add(view)
    window.show_all()
    view.grab_focus()
    errors = []

    def check():
        try:
            result = subprocess.run([BINARY, "insert"], input=TEXT, text=True, capture_output=True, check=True, timeout=8)
            assert result.stdout.strip() == '"typed"', "wtype did not insert into the real Wayland field"
            checked = threading.Event()
            end = time.monotonic() + 3

            def verify():
                buffer = view.get_buffer()
                actual = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True)
                if actual != TEXT and time.monotonic() < end:
                    return True
                if actual != TEXT:
                    errors.append(f"Wayland field differed: expected_chars={len(TEXT)} actual_chars={len(actual)}")
                checked.set()
                return False

            GLib.timeout_add(25, verify)
            assert checked.wait(4) and not errors, "Wayland field did not receive the synthetic text"
            fallback = work / "fallback-bin"
            fallback.mkdir()
            disabled = fallback / "wtype"
            disabled.write_text("#!/bin/sh\nexit 1\n")
            disabled.chmod(0o755)
            result = subprocess.run([BINARY, "insert"], input=TEXT, text=True, capture_output=True, check=True, timeout=8, env={**os.environ, "PATH": str(fallback) + os.pathsep + os.environ["PATH"]})
            assert result.stdout.strip() == '"clipboard"'
            copied = subprocess.check_output(["/usr/bin/wl-paste", "--no-newline"], text=True, timeout=5)
            assert copied == TEXT, "Wayland clipboard fallback lost content"
            print("Wayland: real GTK wtype Unicode/multiline insertion and clipboard fallback passed")
        except BaseException as error:
            detail = getattr(error, "stderr", "")
            errors.append(f"{type(error).__name__}: {error}; {detail}")
            for command in [["wtype", "-"], ["wl-copy", "--type", "text/plain;charset=utf-8"]]:
                try:
                    probe = subprocess.run(command, input=TEXT, text=True, capture_output=True, timeout=3)
                    errors.append(f"helper={command[0]} exit={probe.returncode} diagnostic={probe.stderr.strip()}")
                except Exception as probe_error:
                    errors.append(type(probe_error).__name__)
        finally:
            GLib.idle_add(Gtk.main_quit)

    GLib.timeout_add(500, lambda: (threading.Thread(target=check, daemon=True).start(), False)[1])
    GLib.timeout_add_seconds(25, lambda: (errors.append("timeout"), Gtk.main_quit(), False)[2])
    Gtk.main()
    assert not errors, "Wayland insertion smoke failed: " + ", ".join(errors)
finally:
    sway.terminate()
    try:
        sway.wait(timeout=5)
    except subprocess.TimeoutExpired:
        sway.kill()
        sway.wait()
    log.close()
