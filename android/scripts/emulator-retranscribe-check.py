#!/usr/bin/env python3
"""Real kept AAC → memory PCM → authenticated stream. Only synthetic fixtures; reports metadata only."""
import json
import time
from pathlib import Path


def check(probe, work, output, speakers=False):
    adb, package = probe['adb'], probe['PACKAGE']

    def debug(operation='status'):
        adb('shell', 'am', 'start', '-W', '-n', package + '/.RetranscribeProbeActivity', '--es', 'operation', operation)
        result = json.loads(adb('shell', 'run-as', package, 'cat', 'files/retranscribe-probe.json'))
        assert result.get('ok'), 'Synthetic re-transcribe probe could not read the current note'
        return result

    def click(label):
        node = probe['wait_for'](label, 30)
        adb('shell', 'input', 'tap', *map(str, probe['center'](node)))

    def screenshot(name):
        data = adb('exec-out', 'screencap', '-p')
        (output / name).write_bytes(data[data.index(b'\x89PNG'):])

    def files():
        home = probe['server_home']
        return {str(p.relative_to(home)) for p in home.rglob('*') if p.is_file()}

    before_files = files()
    before = debug('corrupt')
    assert before['wrong'] and before['clips'] > 0, 'Expected kept audio and deliberately wrong text'
    if speakers: assert before['overrides'] > 0, 'The labelled fixture needs a manual turn override'
    adb('logcat', '-c')
    click('More options'); click('Re-transcribe…')
    probe['wait_for']('Re-transcribe', 30)
    screenshot('emulator-retranscribe-consent.png')
    click('Re-transcribe')
    deadline = time.monotonic() + 240
    while True:
        if probe['find']('Transcript updated') is not None or any('updated.' in n.get('text', '') for n in probe['nodes']()): break
        assert time.monotonic() < deadline, 'Kept-audio re-transcription did not complete'
        assert probe['find']('Apply what’s done') is None, 'Re-transcription stopped with a transport failure'
        time.sleep(1)
    screenshot('emulator-retranscribe-updated.png')
    after = debug()
    (output / 'retranscribe-state.json').write_text(json.dumps(after, indent=2) + '\n')
    assert after['updated'] and after['fixture_words'] and not after['wrong'], 'The real model did not replace WRONG TEXT with fixture speech'
    assert after['identity_preserved'] and after['body_preserved'] and after['title_preserved'], 'Speaker identities or user edits changed'
    assert after['previous'] and after['scratch_empty'], 'Missing previous transcript or plaintext scratch left behind'
    if speakers: assert after['overrides'] == before['overrides'], 'Manual reassignment was lost'
    click('Undo')
    restored = debug()
    assert restored['wrong'] and restored['identity_preserved'], 'Undo did not restore the original transcript and turns'
    # Replacing the earlier version is bounded; Restore is available after dismissing the toast.
    click('Dismiss')
    click('More options'); click('Restore previous transcript')
    assert debug()['fixture_words'], 'Restore did not swap the saved transcript back'
    # Activity persistence is debounced; wait for the actual metadata event rather than inspecting content.
    activity = None
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        for path in probe['server_home'].rglob('device-activity.json'):
            data = json.loads(path.read_text())
            activity = [row for row in data.get('events', []) if 'notes_retranscribe' in row]
        if activity: break
        time.sleep(.25)
    assert activity and any(isinstance(row[6], (int, float)) and row[6] > 0 for row in activity), 'No notes_retranscribe activity with audio_ms'
    assert all(len(row) == 10 for row in activity), 'Activity must contain only its fixed metadata fields'
    added = files() - before_files
    assert all(Path(name).name == 'device-activity.json' for name in added), 'Re-transcription wrote unexpected server files'
    forbidden = ('synthetic keyboard', 'draft tomorrow', 'ship the beta', 'spec tomorrow', 'WRONG TEXT')
    logs = probe['server_log'].read_text(errors='replace')
    client = adb('logcat', '-d').decode(errors='replace')
    assert not any(phrase.lower() in logs.lower() for phrase in forbidden), 'Server log contains fixture speech'
    assert not any(phrase.lower() in client.lower() for phrase in forbidden), 'Client log contains fixture speech'
    (output / 'retranscribe-result.json').write_text(json.dumps({'clips': before['clips'], 'identity_preserved': True, 'undo': True, 'restore': True, 'privacy': True, 'speakers': speakers}, indent=2) + '\n')
    print('PASS: real AAC decoder, kept speech re-transcribed, speaker identities/body/title preserved, Undo/Restore, activity metadata and log/file privacy', flush=True)
