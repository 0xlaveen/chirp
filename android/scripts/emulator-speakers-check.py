#!/usr/bin/env python3
"""Speaker labels end to end (#187, on by default #247), run by emulator-notes-check.py: two synthetic voices (macOS `say`,
Samantha then Daniel, looped with silence) through the real NotesCapture and rolling /v1/stream sockets
to the throwaway server's WeSpeaker model. Labels are on without touching a switch, so there is no consent dialog: the first
note asks the server to download its model by itself and shows a status line (the offline server's download is played by a
file copy, with Retry when the offline fetch had already failed). Then it requires two distinct people in the transcript, a
rename from a chip that lands everywhere, and kept-audio replay of a labelled segment. Prints states and counts, never text."""
import json
import shlex
import time
from pathlib import Path


def log(*args):
    print('%7.1f' % (time.monotonic() % 100000), *args, flush=True)


CHIP = '. Rename or merge this speaker'


def check(probe, work, output, standalone=False):
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
    if standalone:
        # What the notes check sets up first: notifications, the library on with kept audio.
        adb('shell', 'pm', 'grant', package, 'android.permission.POST_NOTIFICATIONS')
        adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/chirp_notes_sessions.xml'),
            data=b'<map><boolean name="enabled" value="true"/><boolean name="keep_audio" value="true"/></map>')
    adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<?xml version="1.0" encoding="utf-8"?><map><boolean name="synthetic" value="true" />'
             b'<string name="notes_asset">synthetic-two.wav</string></map>')
    adb('shell', 'am', 'start', '-n', package + '/.SetupActivity', '--es', 'section', 'try')
    probe['wait_for']('Record new note', 60)
    before = server().get('finals', 0)
    tap('Record new note')
    wait(lambda: server().get('finals', 0) >= before + 1, 'The two-voice recording did not reach the transcript')
    # Labels are on by default: no switch, no consent. The first note asked the server to fetch the model by itself.
    wait(lambda: server().get('model'), 'The phone did not ask the server for the speaker model by itself', 60)
    assert not any(n.get('text') == 'Label speakers?' for n in nodes()), 'A consent dialog appeared; labels are on by default'
    status = lambda: [n.get('text') for n in nodes() if (n.get('text') or '').startswith(('Getting the speaker model ready', 'Couldn’t download the speaker model'))]
    deadline = time.monotonic() + 30
    while not (line := status()):
        assert time.monotonic() < deadline, 'No speaker model status line while the model was missing'
        time.sleep(.5)
    log('Status line: %s' % line)
    screenshot('emulator-speakers-status.png')
    probe['speakers_model']()  # the download's stand-in: the pinned file arrives in the server's model cache
    deadline = time.monotonic() + 180
    while status():
        # The offline fetch has already failed on the phone's screen: Retry asks again and the server finds the file.
        retry = [n for n in nodes() if n.get('text') == 'Retry']
        if retry: adb('shell', 'input', 'tap', *map(str, probe['center'](retry[-1])))
        assert time.monotonic() < deadline, 'The speaker model status line never went away: %s' % status()
        time.sleep(2)
    # Segments that finished before the model was ready came back "unavailable": a model state, never an error to the user.
    early = list(server().get('label_errors', []))
    assert set(early) <= {'unavailable'}, 'Unexpected label errors before the model was ready: ' + json.dumps(early)
    labelled = server().get('labelled', 0)
    wait(lambda: server().get('labelled', 0) >= labelled + 2 and len(server().get('slots', [])) >= 2,
         'Two labelled segments with two distinct speakers did not arrive', 180)
    assert server()['slots'] == [0, 1], 'Two voices must be exactly two people: ' + json.dumps(server())
    assert server().get('label_errors', []) == early, 'The server could not label once the model was ready: ' + json.dumps(server())
    probe['click']('Stop recording notes')
    probe['wait_for']('Stopped', 90)
    log('Server: %d labelled segments, slots %s' % (server()['labelled'], server()['slots']))

    tap('Transcript')
    deadline = time.monotonic() + 30
    while len(chips()) < 2:
        assert time.monotonic() < deadline, 'The transcript does not show two speakers: ' + json.dumps(chips())
        time.sleep(1)
    people = chips()
    assert people == ['Person 1', 'Person 2'], 'Two voices must be exactly two people: ' + json.dumps(people)
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
    # On a loaded host the input service can drop characters: type until the field holds the whole name.
    for _ in range(5):
        adb('shell', 'input', 'text', 'Maya')
        time.sleep(1)
        field = [n for n in nodes() if n.get('class') == 'android.widget.EditText']
        if field and field[-1].get('text') == 'Maya': break
        adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_A')
        adb('shell', 'input', 'keyevent', 'KEYCODE_DEL')
    else:
        raise AssertionError('Could not type the new name into the rename field')
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
    log('PASS: speaker labels: on by default, model fetched without consent, two voices → two people, rename from a chip, labelled kept-audio replay')
