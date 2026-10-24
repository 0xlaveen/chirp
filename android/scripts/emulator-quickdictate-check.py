#!/usr/bin/env python3
"""#168 entry points. Disposable emulator, synthetic audio, lengths/states only."""
from pathlib import Path
import re
import runpy
import shlex

bubble = runpy.run_path(str(Path(__file__).with_name('emulator-bubble-check.py')))
PACKAGE = bubble['PACKAGE']
PROBE = bubble['PROBE']


class Entries(bubble['Bubble']):
    def capture(self, name, keep=True):
        data = self.adb('exec-out', 'screencap', '-p')
        prefix = 'share-to-notes-' if name.startswith('share-') else 'quick-dictate-'
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
        providers = self.adb('shell', 'dumpsys', 'appwidget')
        assert b'ChirpWidgetProvider' in providers, 'Widget provider missing'
        print('PASS: plain-text Share added one local note; widget provider is registered (placement is a device check).', flush=True)

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
        run.tile(); run.recognize(); run.share(); run.notes_tile(); run.errors()
    finally:
        if original_tiles == 'null': adb('shell', 'settings', 'delete', 'secure', 'sysui_qs_tiles')
        else: adb('shell', 'cmd', 'statusbar', 'set-tiles', shlex.quote(original_tiles))
    assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == bubble['GBOARD']
    print('PASS: keyboard-free entry matrix; Gboard retained and no Accessibility permission.', flush=True)
