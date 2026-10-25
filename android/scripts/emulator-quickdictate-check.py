#!/usr/bin/env python3
"""#168 entry points. Disposable emulator, synthetic audio, lengths/states only."""
from pathlib import Path
import re
import runpy
import shlex
import time

bubble = runpy.run_path(str(Path(__file__).with_name('emulator-bubble-check.py')))
PACKAGE = bubble['PACKAGE']
PROBE = bubble['PROBE']
bounds = bubble['bounds']
center = bubble['center']


class Entries(bubble['Bubble']):
    def capture(self, name, keep=True):
        data = self.adb('exec-out', 'screencap', '-p')
        prefix = 'share-to-notes-' if name.startswith('share-') else 'launcher-' if name.startswith('widget-') else 'quick-dictate-'
        target = self.output / (prefix + name + '.png') if keep else Path('/tmp/chirp-entry-failure.png')
        target.write_bytes(data[data.index(b'\x89PNG'):])
        # Keep failure evidence even when the launcher wallpaper makes a full-screen PNG large.

    def report(self, pattern):
        return self.wait(lambda h: next((n for n in h if re.search(pattern, n.get('text', ''))), None), 'content-free probe report', seconds=90)

    def open_probe(self):
        self.adb('shell', 'am', 'start', '--activity-clear-top', '--activity-single-top', '-n', PROBE)
        self.label('Recognize')

    def count(self):
        self.open_probe(); self.press('Notes count')
        node = self.report(r'^Notes count=\d+$')
        return int(node.get('text').split('=')[1])

    def tile(self):
        self.open_probe()  # Explicitly unstop the app after the clean pairing fixture.
        self.adb('shell', 'cmd', 'statusbar', 'add-tile', PACKAGE + '/.DictateTileService')
        self.adb('shell', 'cmd', 'statusbar', 'expand-settings')
        self.wait(lambda _: b'DictateTileService' in self.adb('shell', 'dumpsys', 'activity', 'services', PACKAGE), 'Dictate tile bound')
        self.adb('shell', 'cmd', 'statusbar', 'click-tile', PACKAGE + '/.DictateTileService')
        self.label('Listening…', 60)
        self.capture('tile-listening')
        copied = self.label('Copied — paste anywhere', 90)
        self.tap(copied)  # Keep the copied panel open for review.
        self.capture('tile-copied')
        if any(n.get('text') == 'Use raw' for n in self.nodes()):
            self.press('Use raw')
        self.press('Done')
        self.open_probe(); self.press('Paste and report length')
        self.report(r'^Paste length=[1-9]\d*; sensitive=true$')
        self.no_microphone_service('Dictate final')
        print('PASS: Dictate tile listened, auto-copied a sensitive final, pasted a nonzero length and retired capture.', flush=True)

    def recognize(self):
        self.open_probe(); self.press('Recognize')
        self.label('Listening…', 60)
        self.report(r'^Recognize result=-1; ok=true; count=1; length=[1-9]\d*$')
        self.no_microphone_service('Speak result')
        self.press('Recognize'); self.label('Cancel'); self.press('Cancel')
        self.report(r'^Recognize result=0; ok=false; count=0; length=0$')
        self.no_microphone_service('Speak Cancel')
        resolved = self.adb('shell', 'cmd', 'package', 'query-activities', '--brief', '-a', 'android.speech.action.RECOGNIZE_SPEECH')
        assert PACKAGE.encode() in resolved and (b'com.google.android.googlequicksearchbox' in resolved or b'com.google.android.tts/' in resolved), 'Both recognizers must resolve'
        print('PASS: Speak returned one nonempty result, Cancel returned RESULT_CANCELED; Chirp and Google both resolve.', flush=True)

    def share(self):
        before = self.count()
        self.adb('shell', 'am', 'start', '-a', 'android.intent.action.SEND', '-t', 'text/plain', '--es', 'android.intent.extra.TEXT',
                 shlex.quote('Synthetic shared note for visual review'), '-n', PACKAGE + '/.ShareToNotesActivity')
        self.label('Save as new note'); self.capture('share-dialog')
        self.press('Save as new note')
        assert self.count() == before + 1, 'Share must add exactly one note'
        print('PASS: plain-text Share added one local note.', flush=True)

    def notes_tile(self):
        component = PACKAGE + '/.NotesTileService'
        self.adb('shell', 'cmd', 'statusbar', 'add-tile', component)
        self.adb('shell', 'cmd', 'statusbar', 'expand-settings')
        self.wait(lambda _: b'NotesTileService' in self.adb('shell', 'dumpsys', 'activity', 'services', PACKAGE), 'Notes tile bound')
        self.adb('shell', 'cmd', 'statusbar', 'click-tile', component)
        self.wait(lambda _: b'isForeground=true' in self.adb('shell', 'dumpsys', 'activity', 'services', PACKAGE), 'Notes recording')
        self.adb('shell', 'cmd', 'statusbar', 'click-tile', component)
        self.wait(lambda _: b'isForeground=true' not in self.adb('shell', 'dumpsys', 'activity', 'services', PACKAGE), 'Notes stopped', seconds=90)
        self.no_microphone_service('Notes tile stopped')
        print('PASS: existing Notes tile still records and stops.', flush=True)

    # ---- #184: a real widget, placed by the launcher and tapped -----------------------------------------------
    def top_activity(self):
        out = self.adb('shell', 'dumpsys', 'activity', 'activities').decode(errors='replace')
        match = re.search(r'topResumedActivity=ActivityRecord\{\S+ \S+ (\S+)', out)
        return match.group(1) if match else ''

    def home(self, wanted=('widget_dictate',), seconds=30):
        """Home screen hierarchy once the launcher shows the widget's controls; {id: node} for the app's widget views."""
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        def found(hierarchy):
            ids = {n.get('resource-id').split('/')[-1]: n for n in hierarchy
                   if n.get('package') == PACKAGE and n.get('resource-id', '').startswith(PACKAGE + ':id/widget_')}
            return ids if all(w in ids for w in wanted) else None
        return self.wait(found, 'widget controls on the home screen', seconds)

    def dp(self, pixels):
        text = self.adb('shell', 'wm', 'density').decode()
        density = int((re.search(r'Override density: (\d+)', text) or re.search(r'Physical density: (\d+)', text)).group(1))
        return pixels * 160 / density

    def assert_usable(self, controls, where):
        """Each shown control is inside the widget and at least 48 dp each way (a real hit rectangle, even at 200% font)."""
        root = bounds(controls['widget_root'])
        for name, node in controls.items():
            if name == 'widget_root': continue
            x1, y1, x2, y2 = bounds(node)
            assert root[0] <= x1 and root[1] <= y1 and x2 <= root[2] and y2 <= root[3], f'{name} leaves the widget {where}'
            assert self.dp(x2 - x1) >= 48 and self.dp(y2 - y1) >= 48, f'{name} is under 48 dp {where}'

    def resize(self, dx):
        """Long-press the placed widget and drag the launcher's right resize handle, like a person; returns its controls."""
        root = self.home()['widget_root']
        x, y = center(root)
        self.adb('shell', 'input', 'swipe', str(x), str(y), str(x), str(y), '1200')
        # The frame's handles are drawn on the widget's vertical edges at mid-height; the launcher does not always expose them as nodes.
        time.sleep(1.5)  # the frame's handles settle; the assertions on the resulting controls prove the resize happened
        x1, y1, x2, y2 = bounds(root)
        hx, hy = x2, (y1 + y2) // 2
        self.adb('shell', 'input', 'swipe', str(hx), str(hy), str(hx + dx), str(hy), '600')
        time.sleep(1.5)
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')  # leaves resize mode, keeps the size
        return self.home()

    def place_widget(self):
        """Pin through the app's own request and confirm in the launcher; a missed touch on the settling sheet is retried."""
        for attempt in range(3):
            if attempt:
                try:  # A slow launcher may have placed the earlier request: never add a second widget.
                    return self.home(('widget_dictate', 'widget_record'), seconds=8)
                except AssertionError:
                    pass
            self.open_probe(); self.press('Pin widget')
            add = self.label('Add to home screen', 30)
            time.sleep(1.5)  # the sheet is still sliding up; its first bounds are not where the button ends
            self.tap(self.label('Add to home screen', 10) or add)
            try:
                # The launcher's button ignores an accessibility click here; a touch is what a person does anyway.
                return self.home(('widget_dictate', 'widget_record'), seconds=20)
            except AssertionError:
                continue
        raise AssertionError('The launcher never placed the widget after three requests')

    def widget(self):
        night = self.adb('shell', 'cmd', 'uimode', 'night').decode()
        font = self.adb('shell', 'settings', 'get', 'system', 'font_scale').decode().strip()
        try:
            self.adb('shell', 'cmd', 'uimode', 'night', 'no')
            self.adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
            # The provider alone is not placement: ask the launcher for a real widget through the app's own request.
            assert b'ChirpWidgetProvider' in self.adb('shell', 'dumpsys', 'appwidget'), 'Widget provider missing'
            controls = self.place_widget()
            self.assert_usable(controls, 'at the default size')
            cell = (bounds(controls['widget_root'])[2] - bounds(controls['widget_root'])[0]) / 2
            self.capture('widget-default-light')
            # Dictate opens Quick Dictate; it listens, copies, and Gboard stays selected.
            self.tap(controls['widget_dictate'])
            self.label('Listening…', 60)
            assert self.top_activity().endswith('QuickDictateActivity'), 'Widget Dictate did not open Quick Dictate: ' + self.top_activity()
            self.capture('widget-dictate-listening')
            self.label('Copied — paste anywhere', 90)
            self.press('Done')
            self.no_microphone_service('Widget Dictate')
            # Record opens Notes and starts a recording; stopping it ends the foreground service.
            self.tap(self.home(('widget_record',))['widget_record'])
            self.wait(lambda _: b'isForeground=true' in self.adb('shell', 'dumpsys', 'activity', 'services', PACKAGE), 'Notes recording', 60)
            assert self.top_activity().endswith('NotesActivity'), 'Widget Record did not open Notes: ' + self.top_activity()
            self.press('Stop recording notes')
            self.wait(lambda _: b'isForeground=true' not in self.adb('shell', 'dumpsys', 'activity', 'services', PACKAGE), 'Notes stopped', 90)
            self.no_microphone_service('Widget Record')
            # Sizes the launcher supports: one cell hides Record and keeps a usable Dictate; four cells show both.
            narrow = self.resize(-int(cell))
            assert 'widget_record' not in narrow, 'Record should be hidden at one cell'
            self.assert_usable(narrow, 'at one cell')
            self.capture('widget-narrow-light')
            self.tap(narrow['widget_dictate']); self.label('Listening…', 60)
            assert self.top_activity().endswith('QuickDictateActivity'), 'Narrow widget Dictate did not open Quick Dictate'
            self.press('Cancel'); self.no_microphone_service('Narrow widget Dictate')
            wide = self.resize(int(cell * 3))
            assert {'widget_dictate', 'widget_record'} <= set(wide), 'Both controls should show at four cells'
            self.assert_usable(wide, 'at four cells')
            self.capture('widget-wide-light')
            # Dark, then 200% font: still readable, inside the widget, and a real hit rectangle.
            self.adb('shell', 'cmd', 'uimode', 'night', 'yes')
            time.sleep(2)
            self.assert_usable(self.home(('widget_dictate', 'widget_record')), 'in dark')
            self.capture('widget-wide-dark')
            self.adb('shell', 'settings', 'put', 'system', 'font_scale', '2.0')
            time.sleep(2)
            large = self.home(('widget_dictate', 'widget_record'))
            self.assert_usable(large, 'at 200% font')
            self.capture('widget-wide-dark-font200')
            self.adb('shell', 'cmd', 'uimode', 'night', 'no')
            time.sleep(2)
            self.capture('widget-wide-light-font200')
            assert self.adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == bubble['GBOARD'], 'Widget use replaced Gboard'
            print('PASS: real launcher widget placed from the app request; Dictate opened Quick Dictate and Record opened Notes; one- and four-cell sizes; light, dark and 200% font usable; Gboard kept.', flush=True)
        finally:
            self.adb('shell', 'settings', 'delete' if font == 'null' else 'put', 'system', 'font_scale', *([] if font == 'null' else [font]))
            self.adb('shell', 'cmd', 'uimode', 'night', 'yes' if 'yes' in night else 'auto' if 'auto' in night else 'no')

    def errors(self):
        self.m['stop_server']()
        self.open_probe(); self.press('Recognize')
        self.label('Check again', 60); self.capture('network-error')
        self.press('Done')
        self.report(r'^Recognize result=[45]; ok=false; count=0; length=0$')
        self.no_microphone_service('Speak network error')
        print('PASS: abandoned Speak connection error returned NETWORK_ERROR or SERVER_ERROR and no text.', flush=True)


