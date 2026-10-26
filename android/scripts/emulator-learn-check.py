#!/usr/bin/env python3
"""Real speech/model learning loop; only counts and pass/fail are logged, never terms or dictation."""
import json
import re
import shlex
import time


def check(probe, work, output):
    adb, nodes, click, wait_for = (probe[n] for n in ('adb', 'nodes', 'click', 'wait_for'))
    package = probe['PACKAGE']

    def poll(predicate, message, seconds=40):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                value = predicate()
                if value:
                    return value
            except (RuntimeError, StopIteration, FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(.4)
        raise AssertionError(message)

    def editor():
        value = probe['editor_text']()
        return '' if value == 'Synthetic E2E editor' else value

    def metadata():
        return json.loads((work / 'events.json').read_text())

    def dictate():
        probe['fresh_editor']()
        button = wait_for('Microphone: tap to dictate', seconds=60)
        probe['tap'](button)
        poll(lambda: editor().strip(), 'No partial reached the native editor', seconds=70)
        wait_for('Microphone: tap to dictate', seconds=90)
        poll(lambda: metadata().get('retired'), 'Server session did not retire', seconds=90)
        return poll(lambda: editor().strip(), 'Final was not committed')

    def learned_screen():
        adb('shell', 'am', 'start', '-n', package + '/.SetupActivity', '--es', 'section', 'settings')
        wait_for('Dictation', seconds=60)
        click('Dictation')
        for _ in range(6):
            if probe['find']('Learned') is not None:
                break
            w, h = probe['size']()
            adb('shell', 'input', 'swipe', str(w * 3 // 4), str(h * 4 // 5), str(w * 3 // 4), str(h // 3), '300')
        click('Learned')
        wait_for('In use', seconds=30)

    # Reset only our owned emulator's disposable synthetic stores, retaining pairing.
    adb('shell', 'am', 'force-stop', package)
    adb('shell', 'run-as', package, 'rm', '-f', 'files/learned.bin', 'files/dictation_history.bin',
        'shared_prefs/chirp_history.xml', 'shared_prefs/chirp_learning.xml')
    adb('shell', 'run-as', package, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<map><boolean name="synthetic" value="true"/><string name="dictation_asset">synthetic-learn.wav</string></map>')
    for iteration in range(2):
        final = dictate()
        match = re.search(r'\bto (.+?) before\b', final, re.I)
        assert match and match.group(1) != 'AcmeCloud', 'Technical mishearing missing from speech fixture'
        corrected = final[:match.start(1)] + 'AcmeCloud' + final[match.end(1):]
        adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_A')
        adb('shell', 'input', 'text', shlex.quote(corrected.replace(' ', '%s')))
        poll(lambda: 'AcmeCloud' in editor(), 'Correction did not reach the same field')
        time.sleep(1)  # Allow the bounded edit watcher to observe the field before hiding its IME.
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        poll(lambda: adb('shell', 'run-as', package, 'ls', 'files/learned.bin').strip(), 'Learning store was not sealed')
        time.sleep(1)
        print('PASS: correction window', iteration + 1, flush=True)

    learned_screen()
    wait_for('AcmeCloud')
    final = dictate()
    state = metadata()
    (output / 'server-learning.json').write_text(json.dumps(state, indent=2) + '\n')
    print('Server learning observations:', json.dumps(state), flush=True)
    assert 'AcmeCloud' in final, 'Learned term was not applied in the next dictation'
    assert state.get('learned_terms', 0) >= 1, 'Real server did not receive start.learned'
    assert state.get('learned_applied') and state.get('corrected'), 'Real server did not apply the learned correction'
    sealed = adb('shell', 'run-as', package, 'cat', 'files/learned.bin')
    assert b'AcmeCloud' not in sealed and b'acme' not in sealed, 'Learned store contains plaintext'
    for theme, mode in (('light', 'no'), ('dark', 'yes')):
        adb('shell', 'cmd', 'uimode', 'night', mode)
        learned_screen()
        wait_for('AcmeCloud')
        wait_for('In use')
        data = adb('exec-out', 'screencap', '-p')
        (output / ('learned-' + theme + '.png')).write_bytes(data[data.index(b'\x89PNG'):])

    print('PASS: threshold, Learned UI light/dark, sealed storage, start.learned and real-server correction', flush=True)
