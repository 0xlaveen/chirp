#!/usr/bin/env python3
"""TalkBack checks on the release APK installed by emulator-smoke.sh; emulator only."""
from pathlib import Path
import runpy
import shlex
import re
import time

m = runpy.run_path(str(Path(__file__).with_name('emulator-smoke.py')))
adb, nodes, wait_for = m['adb'], m['nodes'], m['wait_for']
TALKBACK = 'com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService'


def probe(action, label):
    adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy', action, shlex.quote(label))


def main():
    originals = {key: adb('shell', 'settings', 'get', 'secure', key).decode().strip()
                 for key in ('enabled_accessibility_services', 'accessibility_enabled')}
    notifications_granted = bool(re.search(rb'android.permission.POST_NOTIFICATIONS: granted=true', adb('shell', 'dumpsys', 'package', 'com.google.android.marvin.talkback')))
    try:
        if m['find']('Don’t allow') is not None:
            probe('click', 'Don’t allow')
        adb('logcat', '-b', 'crash', '-c')
        m['fresh_editor']()
        # Stock uiautomator suppresses/restarts existing services. Run its dump before
        # enabling TalkBack; the preserving all-window probe handles the actual checks.
        adb('shell', 'uiautomator', 'dump', '/sdcard/chirp-talkback.xml')
        adb('shell', 'pm', 'grant', 'com.google.android.marvin.talkback', 'android.permission.POST_NOTIFICATIONS')
        previous = originals['enabled_accessibility_services']
        services = previous.split(':') if previous not in ('null', '') else []
        if TALKBACK not in services:
            services.append(TALKBACK)
        adb('shell', 'settings', 'put', 'secure', 'enabled_accessibility_services', ':'.join(services))
        adb('shell', 'settings', 'put', 'secure', 'accessibility_enabled', '1')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            state = adb('shell', 'dumpsys', 'accessibility')
            if b'touchExplorationEnabled=true' in state:
                break
        else:
            raise AssertionError('TalkBack touch exploration did not start')
        if m['find']('Don’t allow') is not None:
            probe('click', 'Don’t allow')
        mic = wait_for('Microphone: tap to dictate')
        assert mic.get('long-clickable') == 'true', 'Mic options not exposed to TalkBack'
        # Native accessibility actions exercise the same click/long-click a screen reader invokes.
        probe('click', 'Microphone: tap to dictate')
        wait_for('Pair your Mac in Chirp setup. Pair Mac')
        wait_for('Cancel dictation')
        probe('click', 'Cancel dictation')
        probe('long-click', 'Microphone: tap to dictate')
        wait_for('Chirp settings')
        adb('shell', 'input', 'keyevent', '4')
        m['crash_check']()
        m['screenshot']('talkback')
        print('PASS: release TalkBack enabled; stock uiautomator dump; all-window mic/status/cancel labels; mic accessibility click and long-click options; no Chirp crash.')
    finally:
        for key, value in originals.items():
            if value == 'null':
                adb('shell', 'settings', 'delete', 'secure', key)
            else:
                adb('shell', 'settings', 'put', 'secure', key, value)
        if not notifications_granted:
            adb('shell', 'pm', 'revoke', 'com.google.android.marvin.talkback', 'android.permission.POST_NOTIFICATIONS')
        adb('shell', 'rm', '-f', '/sdcard/chirp-talkback.xml', '/sdcard/chirp-windows.xml', '/data/local/tmp/chirp-ui-probe.jar')


if __name__ == '__main__':
    main()
