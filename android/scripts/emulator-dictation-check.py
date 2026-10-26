#!/usr/bin/env python3
"""Real IME tap/hold, composing partial/final, Ripple evidence and crash checks.
Short probe connections avoid an API 37 shell JVM being killed under virtual-key tree churn.
No killed probe is accepted; each gesture also requires the real server's final metadata.
"""
import json
import os
import shlex
import subprocess
import time


def check(p, work, output):
    adb = p['adb']

    def poll(predicate, message, seconds=70):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            result = predicate()
            if result: return result
            time.sleep(.3)
        raise AssertionError(message)

    def state():
        try: return json.loads((work / 'events.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError): return {}

    # A longer finite synthetic input leaves time for a slow all-window dump to observe
    # composition. Every run is still explicitly stopped by tap or hold release.
    adb('shell', 'am', 'force-stop', p['PACKAGE'])
    adb('shell', 'run-as', p['PACKAGE'], 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<map><boolean name="synthetic" value="true"/><int name="dictation_repeats" value="3"/></map>')
    for theme in ('light', 'dark'):
        adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
        for mode in ('tap', 'hold'):
            try:
                p['fresh_editor']()
            except AssertionError:
                # A slow cold start can expose the native field just after the shared timeout.
                # Keep waiting for that same activity rather than repeatedly killing its process.
                p['wait_for_editor'](); p['focus_editor']()
            target = p['wait_for']('Microphone: tap to dictate')
            x, y = p['center'](target)
            before = p['editor_text']()
            gesture = None
            try:
                if mode == 'hold':
                    gesture = subprocess.Popen(['adb', '-s', os.environ['ANDROID_SERIAL'], 'shell', 'input', 'swipe',
                        str(x), str(y), str(x), str(y), '15000'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    adb('shell', 'input', 'tap', str(x), str(y))
                poll(lambda: state().get('partials', 0) > 0 and p['editor_text']() != before and not state().get('retired'),
                     'No composing partial reached the native editor')
                image = adb('exec-out', 'screencap', '-p')
                (output / (theme + '-' + mode + '-listening.png')).write_bytes(image[image.index(b'\x89PNG'):])
                if gesture is not None:
                    assert gesture.wait(timeout=25) == 0, 'Hold/release gesture failed'
                else:
                    adb('shell', 'input', 'tap', str(x), str(y))
                # Tap stops explicitly; hold stops on release, while the finite synthetic input remains.
                p['wait_for']('Microphone: tap to dictate', seconds=90)
                poll(lambda: state().get('retired'), 'Server did not retire the dictation')
                final = p['editor_text']()
                assert final.strip() and final != before, 'Final was not committed'
                observed = state()
                assert observed.get('stop') and observed.get('corrected') and not observed.get('empty'), 'Real server did not clean a stopped dictation'
                p['nodes']()
                (output / (theme + '-' + mode + '-final.xml')).write_bytes(adb('shell', 'cat', '/sdcard/chirp-windows.xml'))
                print('PASS:', theme, mode, 'composing partial, stopped clean final, listening evidence', flush=True)
            finally:
                if gesture is not None and gesture.poll() is None:
                    gesture.terminate(); gesture.wait(timeout=10)
    p['crash_check']()
