#!/usr/bin/env python3
"""Live Notes end to end, invoked by emulator-check.py --notes-check. Synthetic speech only (the debug
asset, looped with silence like a meeting) through the real NotesCapture, rolling /v1/stream sockets and
/v1/notes/* calls of the throwaway server, which counts finals and notes calls without content. Fails
unless what is said reaches the transcript and the notes while recording, within a deadline. Prints
states and counts, never the notes or transcript."""
import json
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
        editor = next((n.get('text', '') for n in hierarchy if n.get('class') == 'android.widget.EditText'), '')
        if editor == 'Record, or type your own notes': editor = ''
        status = next((t for t in texts if t.startswith(STATUSES)), None)
        return {'status': status, 'notes_chars': len(editor), 'gaps': sum('audio not transcribed' in t for t in texts),
                'hearing': any(t.startswith('Hearing: ') for t in texts)}

    def wait(predicate, message, seconds=DEADLINE):
        deadline = time.monotonic() + seconds
        last = None
        while time.monotonic() < deadline:
            current = state()
            seen = (current, server())
            if seen != last: log(*seen); last = seen
            assert not (current['status'] or '').startswith(('Notes stopped', 'Couldn’t resume')), 'Notes stopped by itself: ' + current['status']
            assert current['gaps'] == 0, 'A segment was not transcribed'
            if predicate(current): return current
            time.sleep(1)
        shot = Path('/tmp/chirp-notes-failure.png')
        data = adb('exec-out', 'screencap', '-p'); shot.write_bytes(data[data.index(b'\x89PNG'):])
        raise AssertionError(message + ' within %d s (last: %s; server: %s; screen: %s)' % (seconds, json.dumps(last[0]), json.dumps(server()), shot))

    def recording(s): return (s['status'] or '').startswith(RECORDING)

    adb('shell', 'pm', 'grant', package, 'android.permission.POST_NOTIFICATIONS')
    # Start from empty notes: no recovery copy (or kept notes) of an earlier run.
    adb('shell', 'am', 'force-stop', package)
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
    log('PASS: Live Notes: rolling segments reached the transcript, structured notes reached the editor while recording; pause, resume, stop', server())


STATUSES = ('Tap Record', 'Pair your Mac', 'Connecting', 'Listening', 'Updating', 'Organizing', 'Finishing', 'Stopped', 'Paused',
            'Notes stopped', 'Couldn', 'Mac ', 'Checking', 'Allow microphone')
