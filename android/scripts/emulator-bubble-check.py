#!/usr/bin/env python3
"""Floating mic bubble (#167) on a disposable emulator, through emulator-check.py --keepkb-check or --bubble-check.

Debug APK, synthetic speech and #166's EditorProbeActivity only. Field and clipboard text is never printed or
kept: checks read lengths and states. The caller owns the throwaway server (m['stop_server'] stops it).
"""
from pathlib import Path
import re
import shlex
import time

PACKAGE = 'dev.chirp.android'
CHIRP = PACKAGE + '/.ChirpImeService'
GBOARD = 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME'
SERVICE = PACKAGE + '/.ChirpAccessibilityService'
PROBE = PACKAGE + '/.EditorProbeActivity'
BUBBLE = 'Chirp microphone'
COPY_MODE = 'Chirp microphone — this field can’t be filled automatically'


def bounds(node):
    return tuple(map(int, re.findall(r'-?\d+', node.get('bounds', ''))))


def center(node):
    x1, y1, x2, y2 = bounds(node)
    return (x1 + x2) // 2, (y1 + y2) // 2


class Bubble:
    def __init__(self, m, output):
        self.m, self.adb, self.output = m, m['adb'], output
        self.results = []

    # ---- UI helpers ------------------------------------------------------------------------------------------
    def nodes(self):
        return self.m['nodes']()

    def bubble(self, hierarchy=None):
        return next((n for n in (hierarchy or self.nodes()) if n.get('content-desc', '').startswith(BUBBLE)), None)

    def wait(self, test, what, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            hierarchy = self.nodes()
            found = test(hierarchy)
            if found:
                return found
            time.sleep(.2)
        self.capture('failure-' + re.sub(r'\W+', '-', what.lower()).strip('-'), keep=False)
        raise AssertionError('Missing state: ' + what)

    def label(self, text, seconds=30):
        return self.wait(lambda h: next((n for n in h if n.get('text') == text or n.get('content-desc', '').startswith(text)), None), text, seconds)

    def gone(self, test, what, seconds=10):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not test(self.nodes()):
                return
            time.sleep(.2)
        raise AssertionError('Still shown: ' + what)

    def tap(self, node):
        self.adb('shell', 'input', 'tap', *map(str, center(node)))

    def press(self, text):
        self.tap(self.label(text))

    def probe_field(self, label):
        """Opens the probe and focuses one of its fields by tapping it, like a person would."""
        self.adb('shell', 'am', 'start', '-W', '-n', PROBE)
        self.label('Probe ready')
        field = self.label(label)
        self.tap(field)
        return field

    def field_state(self, label):
        node = next((n for n in self.nodes() if n.get('content-desc') == label or n.get('text') == label or
                     (n.get('class', '').endswith('EditText') and label in n.get('content-desc', ''))), None)
        assert node is not None, 'Field missing: ' + label
        return len(node.get('text', '')), node.get('selection', '')

    def plain_length(self):
        editors = [n for n in self.nodes() if n.get('class') == 'android.widget.EditText' and n.get('package') == PACKAGE]
        assert editors, 'Probe editor missing'
        node = editors[0]
        hint = node.get('text', '') == 'Plain field'
        return 0 if hint else len(node.get('text', '')), node.get('selection', '')

    def no_microphone_service(self, where):
        services = self.adb('shell', 'dumpsys', 'activity', 'services', PACKAGE)
        assert b'isForeground=true' not in services, 'Foreground service still running: ' + where
        audio = self.adb('shell', 'dumpsys', 'audio')
        recording = audio.split(b'RecordActivityMonitor', 1)[-1].split(b'\n\n', 1)[0]
        assert PACKAGE.encode() not in recording, 'Recording client still open: ' + where
        assert not self.adb('logcat', '-b', 'crash', '-d').strip(), 'Chirp crash: ' + where

    def capture(self, name, keep=True):
        data = self.adb('exec-out', 'screencap', '-p')
        target = (self.output / ('emulator-floating-' + name + '.png')) if keep else Path('/tmp/chirp-bubble-' + name + '.png')
        target.write_bytes(data[data.index(b'\x89PNG'):])
        assert target.stat().st_size < 2_000_000, 'Screenshot over 2 MB'

    def dictate(self, field_label, stop=True):
        """Tap the bubble, wait for a non-empty partial (length only), optionally Stop."""
        self.tap(self.wait(self.bubble, 'bubble'))
        self.label('Listening', 40)
        self.wait(lambda h: any(n.get('content-desc', '') == '' and n.get('text', '') not in ('', 'Start speaking…', 'Listening', 'Cancel', 'Stop')
                                and n.get('package') == PACKAGE and n.get('class') == 'android.widget.TextView'
                                and bounds(n)[1] > 0 for n in h), 'partial', 40)
        if stop:
            self.press('Stop dictation')

    # ---- Cases ----------------------------------------------------------------------------------------------
    def show_and_hide(self):
        self.probe_field('Plain field')
        self.wait(self.bubble, 'bubble on plain field')
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        self.gone(self.bubble, 'bubble after Home')
        self.probe_field('Password field')
        time.sleep(1.5)
        assert self.bubble() is None, 'Bubble shown on a password field'
        self.no_microphone_service('show/hide')
        self.results.append('show/hide (plain, Home, password)')

    def drag(self):
        self.probe_field('Plain field')
        start = self.wait(self.bubble, 'bubble')
        width, height = self.m['size']()
        x, y = center(start)
        assert x > width // 2, 'Default bubble should be on the right edge'
        # A slow swipe: well past the 8 dp slop before 250 ms, released at a third of the width.
        self.adb('shell', 'input', 'swipe', str(x), str(y), str(width // 3), str(y + 120), '700')
        self.no_microphone_service('during drag')
        moved = self.wait(lambda h: (b := self.bubble(h)) is not None and center(b)[0] < width // 2 and b, 'bubble at left edge')
        assert bounds(moved)[0] <= 8, 'Bubble did not snap to the left edge'
        self.no_microphone_service('after drag')
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        self.probe_field('Plain field')
        kept = self.wait(self.bubble, 'bubble after refocus')
        assert center(kept)[0] < width // 2, 'Dropped position did not persist'
        # The other screen posture keeps its own spot: unfold to the inner size and back.
        original = self.adb('shell', 'wm', 'size').decode()
        try:
            self.adb('shell', 'wm', 'size', '1080x2092' if width > 1500 else '2208x1840')
            time.sleep(2)
            self.probe_field('Plain field')
            other = self.wait(self.bubble, 'bubble on the other posture')
            other_width = self.m['size']()[0]
            assert center(other)[0] > other_width // 2, 'Other posture should keep its own (default right) spot'
            self.capture('other-posture', keep=False)
        finally:
            override = re.search(r'Override size: (\S+)', original)
            self.adb('shell', 'wm', 'size', override.group(1) if override else 'reset')
            time.sleep(2)
        self.probe_field('Plain field')
        back = self.wait(self.bubble, 'bubble back on the first posture')
        assert center(back)[0] < self.m['size']()[0] // 2, 'First posture lost its spot'
        # Put it back on the right for the remaining cases.
        bx, by = center(back)
        self.adb('shell', 'input', 'swipe', str(bx), str(by), str(self.m['size']()[0] * 3 // 4), str(by), '700')
        self.wait(lambda h: (b := self.bubble(h)) is not None and center(b)[0] > self.m['size']()[0] // 2, 'bubble back right')
        self.results.append('drag: no FGS/recording, snap, persisted, separate posture')

    def dictate_insert(self, cleanup_warm):
        self.probe_field('Plain field')
        before, _ = self.plain_length()
        self.dictate('Plain field')
        self.wait(lambda h: any(n.get('text') in ('Inserted',) for n in h), 'Inserted', 60)
        after, selection = self.plain_length()
        assert after > before, 'Field did not grow'
        assert selection == f'{after},{after}', 'Caret not at the end of the insertion'
        if self.m['find']('Use raw') is not None:
            self.capture('polished')
            self.press('Use raw')
            time.sleep(1)
            raw, _ = self.plain_length()
            assert raw != after, 'Use raw changed nothing'
            self.results.append('Use raw replaced the polished text')
        elif cleanup_warm:
            self.results.append('Use raw not offered (clean-up returned the same text)')
        self.no_microphone_service('after insert')
        # A second polished insert: Use raw goes away by itself after 5 s.
        if cleanup_warm:
            self.dictate('Plain field')
            if self.wait(lambda h: any(n.get('text') == 'Inserted' for n in h), 'Inserted', 60) and self.m['find']('Use raw') is not None:
                time.sleep(5.5)
                assert self.m['find']('Use raw') is None, 'Use raw outlived 5 s'
                self.results.append('Use raw expired after 5 s')
        self.results.append('dictate: Listening, partial, inserted at caret')

    def field_changed(self):
        self.probe_field('Plain field')
        self.dictate('Plain field', stop=False)
        self.press('Stop dictation')
        self.adb('shell', 'input', 'text', 'x')
        self.label('Couldn’t put this in the field', 60)
        self.capture('ready')
        self.press('Copy')
        self.gone(lambda h: any(n.get('text') == 'Couldn’t put this in the field' for n in h), 'Ready to copy panel')
        self.press('Paste and report length')
        report = self.label('Paste length=')
        text = report.get('text') or report.get('content-desc')
        length = int(re.search(r'Paste length=(\d+)', text).group(1))
        assert length > 0 and 'sensitive=true' in text, 'Copy did not leave a sensitive clip'
        self.no_microphone_service('field changed')
        self.results.append('field changed while finishing → Ready to copy; Copy → sensitive clip')

    def copy_mode(self):
        self.probe_field('Editable without set text')
        self.wait(lambda h: (b := self.bubble(h)) is not None and b.get('content-desc', '').startswith(COPY_MODE) and b, 'copy-mode badge')
        self.capture('copy-mode-bubble')
        self.dictate('Editable without set text')
        self.label('This field can’t be filled automatically', 60)
        self.press('Open in Scratchpad')
        self.wait(lambda h: any(n.get('package') == PACKAGE and n.get('class') == 'android.widget.EditText' and n.get('text', '') not in ('', 'Dictate, then edit here') for n in h),
                  'Scratchpad with the words', 20)
        self.no_microphone_service('copy mode')
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        self.results.append('copy mode badge → Ready to copy → Scratchpad has the words')

    def web_field(self):
        self.probe_field('Web field')
        self.dictate('Web field')
        state = self.wait(lambda h: next((n.get('text') for n in h if n.get('text') in ('Inserted', 'Couldn’t put this in the field', 'This field can’t be filled automatically')), None),
                          'WebView outcome', 60)
        self.results.append('WebView textarea → ' + ('inserted' if state == 'Inserted' else 'Ready to copy'))
        if state != 'Inserted':
            self.press('Done')
        self.no_microphone_service('web field')

    def errors(self):
        self.adb('shell', 'pm', 'revoke', PACKAGE, 'android.permission.RECORD_AUDIO')
        try:
            time.sleep(2)  # Revoking restarts the process; the service rebinds.
            self.probe_field('Plain field')
            self.tap(self.wait(self.bubble, 'bubble after revoke', 40))
            self.label('Allow the microphone for Chirp')
            assert self.m['find']('Allow') is not None
            self.capture('error-microphone', keep=False)
            self.press('Hide panel')
        finally:
            self.adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.RECORD_AUDIO')
        self.m['stop_server']()
        time.sleep(1)
        self.probe_field('Plain field')
        self.tap(self.wait(self.bubble, 'bubble with the Mac offline', 40))
        self.label('Check again', 40)
        self.capture('error-offline')
        self.press('Hide panel')
        self.no_microphone_service('errors')
        self.results.append('errors: Allow (mic revoked), Check again (server stopped)')

    def captures(self):
        """Idle and listening in light and dark, on the inner screen and the cover size."""
        original = self.adb('shell', 'wm', 'size').decode()
        try:
            for screen, size in (('inner', None), ('cover', '1080x2092')):
                if size:
                    self.adb('shell', 'wm', 'size', size); time.sleep(2)
                for night in ('no', 'yes'):
                    self.adb('shell', 'cmd', 'uimode', 'night', night); time.sleep(1.5)
                    theme = 'dark' if night == 'yes' else 'light'
                    self.probe_field('Plain field')
                    self.wait(self.bubble, 'bubble'); time.sleep(.6)
                    self.capture(f'idle-{screen}-{theme}')
                    self.dictate('Plain field', stop=False)
                    self.capture(f'listening-{screen}-{theme}')
                    self.press('Stop dictation')
                    self.wait(lambda h: any(n.get('text') in ('Inserted', 'Couldn’t put this in the field') for n in h), 'end', 60)
                    if self.m['find']('Done') is not None:
                        self.press('Done')
                    self.no_microphone_service('captures')
        finally:
            self.adb('shell', 'cmd', 'uimode', 'night', 'no')
            override = re.search(r'Override size: (\S+)', original)
            self.adb('shell', 'wm', 'size', override.group(1) if override else 'reset')
        self.results.append('captures: idle and listening, inner and cover, light and dark')

    def talkback_labels(self):
        """The bubble's TalkBack contract without TalkBack running: a button with both custom actions."""
        self.probe_field('Plain field')
        node = self.wait(self.bubble, 'bubble')
        assert node.get('clickable') == 'true'
        assert node.get('actions') == 'Move to other side|Hide in this app', 'Bubble custom actions missing'
        x = center(node)[0]
        self.adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy',
                 'custom-action', shlex.quote(BUBBLE), shlex.quote('Move to other side'))
        width = self.m['size']()[0]
        self.wait(lambda h: (b := self.bubble(h)) is not None and (center(b)[0] < width // 2) != (x < width // 2), 'moved to other side')
        self.adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy',
                 'custom-action', shlex.quote(BUBBLE), shlex.quote('Move to other side'))
        self.adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/', 'dev.chirp.smoke.UiHierarchy',
                 'custom-action', shlex.quote(BUBBLE), shlex.quote('Hide in this app'))
        self.gone(self.bubble, 'bubble after Hide in this app')
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        self.probe_field('Plain field')
        self.wait(self.bubble, 'bubble back after leaving the app')
        self.results.append('TalkBack contract: button, Move to other side, Hide in this app (until the app leaves)')


def prepare(m, base, token):
    """Standalone setup for --bubble-check: Gboard, the service, microphone, synthetic speech and pairing."""
    import urllib.parse
    adb = m['adb']
    adb('shell', 'am', 'force-stop', PACKAGE)
    adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'shared_prefs')
    adb('shell', 'run-as', PACKAGE, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<map><boolean name="synthetic" value="true" /></map>')
    for permission in ('RECORD_AUDIO', 'ACCESS_LOCAL_NETWORK', 'POST_NOTIFICATIONS'):
        adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.' + permission)
    adb('shell', 'ime', 'enable', GBOARD)
    adb('shell', 'ime', 'set', GBOARD)
    adb('shell', 'settings', 'put', 'secure', 'enabled_accessibility_services', SERVICE)
    adb('shell', 'settings', 'put', 'secure', 'accessibility_enabled', '1')
    link = 'chirp://pair?' + urllib.parse.urlencode({'url': base, 'token': token})
    # adb echoes the intent; never forward its output.
    adb('shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', shlex.quote(link))
    # Saved pairing shows up as the encrypted token key; its value is never read out.
    deadline = time.monotonic() + 40
    while b'name="token"' not in adb('shell', 'run-as', PACKAGE, 'sh', '-c', shlex.quote('cat shared_prefs/chirp.xml 2>/dev/null; true')):
        assert time.monotonic() < deadline, 'Pairing was not saved'
        time.sleep(.5)
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')


def check(m, work, output, base, token, cleanup_warm=False, standalone=False):
    adb = m['adb']
    if standalone:
        prepare(m, base, token)
    assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == GBOARD, 'Gboard must stay selected'
    adb('logcat', '-b', 'crash', '-c')
    run = Bubble(m, output)
    for case in (run.show_and_hide, run.drag, lambda: run.dictate_insert(cleanup_warm), run.field_changed, run.copy_mode,
                 run.web_field, run.talkback_labels, run.captures, run.errors):
        case()
    assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == GBOARD, 'Gboard was replaced'
    prefs = adb('shell', 'run-as', PACKAGE, 'sh', '-c', shlex.quote('cat shared_prefs/*.xml'))
    assert b'Synthetic' not in prefs and b'synthetic speech' not in prefs.lower(), 'Dictated text reached preferences'
    for line in run.results:
        print('  ·', line, flush=True)
    print('PASS: floating mic bubble checks; Gboard kept; no FGS, recording client or crash after each case; no text in prefs.', flush=True)
