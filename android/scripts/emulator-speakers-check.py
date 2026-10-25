#!/usr/bin/env python3
"""Speaker labels end to end (#187), run by emulator-notes-check.py: two synthetic voices (macOS `say`,
Samantha then Daniel, looped with silence) through the real NotesCapture and rolling /v1/stream sockets
to the throwaway server's WeSpeaker model. Turns Label speakers on from the note's menu through the
consent dialog, then requires two distinct people in the transcript, a rename from a chip that lands
everywhere, and kept-audio replay of a labelled segment. Prints states and counts, never text."""
import json
import shlex
import time
from pathlib import Path


def log(*args):
    print('%7.1f' % (time.monotonic() % 100000), *args, flush=True)


CHIP = '. Rename or merge this speaker'


def check(probe, work, output):
    adb, nodes = probe['adb'], probe['nodes']
    package = probe['PACKAGE']
    counts = work / 'notes.json'

    def server():
        try: return json.loads(counts.read_text())
        except (OSError, ValueError): return {}

    def screenshot(name):
        data = adb('exec-out', 'screencap', '-p')
        (output / name).write_bytes(data[data.index(b'\x89PNG'):])

    def wait(predicate, message, seconds=120):
        deadline = time.monotonic() + seconds
        last = None
        while time.monotonic() < deadline:
            seen = server()
            if seen != last: log({k: seen.get(k) for k in ('finals', 'labelled', 'slots', 'label_errors', 'model')}); last = seen
            if predicate(): return
            time.sleep(1)
        screenshot('emulator-speakers-failure.png')
        raise AssertionError(message + ' within %d s (server: %s)' % (seconds, json.dumps(last)))

    def chips(): return sorted({n.get('content-desc')[:-len(CHIP)] for n in nodes() if n.get('content-desc', '').endswith(CHIP)})

    def tap(label): adb('shell', 'input', 'tap', *map(str, probe['center'](probe['wait_for'](label, 30))))

    # The two-voice asset, read by a fresh process (preferences are cached per process).
    adb('shell', 'am', 'force-stop', package)
    adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<?xml version="1.0" encoding="utf-8"?><map><boolean name="synthetic" value="true" />'
             b'<string name="notes_asset">synthetic-two.wav</string></map>')
    adb('shell', 'am', 'start', '-n', package + '/.SetupActivity', '--es', 'section', 'try')
    probe['wait_for']('Record new note', 60)
    before = server().get('finals', 0)
    tap('Record new note')
    wait(lambda: server().get('finals', 0) >= before + 1, 'The two-voice recording did not reach the transcript')
    # Smart options: Label speakers asks before the Mac downloads its model (the throwaway server has it already).
    probe['click']('More options')
    tap('Label speakers')
    probe['wait_for']('Label speakers?', 20)
    screenshot('emulator-speakers-consent.png')
    tap('Download')
    wait(lambda: 200 in server().get('model', []), 'The consented download never reached /v1/speakers/model', 30)
    labelled = server().get('labelled', 0)
    wait(lambda: server().get('labelled', 0) >= labelled + 2 and len(server().get('slots', [])) >= 2,
         'Two labelled segments with two distinct speakers did not arrive', 180)
    assert not server().get('label_errors'), 'The server could not label: ' + json.dumps(server())
    probe['click']('Stop recording notes')
    probe['wait_for']('Stopped', 90)
    log('Server: %d labelled segments, slots %s' % (server()['labelled'], server()['slots']))

    tap('Transcript')
    deadline = time.monotonic() + 30
    while len(chips()) < 2:
        assert time.monotonic() < deadline, 'The transcript does not show two speakers: ' + json.dumps(chips())
        time.sleep(1)
    people = chips()
    assert {'Person 1', 'Person 2'} <= set(people), 'Unexpected speakers: ' + json.dumps(people)
    screenshot('emulator-speakers-transcript.png')
    log('Transcript speakers: %s' % people)

    # Rename from a chip: the new name replaces "Person 2" everywhere in the note.
    tap('Person 2' + CHIP)
    tap('Rename “Person 2”…')
    deadline = time.monotonic() + 20
    while not (fields := [n for n in nodes() if n.get('class') == 'android.widget.EditText']):
        assert time.monotonic() < deadline, 'The rename field did not open'
        time.sleep(.5)
    adb('shell', 'input', 'tap', *map(str, probe['center'](fields[-1])))
    adb('shell', 'input', 'text', 'Maya')
    time.sleep(1)
    adb('shell', 'input', 'keyevent', 'KEYCODE_ENTER')
    deadline = time.monotonic() + 20
    while 'Maya' not in chips():
        assert time.monotonic() < deadline, 'The rename did not reach the transcript: ' + json.dumps(chips())
        time.sleep(1)
    assert 'Person 2' not in chips(), 'Person 2 is still shown after the rename'
    screenshot('emulator-speakers-renamed.png')

    # Kept audio still replays per segment in a labelled transcript.
    play = [n for n in nodes() if n.get('content-desc', '').startswith('Play segment ')]
    assert play, 'No kept audio to replay in the labelled transcript'
    adb('shell', 'input', 'tap', *map(str, probe['center'](play[-1])))
    probe['wait_for']('Stop playback', 30)
    deadline = time.monotonic() + 75
    while probe['find']('Stop playback') is not None:
        assert time.monotonic() < deadline, 'Kept audio never completed playback'
        time.sleep(.5)
    tap('Close transcript')

    # Back to the one-voice asset for whatever runs next.
    adb('shell', 'am', 'force-stop', package)
    adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<?xml version="1.0" encoding="utf-8"?><map><boolean name="synthetic" value="true" /></map>')
    log('PASS: speaker labels: consent → model ready, two voices → two people, rename from a chip, labelled kept-audio replay')