def check(m, work, output, base, token):
    bubble['prepare'](m, base, token)
    adb = m['adb']
    # This path proves it needs no Accessibility service and leaves Gboard selected.
    adb('shell', 'settings', 'delete', 'secure', 'enabled_accessibility_services')
    adb('shell', 'settings', 'put', 'secure', 'accessibility_enabled', '0')
    run = Entries(m, output)
    original_tiles = adb('shell', 'settings', 'get', 'secure', 'sysui_qs_tiles').decode().strip()
    # Keep both test tiles on the visible page so SystemUI actually binds their services.
    adb('shell', 'cmd', 'statusbar', 'set-tiles', shlex.quote('custom(' + PACKAGE + '/.DictateTileService),custom(' + PACKAGE + '/.NotesTileService),wifi,bt'))
    try:
        run.tile(); run.recognize(); run.share(); run.notes_tile(); run.widget(); run.errors()
    finally:
        if original_tiles == 'null': adb('shell', 'settings', 'delete', 'secure', 'sysui_qs_tiles')
        else: adb('shell', 'cmd', 'statusbar', 'set-tiles', shlex.quote(original_tiles))
    assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == bubble['GBOARD']
    print('PASS: keyboard-free entry matrix; Gboard retained and no Accessibility permission.', flush=True)
