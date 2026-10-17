#!/usr/bin/env python3
"""Explicitly opt-in emulator E2E; no phone, real microphone, production server or user speech.
Run with the Android toolchain sourced and the built debug APK. Requires Pillow and the
existing server venv/model paths passed on the command line. All runtime secrets/audio stay
outside git; only screenshots and a content-free result are retained.
"""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import shlex
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

SERIAL = "emulator-5580"
PACKAGE = "dev.chirp.android"
IME = PACKAGE + "/.ChirpImeService"
ROOT = Path(__file__).resolve().parents[2]


def adb(*args, capture=True, data=None):
    # Never fall back to adb's default device, regardless of caller environment.
    result = subprocess.run(["adb", "-s", SERIAL, *args], input=data, check=False,
                            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    if result.returncode:
        raise RuntimeError("ADB action failed (arguments redacted): " + args[0])
    return result.stdout


def nodes():
    for _ in range(4):
        adb("shell", "uiautomator", "dump", "/sdcard/chirp-check.xml")
        # shell cat uses the same Android shell identity/mount namespace as the dumper.
        raw = adb("shell", "cat", "/sdcard/chirp-check.xml")
        try:
            return list(ET.fromstring(raw[raw.index(b"<?xml"):]).iter("node"))
        except (ValueError, ET.ParseError):
            time.sleep(.5)
    raise RuntimeError("Emulator did not produce an XML hierarchy")


def center(node):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.attrib["bounds"]))
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def click(label):
    for _ in range(5):
        matches = [n for n in nodes() if n.get("text") == label and center(n) != (0, 0)]
        if matches:
            tap(*center(matches[-1])); time.sleep(.5); return
        adb("shell", "input", "swipe", "1100", "1800", "1100", "900", "300")
    raise RuntimeError("UI action missing: " + label)


def editor():
    return next(n for n in nodes() if n.get("class") == "android.widget.EditText")


def focus_editor():
    # Theme recreation deliberately does not save field text/focus. Reset the wizard's
    # scroll position before tapping; coordinates from an offscreen semantics node are 0,0.
    if b"mInputShown=true" in adb("shell", "dumpsys", "input_method"):
        adb("shell", "input", "keyevent", "4")
    for _ in range(3):
        adb("shell", "input", "swipe", "1100", "400", "1100", "1800", "200")
    node = editor()
    assert center(node) != (0, 0), "Test field is offscreen"
    tap(*center(node))
    time.sleep(1)


def screenshot(path):
    adb("shell", "screencap", "-p", "/sdcard/chirp-check.png")
    adb("pull", "/sdcard/chirp-check.png", str(path))


def mic_position(night, work):
    from PIL import Image
    path = work / "geometry.png"
    screenshot(path)
    im = Image.open(path).convert("RGB")
    color = (159, 211, 185) if night else (56, 106, 88)
    # First 32dp: the strip mic is the only large solid accent area on the left edge.
    x = max(24, round(im.width * 32 / (im.width / 2.4375)))
    rows = [y for y in range(70, im.height - 50) if sum(abs(im.getpixel((x, y))[c] - color[c]) for c in range(3)) < 15]
    runs = []
    for y in rows:
        if runs and y == runs[-1][-1] + 1:
            runs[-1].append(y)
        else:
            runs.append([y])
    large = [r for r in runs if len(r) > 35]
    if not large:
        screenshot(Path("/tmp/chirp-mic-missing.png"))
        raise RuntimeError("Chirp mic is not visible")
    run = max(large, key=len)
    return x, (run[0] + run[-1]) // 2, im.width, im.height


