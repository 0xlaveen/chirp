#!/usr/bin/env python3
"""Speaker labels end to end (#187), run by emulator-notes-check.py: two synthetic voices (macOS `say`,
Samantha then Daniel, looped with silence) through the real NotesCapture and rolling /v1/stream sockets
to the throwaway server's WeSpeaker model. Labels default on and the phone requests its model
without consent; the offline fixture copies and verifies the pinned file. Requires exactly two
people, the post-Stop naming sheet, rename persistence, and kept-audio replay. Prints states and counts, never text."""
import json
import os
import shlex
import time
import xml.etree.ElementTree as ET
from pathlib import Path


def log(*args):
    print('%7.1f' % (time.monotonic() % 100000), *args, flush=True)


CHIP = '. Rename, merge or reassign this speaker'


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

    def chips(): return sorted({n.get('content-desc')[:-len(CHIP)].removesuffix(', recognised') for n in nodes() if n.get('content-desc', '').endswith(CHIP)})

    def edit_text():
        return [n for n in nodes() if n.get('class') == 'android.widget.EditText']

    def type_into(field, name):
        """Taps [field] and types until it holds the whole [name]: on a loaded host the input service can drop characters."""
        adb('shell', 'input', 'tap', *map(str, probe['center'](field)))
        for _ in range(5):
            adb('shell', 'input', 'text', name)
            time.sleep(1)
            now = edit_text()
            if now and any(f.get('text') == name for f in now): return
            adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_A')
            adb('shell', 'input', 'keyevent', 'KEYCODE_DEL')
        raise AssertionError('Could not fill the speaker name field')

    def tap(label):
        result = adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                     'dev.chirp.smoke.UiHierarchy', 'await-click', shlex.quote(label), '30000')
        assert b'CLICKED' in result, 'Accessible action did not complete'

    # The two-voice asset, read by a fresh process (preferences are cached per process).
    adb('shell', 'am', 'force-stop', package)
    # This phase isolates real diarization/enrollment from managed cleanup's engine lease.
    # Preserve the encrypted fixture pairing in memory, never print it or write it to evidence.
    preferences = ET.fromstring(adb('shell', 'run-as', package, 'cat', 'shared_prefs/chirp.xml'))
    for child in list(preferences):
        if child.get('name') in ('correction', 'correction_explicit'):
            preferences.remove(child)
    ET.SubElement(preferences, 'boolean', name='correction', value='false')
    ET.SubElement(preferences, 'boolean', name='correction_explicit', value='true')
    adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/chirp.xml'), data=ET.tostring(preferences))
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
    probe['wait_for']('Turn off', 90)
    screenshot('emulator-speakers-status.png')
    if os.environ.get('CHIRP_E2E_SPEAKER_CANCEL') == '1':
        # Against the cancellation-capable server branch: turn off stops its active fetch,
        # leaves the preference off, then a deliberate on starts a fresh download.
        tap('Turn off')
        wait(lambda: server().get('model_actions', [])[-1:] == ['cancel'] and
             server().get('model_state') == 'not_downloaded', 'Turn off did not cancel the active fetch', 30)
        assert probe['find']('Turn off') is None, 'Model status remained after turning labels off'
        probe['click']('More options')
        tap('Label speakers')
        probe['wait_for']('Turn off', 90)
        wait(lambda: server().get('model_actions', [])[-1:] == ['download'] and
             server().get('model_state') == 'downloading', 'Explicit on did not restart the download', 30)
        log('PASS: Turn off cancelled the active download; explicit on restarted it')
    probe['speakers_model']()  # Release only after the inline preparation status was captured.
    wait(lambda: server().get('finals', 0) >= before + 1, 'The two-voice recording did not reach the transcript')
    # No switch or consent: the first note requests the model by itself.
    wait(lambda: any(code in (200, 202) for code in server().get('model', [])),
         'The automatic download never reached /v1/speakers/model', 30)
    assert probe['find']('Label speakers?') is None, 'A consent dialog blocked default-on labels'
    labelled = server().get('labelled', 0)
    wait(lambda: server().get('labelled', 0) >= labelled + 2 and len(server().get('slots', [])) >= 2,
         'Two labelled segments with two distinct speakers did not arrive', 180)
    assert server()['slots'] == [0, 1], 'Two voices must be exactly two people: ' + json.dumps(server())
    assert not server().get('label_errors'), 'The server could not label: ' + json.dumps(server())
    probe['click']('Stop recording notes')
    probe['wait_for']('Stopped', 90)
    log('Server: %d labelled segments, slots %s' % (server()['labelled'], server()['slots']))

    # After Stop with unnamed people: "Who was speaking?" opens the Name speakers sheet, one place for everyone.
    probe['wait_for']('Who was speaking?', 30)
    screenshot('emulator-speakers-who.png')
    tap('Name speakers')
    deadline = time.monotonic() + 20
    while len(fields := edit_text()) < 2:
        assert time.monotonic() < deadline, 'The Name speakers sheet did not list two people'
        time.sleep(.5)
    assert len(fields) == 2, 'Two voices must be exactly two rows in the Name speakers sheet: %d' % len(fields)
    type_into(sorted(fields, key=lambda n: probe['center'](n)[1])[0], 'Sam')
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')  # closes the keyboard
    screenshot('emulator-speakers-name-sheet.png')
    tap('Play a sample of Person 1')
    probe['wait_for']('Stop sample', 30)
    tap('Stop sample')
    tap('Done')
    # Enrolment uses voiced windows, rather than the wall clock. If this first note is
    # short, continuing it must automatically remember the drafted name without another rename.
    deadline = time.monotonic() + 45
    continued = False
    while probe['find']('Remembering voices') is None:
        if 'too_short' in server().get('voice_errors', []):
            tap('Continue recording')
            continued = True
            break
        assert time.monotonic() < deadline, 'Naming produced neither enrollment nor a short-voice result'
        time.sleep(.5)
    probe['wait_for']('Remembering voices', 180)
    screenshot('emulator-speakers-notice.png')
    tap('OK')
    wait(lambda: server().get('voice_count', 0) >= 1, 'Naming did not remember a voice on the server', 30)
    if continued:
        probe['click']('Stop recording notes')
        probe['wait_for']('Stopped', 90)

    tap('Transcript')
    deadline = time.monotonic() + 30
    while len(chips()) < 2:
        assert time.monotonic() < deadline, 'The transcript does not show two speaker chips'
        time.sleep(1)
    people = chips()
    assert people == ['Person 2', 'Sam'], 'Two voices must be exactly two people, one named in the sheet'
    screenshot('emulator-speakers-transcript.png')
    log('Transcript speaker count: %d' % len(people))

    # Rename from a chip: the new name replaces "Person 2" everywhere in the note.
    tap('Person 2' + CHIP)
    tap('Rename “Person 2”…')
    deadline = time.monotonic() + 20
    while not (fields := edit_text()):
        assert time.monotonic() < deadline, 'The rename field did not open'
        time.sleep(.5)
    type_into(fields[-1], 'Maya')
    adb('shell', 'input', 'keyevent', 'KEYCODE_ENTER')
    deadline = time.monotonic() + 20
    while 'Maya' not in chips():
        assert time.monotonic() < deadline, 'The rename did not reach the transcript'
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

    # A new note uses a new random session; both named voices are recognised by the server.
    wait(lambda: server().get('voice_count', 0) == 2, 'Chip rename did not remember the second voice', 45)
    tap('Back to notes')
    probe['wait_for']('Record new note', 30)
    matched = server().get('matched', 0)
    tap('Record new note')
    wait(lambda: server().get('matched', 0) >= matched + 2,
         'A new note did not recognise the saved voices', 180)
    tap('Transcript')
    probe['wait_for']('Sam, recognised' + CHIP, 45)
    screenshot('emulator-speakers-recognised.png')
    remembered = sum(a == {'action': 'remember', 'status': 200} for a in server().get('voice_actions', []))
    tap('Sam, recognised' + CHIP)
    tap('Update Sam’s voice')
    wait(lambda: sum(a == {'action': 'remember', 'status': 200} for a in server().get('voice_actions', [])) > remembered,
         'Update saved voice did not reach the server', 45)
    tap('Sam, recognised' + CHIP)
    tap('Not Sam')
    assert 'Sam' not in chips(), 'Not X did not restore the numbered person'
    labelled = server().get('labelled', 0)
    wait(lambda: server().get('labelled', 0) > labelled, 'No segment arrived after Not X', 90)
    assert 'Sam' not in chips(), 'A rejected voice was applied again in the same note'
    assert server().get('voice_count') == 2, 'Not X changed the shared library'
    screenshot('emulator-speakers-rejected.png')
    tap('Close transcript')
    probe['click']('Stop recording notes')
    probe['wait_for']('Stopped', 90)

    # Re-transcribe the labelled real AAC clips, preserving names and a per-turn override.
    import runpy
    runpy.run_path(str(Path(__file__).with_name("emulator-retranscribe-check.py")))["check"](probe, work, output, speakers=True)

    # Back to the one-voice asset for whatever runs next.
    adb('shell', 'am', 'force-stop', package)
    adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<?xml version="1.0" encoding="utf-8"?><map><boolean name="synthetic" value="true" /></map>')
    log('PASS: speaker labels: on by default, model fetched without consent, two voices → two people, Name speakers sheet, rename from a chip, labelled kept-audio replay; naming → server enrollment → automatic recognition in a new note; Update voice; Not X suppression')
