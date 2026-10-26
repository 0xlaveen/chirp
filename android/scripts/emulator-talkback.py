#!/usr/bin/env python3
"""TalkBack checks on the release APK installed by emulator-smoke.sh; emulator only."""
from pathlib import Path
import runpy
import shlex
import re
import time
import sys

m = runpy.run_path(str(Path(__file__).with_name('emulator-smoke.py')))
adb, nodes, wait_for = m['adb'], m['nodes'], m['wait_for']
TALKBACK = 'com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService'


def probe(action, label):
    adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy', action, shlex.quote(label))


def choice_cards():
    adb('shell', 'pm', 'clear', m['PACKAGE'])
    adb('shell', 'ime', 'set', 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME')
    adb('shell', 'ime', 'disable', m['IME'])
    adb('shell', 'am', 'start', '-n', m['PACKAGE'] + '/.SetupActivity')
    wait_for('Get started'); probe('click', 'Get started')
    wait_for('How you’ll dictate')
    radios = [node for node in nodes() if node.get('class') == 'android.widget.RadioButton']
    assert len(radios) == 2, 'Choice cards must each expose a radio role'
    assert all(node.get('checked') == 'false' for node in radios), 'Choice must begin with no selection'
    probe('click', 'Keep Gboard')
    radios = [node for node in nodes() if node.get('class') == 'android.widget.RadioButton']
    assert sum(node.get('checked') == 'true' for node in radios) == 1
    assert any('Keep Gboard' in node.get('text', '') and 'Needs an Accessibility permission' in node.get('text', '') for node in radios)
    m['screenshot']('keepkb-talkback-choice')
    probe('click', 'Continue')
    wait_for('Turn on the floating mic')
    m['crash_check']()
    print('PASS: actual TalkBack; choice cards expose radio role, full text, unchecked/checked states and click action; floating-mic disclosure reached.')


def bubble_actions():
    """#167: the floating mic bubble under real TalkBack: its label, double tap and both custom actions."""
    bubble = 'Chirp microphone'
    def custom(action):
        adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy',
            'custom-action', shlex.quote(bubble), shlex.quote(action))
    # The smoke's own editor (Notes → Dictate → Scratchpad), then Gboard so the floating mic shows instead of Chirp's keyboard.
    m['fresh_editor']()
    adb('shell', 'ime', 'set', 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME')
    probe('click', 'Dictate, then edit here')
    node = wait_for(bubble)
    assert node.get('content-desc') == 'Chirp microphone: tap to dictate, hold to talk', 'Bubble label changed'
    assert node.get('actions') == 'Move to other side|Hide in this app', 'Bubble custom actions missing'
    def cx(n):
        x1, _, x2, _ = map(int, re.findall(r'\d+', n.get('bounds')))
        return (x1 + x2) // 2
    width = m['size']()[0]
    x = cx(node)
    custom('Move to other side')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        moved = m['find'](bubble)
        if moved is not None and (cx(moved) < width // 2) != (x < width // 2):
            break
    else:
        raise AssertionError('Move to other side did not move the bubble')
    custom('Move to other side')
    # Double tap is a click: the release build is unpaired, so the panel opens on its one fix.
    probe('click', bubble)
    wait_for('Pair your computer to dictate'); wait_for('Pair computer')
    m['screenshot']('talkback-floating-error')
    probe('click', 'Hide panel')
    probe('click', 'Dictate, then edit here')
    wait_for(bubble)
    custom('Hide in this app')
    deadline = time.monotonic() + 10
    while m['find'](bubble) is not None:
        assert time.monotonic() < deadline, 'Hide in this app left the bubble up'
    m['crash_check']()
    print('PASS: actual TalkBack; floating mic bubble label, double tap to its one-fix panel, Move to other side and Hide in this app.')


def quickdictate_actions():
    """The release sheet's single fix and cancellation, then the Share dialog, with real TalkBack bound."""
    package = m['PACKAGE']
    adb('shell', 'pm', 'grant', package, 'android.permission.RECORD_AUDIO')
    adb('shell', 'am', 'start', '-n', package + '/.QuickDictateActivity')
    wait_for('Quick dictate'); wait_for('Pair computer'); wait_for('Cancel')
    probe('click', 'Cancel')
    adb('shell', 'am', 'start', '-a', 'android.intent.action.SEND', '-t', 'text/plain',
        '--es', 'android.intent.extra.TEXT', shlex.quote('Synthetic share for accessibility review'), '-n', package + '/.ShareToNotesActivity')
    wait_for('Save to Notes'); wait_for('Save as new note'); wait_for('Cancel')
    m['screenshot']('quickdictate-talkback-share')
    probe('click', 'Cancel')
    m['crash_check']()
    print('PASS: actual TalkBack; Quick dictate title, one Pair computer fix and Cancel; Share title, Save as new note and Cancel; no crash.')


def main():
    originals = {key: adb('shell', 'settings', 'get', 'secure', key).decode().strip()
                 for key in ('enabled_accessibility_services', 'accessibility_enabled', 'default_input_method')}
    notifications_granted = bool(re.search(rb'android.permission.POST_NOTIFICATIONS: granted=true', adb('shell', 'dumpsys', 'package', 'com.google.android.marvin.talkback')))
    try:
        if m['find']('Don’t allow') is not None:
            probe('click', 'Don’t allow')
        adb('logcat', '-b', 'crash', '-c')
        if not any(flag in sys.argv for flag in ('--keepkb-check', '--bubble-check', '--quickdictate-check')):
            m['fresh_editor']()
        # Stock uiautomator suppresses/restarts existing services. Run its dump before
        # enabling TalkBack; the preserving all-window probe handles the actual checks.
        adb('shell', 'uiautomator', 'dump', '/sdcard/chirp-talkback.xml')
        adb('shell', 'pm', 'grant', 'com.google.android.marvin.talkback', 'android.permission.POST_NOTIFICATIONS')
        previous = originals['enabled_accessibility_services']
        services = previous.split(':') if previous not in ('null', '') else []
        if TALKBACK not in services:
            services.append(TALKBACK)
        if '--bubble-check' in sys.argv:
            # The floating mic beside TalkBack, with another keyboard selected so the bubble shows.
            adb('shell', 'ime', 'set', 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME')
            if m['PACKAGE'] + '/.ChirpAccessibilityService' not in services:
                services.append(m['PACKAGE'] + '/.ChirpAccessibilityService')
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
        if '--keepkb-check' in sys.argv:
            choice_cards()
            return
        if '--bubble-check' in sys.argv:
            bubble_actions()
            return
        if '--quickdictate-check' in sys.argv:
            quickdictate_actions()
            return
        mic = wait_for('Microphone: tap to dictate')
        assert mic.get('clickable') == 'true', 'Mic start/stop not exposed to TalkBack'
        wait_for('Dictation options')
        # Native accessibility actions exercise the same click a screen reader invokes on the mic and on the ⋯ options button.
        probe('click', 'Microphone: tap to dictate')
        wait_for('Pair your computer in Chirp settings. Pair computer')
        wait_for('Cancel dictation')
        probe('click', 'Cancel dictation')
        probe('click', 'Dictation options')
        wait_for('Chirp settings')
        adb('shell', 'input', 'keyevent', '4')
        m['crash_check']()
        m['screenshot']('talkback')
        print('PASS: release TalkBack enabled; stock uiautomator dump; all-window mic/status/cancel labels; mic accessibility click and ⋯ options button; no Chirp crash.')
    finally:
        for key, value in originals.items():
            if key == 'default_input_method' and value not in ('null', ''):
                adb('shell', 'ime', 'set', value)
            elif value == 'null':
                adb('shell', 'settings', 'delete', 'secure', key)
            else:
                adb('shell', 'settings', 'put', 'secure', key, value)
        if not notifications_granted:
            adb('shell', 'pm', 'revoke', 'com.google.android.marvin.talkback', 'android.permission.POST_NOTIFICATIONS')
        adb('shell', 'rm', '-f', '/sdcard/chirp-talkback.xml', '/sdcard/chirp-windows.xml', '/data/local/tmp/chirp-ui-probe.jar')


if __name__ == '__main__':
    main()