def wait_health(token, timeout=150):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request("http://127.0.0.1:7899/v1/health", headers={"Authorization": "Bearer " + token})
            with urllib.request.urlopen(req, timeout=2) as response:
                if json.load(response).get("ready"):
                    return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError("Throwaway model server did not become ready")


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--python", required=True)
    args.add_argument("--model-dir", required=True)
    args.add_argument("--apk", required=True)
    opt = args.parse_args()
    assert adb("get-serialno").strip().decode() == SERIAL
    # Refuse to disturb any service already using this test port.
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", 7899))
    output = ROOT / "docs/screenshots/android"
    with tempfile.TemporaryDirectory(prefix="chirp-emulator-") as name:
        work = Path(name)
        home = work / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), PYTHONPATH=str(ROOT / "server/src"))
        server = subprocess.Popen([opt.python, "-m", "chirp_server", "--port", "7899", "--model-dir", opt.model_dir],
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            token_path = home / ".config/chirp/token"
            for _ in range(100):
                if token_path.exists():
                    break
                if server.poll() is not None:
                    raise RuntimeError("Throwaway server exited before initialization")
                time.sleep(.1)
            token = token_path.read_text().strip()
            wait_health(token)
            # Independent host-routing probe, no authentication or private response content.
            probe = adb("shell", "sh", "-c", shlex.quote("printf 'GET /v1/health HTTP/1.0\\r\\nHost: 10.0.2.2\\r\\n\\r\\n' | toybox nc -w 3 10.0.2.2 7899"))
            print("Emulator route to throwaway server:", b"200 OK" in probe, flush=True)
            adb("install", "-r", str(Path(opt.apk).resolve()))
            adb("shell", "am", "force-stop", PACKAGE)
            adb("shell", "run-as", PACKAGE, "mkdir", "-p", "shared_prefs")
            adb("shell", "run-as", PACKAGE, "sh", "-c", shlex.quote("cat > shared_prefs/debug_capture.xml"),
                data=b'<?xml version="1.0" encoding="utf-8"?><map><boolean name="synthetic" value="true" /></map>')
            adb("shell", "pm", "grant", PACKAGE, "android.permission.RECORD_AUDIO")
            adb("shell", "pm", "grant", PACKAGE, "android.permission.ACCESS_LOCAL_NETWORK")
            adb("shell", "ime", "enable", IME)
            adb("shell", "ime", "set", IME)
            adb("shell", "settings", "put", "secure", "show_ime_with_hard_keyboard", "1")
            adb("logcat", "-b", "crash", "-c")
            # adb prints the intent URI, so output is deliberately never forwarded to logs.
            link = "chirp://pair?" + urllib.parse.urlencode({"url": "http://10.0.2.2:7899", "token": token})
            adb("shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", shlex.quote(link))
            screenshot(Path("/tmp/chirp-pairing-before.png"))
            click("Test connection & save pairing")
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if any(n.get("text") == "Mac ready" for n in nodes()):
                    break
                time.sleep(.3)
            else:
                statuses = [n.get("text", "") for n in nodes() if n.get("text", "").startswith(("Mac ", "Pairing link received", "Invalid Chirp", "Paste a valid", "Paired", "Checking Mac"))]
                screenshot(Path("/tmp/chirp-pairing-failure.png"))
                print("Pairing status:", statuses, flush=True)
                diagnostic = adb("shell", "run-as", PACKAGE, "cat", "shared_prefs/debug_capture.xml")
                for item in ET.fromstring(diagnostic):
                    if item.get("name") in ("failure_class", "cleartext_allowed"):
                        print(item.get("name"), item.text or item.get("value"), flush=True)
                raise RuntimeError("Emulator did not save pairing")
            click("Next")
            focus_editor()
            for night in (False, True):
                theme = "dark" if night else "light"
                adb("shell", "cmd", "uimode", "night", "yes" if night else "no")
                time.sleep(1)
                focus_editor()
                x, y, width, height = mic_position(night, work)
                # The strip must live in the keyboard's lower frame, leaving the editor visible.
                assert y > height // 3, "Keyboard unexpectedly fills the screen"
                screenshot(output / ("emulator-keyboard-idle-" + theme + ".png"))
                before = editor().get("text", "")
                tap(x, y)
                time.sleep(2.5)
                live = editor().get("text", "")
                screenshot(Path("/tmp/chirp-listening-check.png"))
                if live == before:
                    diagnostic = adb("shell", "run-as", PACKAGE, "cat", "shared_prefs/debug_capture.xml")
                    for item in ET.fromstring(diagnostic):
                        if item.get("name") in ("touch", "start", "synthetic"):
                            print(item.get("name"), item.text or item.get("value"), flush=True)
                    raise RuntimeError("No live composing partial reached the editor")
                screenshot(output / ("emulator-keyboard-listening-" + theme + ".png"))
                # Tap toggles stop. Wait for final; only synthetic content is inspected in memory.
                tap(x, y)
                time.sleep(3)
                final = editor().get("text", "")
                assert final and final != before, "Final was not committed"
                screenshot(output / ("emulator-keyboard-final-" + theme + ".png"))
                assert adb("shell", "settings", "get", "secure", "default_input_method").decode().strip() == IME
                # Repeat immediately: the original reported first-use behavior must not recur.
                before_repeat = editor().get("text", "")
                tap(x, y); time.sleep(1.5); tap(x, y); time.sleep(2)
                assert editor().get("text", "") != before_repeat, "Second utterance did not commit"
                assert adb("shell", "settings", "get", "secure", "default_input_method").decode().strip() == IME
                # Tap the actual QWERTY 'a' key after dictation to verify HeliBoard's
                # composing/cache handoff, rather than injecting text via adb input text.
                before_type = editor().get("text", "")
                tap(round(width * .10), round(height * .72))
                typed = editor().get("text", "")
                assert typed in (before_type + "a", before_type + "A"), "Typing after dictation failed"
                # Hold is push-to-talk; then cancel a new utterance and hide the IME.
                adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "600")
                time.sleep(2)
                before_cancel = editor().get("text", "")
                tap(x, y); time.sleep(.5); tap(width - x, y); time.sleep(.5)
                assert editor().get("text", "") == before_cancel, "Cancel changed committed text"
                adb("shell", "input", "keyevent", "4")
                time.sleep(.5)
                crash = adb("logcat", "-b", "crash", "-d").decode(errors="replace")
                assert "Process: dev.chirp.android" not in crash and ">>> dev.chirp.android <<<" not in crash, "Chirp crash recorded"
            click("Keyboard layouts & settings")
            click("Chirp setup & pairing")
            click("Diagnostics")
            click("Copy diagnostics")
            click("Close")
            print("PASS: real Parakeet server; Keystore pairing; composing partials/finals; two utterances; tap/hold/cancel/hide; typing after dictation; keyboard settings/setup/diagnostics; light/dark screenshots; IME retained; no Chirp crash.")
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
            # Disable synthetic input and remove throwaway pairing credentials; leave the emulator running.
            adb("shell", "rm", "-f", "/sdcard/chirp-check.xml", "/sdcard/chirp-check.png")
            adb("shell", "am", "force-stop", PACKAGE)
            adb("shell", "run-as", PACKAGE, "rm", "-f", "shared_prefs/debug_capture.xml", "shared_prefs/chirp.xml")
            adb("shell", "ime", "set", IME)


if __name__ == "__main__":
    main()
