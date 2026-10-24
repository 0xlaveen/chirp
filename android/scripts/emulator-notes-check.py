#!/usr/bin/env python3
"""Live Notes end to end, invoked by emulator-check.py --notes-check. Synthetic speech only (the debug
asset, looped with silence like a meeting) through the real NotesCapture, rolling /v1/stream sockets and
/v1/notes/* calls of the throwaway server, which counts finals and notes calls without content. Fails
unless what is said reaches the transcript and the notes while recording, within a deadline. Prints
states and counts, never the notes or transcript."""
import json
import re
import time
from pathlib import Path

DEADLINE = 90
RECORDING = ('Listening…', 'Updating notes…', 'Organizing notes…')


def log(*args):
    print('%7.1f' % (time.monotonic() % 100000), *args, flush=True)


def check(probe, work, output):
    adb, nodes = probe['adb'], probe['nodes']
    package = probe['PACKAGE']
    counts = work / 'notes.json'

    def server():
        try: return json.loads(counts.read_text())
        except (OSError, ValueError): return {}

    baseline = 0
    def finals(): return server().get('finals', 0) - baseline

    def state():
        hierarchy = nodes()
        texts = [n.get('text', '') for n in hierarchy]
        # The notes render as Markdown blocks (tagged notes-block); while editing they are one EditText.
        blocks = [n for n in hierarchy if n.get('resource-id') == 'notes-block']
        editor = next((n.get('text', '') for n in hierarchy if n.get('class') == 'android.widget.EditText'), '')
        notes = sum(len(n.get('text', '')) for n in blocks) or len(editor)
        status = next((t for t in texts if t.startswith(STATUSES)), None)
        # A listening command shows what it heard: never printed.
        if any(t.startswith('“') for t in texts) and status is None: status = '“…”'
        note = next((t for t in texts if t.startswith(NOTES)), None)
        # Chirp's elapsed clock (not the status bar's) comes before any transcript timestamp.
        clock = next((n.get('text') for n in hierarchy if n.get('package') == package and re.fullmatch(r'(\d+:)?\d\d:\d\d', n.get('text', ''))), '0:0')
        seconds = sum(int(part) * 60 ** i for i, part in enumerate(reversed(clock.split(':'))))
        return {'status': status, 'note': note, 'clock': seconds, 'notes_chars': notes, 'gaps': [t for t in texts if 'audio not transcribed' in t],
                'hearing': any(n.get('resource-id') == 'notes-hearing' for n in hierarchy)}

    def wait(predicate, message, seconds=DEADLINE):
        deadline = time.monotonic() + seconds
        last = None
        while time.monotonic() < deadline:
            current = state()
            seen = (current, server())
            if seen != last: log(*seen); last = seen
            assert not (current['status'] or '').startswith(('Notes stopped', 'Couldn’t resume')), 'Notes stopped by itself: ' + current['status']
            assert not current['gaps'], 'A segment was not transcribed: ' + ', '.join(current['gaps'])
            if predicate(current): return current
            time.sleep(1)
        shot = Path('/tmp/chirp-notes-failure.png')
        data = adb('exec-out', 'screencap', '-p'); shot.write_bytes(data[data.index(b'\x89PNG'):])
        raise AssertionError(message + ' within %d s (last: %s; server: %s; screen: %s)' % (seconds, json.dumps(last[0]), json.dumps(server()), shot))

    def wait_node(label, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            node = probe['find'](label)
            if node is not None: return node
        raise AssertionError('Missing control: ' + label)

    def tap(node): adb('shell', 'input', 'tap', *map(str, probe['center'](node)))

    def find_idle(): return probe['find']('Microphone: tap to dictate') is not None

    def recording(s): return (s['status'] or '').startswith(RECORDING)

    adb('shell', 'pm', 'grant', package, 'android.permission.POST_NOTIFICATIONS')
    # Start from empty notes: no recovery copy (or kept notes) of an earlier run. The fresh install's process reads
    # them only when Notes first opens.
    adb('shell', 'run-as', package, 'rm', '-f', 'no_backup/notes_recovery.bin', 'files/notes_sessions.bin')
    baseline = server().get('finals', 0)  # the managed warm-up's final
    adb('shell', 'am', 'start', '-n', package + '/.SetupActivity')
    probe['wait_for']('Notes')
    probe['click']('Notes')
    probe['wait_for']('Record notes')
    started = time.monotonic()
    probe['click']('Record notes')
    wait(lambda s: recording(s) and s['hearing'], 'No live speech reached Notes')
    # The asset repeats every ~12 s, so a cut comes at the first pause after 12 s: three segments need two cuts.
    wait(lambda s: recording(s) and finals() >= 3, 'Three segments did not reach the transcript while recording')
    wait(lambda s: recording(s) and 200 in server().get('structure', []) and s['notes_chars'] > 0, 'Structured notes did not reach the editor while recording')
    log('Recording: segments and notes arrived after %.0f s' % (time.monotonic() - started))

    def calls(name): return len(server().get(name, []))

    # Edit by voice while recording: capture goes to the command's socket and back to a fresh notes socket.
    before = finals()
    tap(wait_node('Edit notes by voice'))
    wait(lambda s: s['status'] in ('Say the edit…', '“…”'), 'The voice command did not start listening', 20)
    time.sleep(8)
    tap(wait_node('Send the spoken edit'))
    wait(lambda s: calls('edit') >= 1, 'The spoken edit never reached /v1/notes/edit', 60)
    assert all(code == 200 for code in server()['edit']), 'The edit call failed: ' + json.dumps(server())
    wait(lambda s: recording(s) and finals() >= before + 3, 'Notes did not go on recording after the spoken edit')
    log('Voice edit: one edit call; notes went on recording')

    # Battery saver: with the screen off, segments and notes calls go on; the editor catches up when it is back.
    clock, before, passes = state()['clock'], finals(), calls('structure')
    adb('shell', 'input', 'keyevent', 'KEYCODE_SLEEP')
    time.sleep(40)
    off = (finals() - before, calls('structure') - passes)
    adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'); adb('shell', 'wm', 'dismiss-keyguard')
    assert off[0] >= 1, 'Segments stopped with the screen off: ' + json.dumps(server())
    assert off[1] >= 1, 'Notes calls stopped with the screen off: ' + json.dumps(server())
    # The clock stops with the screen off; it (and the editor and partial line) catch up the moment it is back. It counts
    # captured audio, which the paced synthetic source delivers a little behind wall time on a busy host.
    wait(lambda s: recording(s) and s['clock'] >= clock + 20, 'The screen did not catch up after it came back', 10)
    log('Screen off 40 s: %d segments, %d notes calls; editor caught up' % off)
    probe['click']('Pause recording notes')
    wait(lambda s: s['status'] == 'Paused', 'Pause did not take effect', 30)
    before = finals()
    time.sleep(3)
    probe['click']('Resume recording notes')
    wait(lambda s: recording(s) and finals() >= before + 1, 'No segment reached the transcript after Resume')
    probe['click']('Stop recording notes')
    final = wait(lambda s: (s['status'] or '').startswith('Stopped'), 'Stop did not finish', 60)
    assert final['notes_chars'] > 0, 'Notes are empty after Stop'
    assert all(code == 200 for code in server().get('structure', [])), 'A structure call failed: ' + json.dumps(server())
    # Organize on notes under the reorganize minimum says so; with more notes it reorganizes them.
    organized = calls('reorganize')
    # Organize and Share are in the ⋮ menu; typing needs Edit (the page is rendered Markdown until then).
    # Wait for the item rather than click(), whose scroll-to-find swipe would close the menu.
    def menu(item): probe['click']('More options'); tap(wait_node(item))
    if state()['notes_chars'] < 80:
        menu('Organize')
        wait(lambda s: s['note'] == 'Nothing to organize yet — keep going', 'Organize on short notes gave no answer', 20)
        assert calls('reorganize') == organized
        # Exactly Edit notes: click() matches by substring, which would also hit Edit notes by voice.
        tap(next(n for n in nodes() if n.get('content-desc') == 'Edit notes'))
        deadline = time.monotonic() + 20
        while not (editors := [n for n in nodes() if n.get('class') == 'android.widget.EditText']):
            assert time.monotonic() < deadline, 'Edit did not open the editor'
        tap(editors[0])
        adb('shell', 'input', 'keyevent', 'KEYCODE_MOVE_END'); adb('shell', 'input', 'keyevent', 'KEYCODE_ENTER')
        adb('shell', 'input', 'text', '-%sReview%sthe%sbudget%swith%sfinance%sbefore%sthe%slaunch%son%sMonday')
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')  # hides the keyboard
        wait(lambda s: s['notes_chars'] >= 80 and s['note'] is None, 'Typing into the notes did not land', 20)
        probe['click']('Done editing')
        wait(lambda s: s['notes_chars'] > 0, 'The page did not come back after editing', 10)
    menu('Organize')
    wait(lambda s: calls('reorganize') > organized and not (s['status'] or '').startswith('Organizing'), 'Organize did not reorganize', 90)
    assert all(code == 200 for code in server()['reorganize']), 'A reorganize call failed: ' + json.dumps(server())
    menu('Share')
    deadline = time.monotonic() + 15
    # Wait until the sheet has input focus, so Back closes it rather than reaching Notes behind it on a slow host.
    while 'Chooser' not in next((l for l in adb('shell', 'dumpsys', 'window').decode(errors='replace').splitlines() if 'mCurrentFocus' in l), ''):
        assert time.monotonic() < deadline, 'Share did not open the share sheet'
        time.sleep(.5)
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')

    # The Scratchpad: the same server and app network path, the keyboard's capture. One synthetic utterance must land.
    probe['click']('Home')  # the shell's Home tab; the notes stay in the Notes tab
    probe['wait_for']('Dictate')
    probe['click']('Dictate')
    before = finals()
    tap(wait_node('Microphone: tap to dictate'))
    def scratchpad():
        return next((n.get('text', '') for n in nodes() if n.get('class') == 'android.widget.EditText'), '')
    deadline = time.monotonic() + 45
    while not (finals() > before and scratchpad() not in ('', 'Dictate, then edit here') and find_idle()):
        assert time.monotonic() < deadline, 'Scratchpad dictation did not land (server: %s)' % json.dumps(server())
        time.sleep(1)
    log('Scratchpad: one dictation landed')
    log('PASS: Live Notes: rolling segments reached the transcript, structured notes reached the editor while recording; voice edit; screen-off battery saver; pause, resume, stop; Organize; Share; Scratchpad', server())


# The fixed notes above the record control (voice edit, Organize, structuring); never notes text.
NOTES = ('Couldn’t', 'Didn’t catch', 'Nothing to edit', 'That didn’t sound', 'Can’t add', 'Notes changed', 'The edit changed',
         'Too much to edit', 'Edited', 'Organized', 'Too long to organize', 'Nothing to organize')
STATUSES = ('Tap Record', 'Pair your Mac', 'Connecting', 'Listening', 'Updating', 'Organizing', 'Finishing', 'Stopped', 'Paused',
            'Notes stopped', 'Couldn', 'Mac ', 'Checking', 'Allow microphone', 'Say the edit', 'Editing notes')
