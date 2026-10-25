#!/usr/bin/env python3
"""Real Tk text field + SendInput on Windows (CI's interactive desktop). Synthetic text is never
printed. Checks typed and pasted insertion, clipboard restore, the AltGr default key and that
the keyboard hook installs. The hook ignores injected input by design, so pressing the key
itself stays on the manual checklist (docs/windows.md)."""

import ctypes
import os
import subprocess
import sys
import threading
import time
import tkinter as tk
from ctypes import wintypes

BINARY = os.environ.get(
    "CHIRP_PLATFORM_SMOKE", "src-tauri/target/debug/examples/platform-smoke.exe"
)
TYPED = (
    "Chirp Windows — café, 日本語, naïve.\nA second line;\t$(literal) `literal` %PATH%."
)
PASTED = ("Long dictation is pasted, not typed. " * 70).strip()
BEFORE = "clipboard before dictation"
KLF_ACTIVATE, KLF_SETFORPROCESS = 0x1, 0x100

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.LoadKeyboardLayoutW.argtypes = [wintypes.LPCWSTR, wintypes.UINT]
user32.LoadKeyboardLayoutW.restype = wintypes.HANDLE
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.GetParent.argtypes = [wintypes.HWND]
user32.GetParent.restype = wintypes.HWND

root = tk.Tk()
root.title("Chirp Windows insertion test")
root.geometry("700x300")
root.attributes("-topmost", True)
field = tk.Text(root)
field.pack(fill="both", expand=True)
errors = []
done = threading.Event()


def on_main(function):
    """Run `function` on Tk's thread and return its result."""
    result, ready = [], threading.Event()
    root.after(0, lambda: (result.append(function()), ready.set()))
    assert ready.wait(10), "Tk did not respond"
    return result[0]


def focus():
    def bring():
        field.delete("1.0", "end")
        root.deiconify()
        root.focus_force()
        field.focus_set()
        user32.SetForegroundWindow(user32.GetParent(root.winfo_id()) or root.winfo_id())

    on_main(bring)
    time.sleep(0.5)


def wait_for(expected, what):
    deadline = time.monotonic() + 10
    actual = ""
    while time.monotonic() < deadline:
        actual = on_main(lambda: field.get("1.0", "end-1c"))
        if actual == expected:
            return
        time.sleep(0.1)
    index = next(
        (i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]),
        min(len(actual), len(expected)),
    )
    errors.append(
        f"{what}: actual_chars={len(actual)} expected_chars={len(expected)} "
        f"first_difference={index} actual={[ord(c) for c in actual[index : index + 4]]} "
        f"expected={[ord(c) for c in expected[index : index + 4]]}"
    )


def insert(text):
    result = subprocess.run(
        [BINARY, "insert"],
        input=text.encode(),
        capture_output=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, "native insertion failed"
    return result.stdout.decode().strip()


def default_key(layout):
    user32.LoadKeyboardLayoutW(layout, KLF_ACTIVATE | KLF_SETFORPROCESS)
    focus()
    return subprocess.check_output(
        [BINARY, "default-key"], text=True, timeout=30
    ).strip()


def check():
    try:
        focus()
        outcome = insert(TYPED)
        assert outcome == '"typed"', f"typing fell back: {outcome}"
        wait_for(TYPED, "typed text differed")

        def seed():
            root.clipboard_clear()
            root.clipboard_append(BEFORE)
            root.update()

        on_main(seed)
        focus()
        assert insert(PASTED) == '"typed"', "paste fell back"
        wait_for(PASTED, "pasted text differed")
        restored = on_main(lambda: root.clipboard_get())
        assert restored == BEFORE, "clipboard was not restored"

        for layout, expected in [("00000409", "RightAlt"), ("00000407", "RightCtrl")]:
            actual = default_key(layout)
            assert actual == expected, (
                f"layout {layout}: default {actual}, expected {expected}"
            )
        user32.LoadKeyboardLayoutW("00000409", KLF_ACTIVATE | KLF_SETFORPROCESS)

        hook = subprocess.Popen([BINARY, "hotkey"], stdout=subprocess.PIPE, text=True)
        try:
            assert hook.stdout.readline().strip() == "ready", (
                "keyboard hook did not install"
            )
        finally:
            hook.kill()
    except Exception as error:  # noqa: BLE001 - report every failure, then exit non-zero
        errors.append(f"{type(error).__name__}: {error}")
    finally:
        done.set()
        root.after(0, root.destroy)


threading.Thread(target=check, daemon=True).start()
root.after(120_000, root.destroy)
root.mainloop()
if errors or not done.is_set():
    print("\n".join(errors) or "smoke did not finish", file=sys.stderr)
    raise SystemExit(1)
print(
    "windows smoke passed: typed, pasted + clipboard restored, AltGr default, hook installed"
)
