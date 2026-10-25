#!/usr/bin/env python3
"""Real GTK text field + XTest input under Xvfb. Synthetic text is never printed."""
import os
import ctypes
import select
import subprocess
import threading
import time

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

BINARY = os.environ.get("CHIRP_PLATFORM_SMOKE", "/cargo-target/debug/examples/platform-smoke")
TEXT = "Chirp Linux — café, 日本語.\nA second line; $(literal) `literal`."
window = Gtk.Window(title="Chirp Linux insertion test")
view = Gtk.TextView()
window.add(view)
window.set_default_size(600, 200)
window.show_all()
view.grab_focus()
errors = []


def line(process):
    assert select.select([process.stdout], [], [], 5)[0], "hotkey observer timed out"
    return process.stdout.readline().decode().strip()


x11 = ctypes.CDLL("libX11.so.6")
xtest = ctypes.CDLL("libXtst.so.6")
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
x11.XStringToKeysym.restype = ctypes.c_ulong
x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
x11.XKeysymToKeycode.restype = ctypes.c_ubyte
x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
xtest.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
display = x11.XOpenDisplay(None)
assert display, "X11 display unavailable"


def key(action, name):
    code = x11.XKeysymToKeycode(display, x11.XStringToKeysym(name.encode()))
    assert code, "XTest key unavailable"
    assert xtest.XTestFakeKeyEvent(display, code, action == "keydown", 0)
    x11.XSync(display, False)
    time.sleep(0.08)


def check():
    try:
        windows = subprocess.check_output(["xdotool", "search", "--name", "Chirp Linux insertion test"], text=True).split()
        subprocess.run(["xdotool", "windowfocus", "--sync", windows[-1]], check=True)
        result = subprocess.run([BINARY, "insert"], input=TEXT, text=True, capture_output=True, check=True)
        assert result.stdout.strip() == '"typed"', "native insertion fell back"
        # The GTK loop needs to consume all XTest events before checking text.
        checked = threading.Event()
        deadline = time.monotonic() + 3
        def verify_text():
            buffer = view.get_buffer()
            actual = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True)
            if actual != TEXT:
                if time.monotonic() < deadline:
                    return True
                index = next((i for i, pair in enumerate(zip(actual, TEXT)) if pair[0] != pair[1]), min(len(actual), len(TEXT)))
                errors.append(f"inserted text differed: actual_chars={len(actual)} expected_chars={len(TEXT)} first_difference={index} actual_codepoints={[ord(c) for c in actual[index:index+4]]} expected_codepoints={[ord(c) for c in TEXT[index:index+4]]}")
            checked.set()
            return False
        GLib.timeout_add(25, verify_text)
        assert checked.wait(4), "GTK did not consume insertion events"
        assert not errors
        for layout, expected in [("us", "RightAlt"), ("de", "RightCtrl")]:
            subprocess.run(["setxkbmap", "-layout", layout], check=True)
            actual = subprocess.check_output([BINARY, "default-key"], text=True).strip()
            assert actual == expected, f"layout detection differed: layout={layout} actual={actual} expected={expected}"
        subprocess.run(["setxkbmap", "-layout", "us"], check=True)
        process = subprocess.Popen([BINARY, "hotkey"], stdout=subprocess.PIPE, bufsize=0)
        try:
            def expect(expected):
                probes = []
                while True:
                    try:
                        actual = line(process)
                    except AssertionError:
                        raise AssertionError(f"waiting for {expected}; selected-modifier probes={probes}") from None
                    if actual.startswith("probe "):
                        probes.append(actual)
                        continue
                    assert actual == expected, f"hotkey action differed: actual={actual} expected={expected} probes={probes}"
                    break
            expect("ready")
            key("keydown", "Control_R"); expect("Start")
            key("keyup", "Control_R"); expect("Stop")
            key("keydown", "Control_R"); expect("Start")
            key("keydown", "a"); expect("Cancel")
            key("keyup", "a"); key("keyup", "Control_R")
        finally:
            process.terminate(); process.wait(timeout=5)
        print("X11: Unicode/multiline insertion and modifier hold/chord cancellation passed")
    except BaseException as error:
        errors.append(f"{type(error).__name__}: {error}")
    finally:
        GLib.idle_add(Gtk.main_quit)


GLib.timeout_add(300, lambda: (threading.Thread(target=check, daemon=True).start(), False)[1])
GLib.timeout_add_seconds(20, lambda: (errors.append("timeout"), Gtk.main_quit(), False)[2])
Gtk.main()
assert not errors, "X11 smoke failed: " + ", ".join(errors)
