#!/usr/bin/env python3
"""Dictation history demo, invoked by emulator-check.py --history-check. Synthetic speech only:
opt in from the keyboard, dictate, erase, reinsert from history (cleaned and raw), check the
file is encrypted, capture the panel on the Fold's inner and cover screens, then turn history
off and confirm the file is deleted."""
import re
import time
import xml.etree.ElementTree as ET

HINTS = ('Test dictation here', 'Try a sentence')


def check(probe, work, output):
    adb, click, wait_for, nodes, tap = (probe[name] for name in ('adb', 'click', 'wait_for', 'nodes', 'tap'))
    package = probe['PACKAGE']
    store = 'files/dictation_history.bin'

    def shot(name):
        data = adb('exec-out', 'screencap', '-p')
        path = output / ('emulator-history-' + name + '.png')
        path.write_bytes(data[data.index(b'\x89PNG'):])
        assert path.stat().st_size < 2_000_000, 'Screenshot exceeds 2 MB'

    def editor():
        # A keyboard strip resize can briefly expose no editor accessibility root.
        for _ in range(30):
            try:
                value = probe['editor_text']()
            except StopIteration:
                time.sleep(.2)
                continue
            return '' if value in HINTS else value
        raise AssertionError('Editor accessibility root did not return')

    def poll(predicate, message, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                result = predicate()
            except RuntimeError:
                # The on-device accessibility probe can fail transiently under host load.
                time.sleep(.5)
                continue
            # A matched node with no children is falsy, so test elements by identity.
            if isinstance(result, ET.Element) or result:
                return result
            time.sleep(.3)
        raise AssertionError(message)

    def strip_button():
        # The settings page behind the keyboard also has a "Dictation history" switch.
        return next((n for n in nodes() if n.get('content-desc') == 'Dictation history'
                     and n.get('class') == 'android.widget.Button'), None)

    def open_history():
        tap(poll(strip_button, 'History button missing from the Chirp row'))
        poll(lambda: any(n.get('content-desc') == 'Close dictation history' for n in nodes()), 'History panel did not open')

    def row(value):
        deadline = time.monotonic() + 15
        needle = value[:40]
        while time.monotonic() < deadline:
            match = next((n for n in nodes() if n.get('content-desc', '').startswith(value + '. ')
                          or needle in n.get('content-desc', '')), None)
            if isinstance(match, ET.Element):
                return match
            time.sleep(.3)
        print('NEEDLE', repr(value), flush=True)
        for n in nodes():
            if n.get('class') not in ('helium314.keyboard.keyboard.Key',) and (n.get('text') or n.get('content-desc')):
                print('DBG', n.get('class'), (n.get('text') or '')[:70], (n.get('content-desc') or '')[:90], flush=True)
        raise AssertionError('Dictation missing from history')

    def stored():
        return adb('shell', 'run-as', package, 'sh', '-c', "'cat " + store + " 2>/dev/null || true'")

    def fresh_editor():
        # Once paired, the test field can sit just under the fold with only a sliver reported
        # visible; the shared helper then taps outside it. Scroll it fully into view and retry.
        try:
            probe['fresh_editor']()
        except AssertionError:
            w, h = probe['size']()
            adb('shell', 'input', 'swipe', str(w // 2), str(h * 3 // 4), str(w // 2), str(h // 4), '300')
            probe['focus_editor']()

    def erase():
        adb('shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_A')
        adb('shell', 'input', 'keyevent', 'KEYCODE_DEL')
        poll(lambda: editor() == '', 'Editor was not cleared')

    original_size = adb('shell', 'wm', 'size').decode()
    original_density = adb('shell', 'wm', 'density').decode()
    try:
        adb('shell', 'run-as', package, 'rm', '-f', 'shared_prefs/chirp_history.xml', store)
        adb('shell', 'cmd', 'uimode', 'night', 'no')
        adb('shell', 'wm', 'size', '2076x2152')
        adb('shell', 'wm', 'density', '420')
        fresh_editor()
        erase()

        # One-tap opt-in from the keyboard; nothing is stored before it.
        open_history()
        wait_for('Keep history on this phone')
        shot('optin-inner-light')
        click('Keep history on this phone')
        poll(lambda: any(n.get('text', '').startswith('No dictations yet') for n in nodes()), 'Empty history missing after opt-in')
        click('Back to keyboard')
        assert not stored(), 'History file written before any dictation'

        # Synthetic dictation with on-Mac clean-up, then erase it.
        def dictate():
            x, y = probe['center'](wait_for('Microphone: tap to dictate'))
            adb('shell', 'input', 'tap', str(x), str(y))
            poll(lambda: editor() != '', 'No partial reached the editor', seconds=60)
            time.sleep(3)
            adb('shell', 'input', 'tap', str(x), str(y))
            time.sleep(1)
            wait_for('Microphone: tap to dictate', seconds=70)
            return poll(lambda: editor().strip(), 'Final was not committed')

        # Under host load the IME's clean-up budget can lapse and keep the original; retry once.
        final = dictate()
        if re.search(r'\b(?:um|uh)\b', final, re.I):
            print('Clean-up kept the original; retrying once', flush=True)
            erase()
            final = dictate()
        assert not re.search(r'\b(?:um|uh)\b', final, re.I), 'Clean-up did not remove fixture fillers'
        encrypted = poll(stored, 'History file was not written')
        words = [w for w in re.findall(r'[A-Za-z]{5,}', final)]
        assert words and not any(w.encode() in encrypted for w in words), 'History file contains plaintext'
        erase()

        # Reinsert the cleaned text from the keyboard panel.
        open_history()
        row(final)
        shot('list-inner-light')
        target = row(final)
        assert 'Cleaned' in target.get('content-desc', ''), 'Cleaned entry is not announced as cleaned'
        tap(target)
        deadline = time.monotonic() + 20
        last = None
        while time.monotonic() < deadline:
            try:
                last = editor().strip()
            except RuntimeError:
                time.sleep(.5)
                continue
            if last == final:
                break
            time.sleep(.3)
        else:
            print('WANT', repr(final), flush=True)
            print('GOT', repr(last), flush=True)
            raise AssertionError('History tap did not reinsert the dictation')
        assert not any(n.get('content-desc') == 'Close dictation history' for n in nodes()), 'Panel stayed open after insert'
        shot('reinserted-inner-light')

        # Long-press shows Copy / Insert raw / Delete; Insert raw restores the fillers.
        erase()
        open_history()
        for _ in range(2):
            rx, ry = probe['center'](row(final))
            adb('shell', 'input', 'swipe', str(rx), str(ry), str(rx), str(ry), '800')
            item = probe['find']('Insert raw')
            if item is not None:
                break
        assert item is not None, 'Long-press menu did not open'
        shot('menu-inner-light')
        tap(item)
        raw = poll(lambda: editor().strip(), 'Insert raw did not insert')
        assert re.search(r'\bum\b', raw, re.I) and re.search(r'\buh\b', raw, re.I), 'Insert raw did not restore fixture fillers'
        erase()

        for form, resolution in (('inner', '2076x2152'), ('cover', '1080x2520')):
            adb('shell', 'wm', 'size', resolution)
            for theme in ('light', 'dark'):
                adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
                fresh_editor()
                shot('keyboard-' + form + '-' + theme)
                open_history()
                try:
                    node = row(final)
                except AssertionError:
                    raise AssertionError('History missing on ' + form + ' ' + theme)
                w, h = probe['size']()
                x1, y1, x2, y2 = probe['bounds'](node)
                assert 0 <= x1 < x2 <= w and 0 <= y1 < y2 <= h, 'Clipped history row'
                assert not any(n.get('class') == 'helium314.keyboard.keyboard.Key' for n in nodes()), 'Keys still exposed under the panel'
                shot('panel-' + form + '-' + theme)
                # Back closes the panel and leaves the keyboard up.
                adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
                wait_for('Microphone: tap to dictate')
                assert any(n.get('class') == 'helium314.keyboard.keyboard.Key' for n in nodes()), 'Back hid the keyboard'

        # Full history screen with search.
        adb('shell', 'wm', 'size', '2076x2152')
        adb('shell', 'cmd', 'uimode', 'night', 'no')
        fresh_editor()
        open_history()
        click('Search and manage dictation history')
        wait_for('Search history')
        poll(lambda: any(final in n.get('text', '') for n in nodes()), 'Entry missing from history screen')
        assert any(n.get('text', '').startswith('Before clean-up: ') for n in nodes()), 'Raw text missing from history screen'
        shot('screen-light')
        click('Search history')
        adb('shell', 'input', 'text', 'zzqx')
        wait_for('No matches')
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')

        # Turning history off asks first and then deletes the file.
        adb('shell', 'am', 'start', '-n', package + '/.SetupActivity', '--es', 'section', 'settings')
        wait_for('Keep dictation history on this phone')
        shot('settings-light')
        tap(poll(lambda: next((n for n in nodes() if n.get('content-desc') == 'Dictation history'
                                and n.get('class') == 'android.widget.Switch'), None), 'History switch missing'))
        wait_for('Turn off and delete')
        click('Turn off and delete')
        poll(lambda: not stored(), 'History file survived turning history off')
        print('PASS: keyboard opt-in; cleaned final recorded encrypted (no plaintext on disk); erase + reinsert '
              'from panel; long-press Insert raw; inner/cover light/dark; back closes panel; history screen '
              'search; turn off deletes file.', flush=True)
    except Exception:
        data = adb('exec-out', 'screencap', '-p')
        open('/tmp/chirp-history-failure.png', 'wb').write(data[data.index(b'\x89PNG'):])
        raise
    finally:
        for command, original in (('size', original_size), ('density', original_density)):
            override = re.search(r'Override (?:size|density): (\S+)', original)
            adb('shell', 'wm', command, override.group(1) if override else 'reset')
        adb('shell', 'cmd', 'uimode', 'night', 'no')
        adb('shell', 'run-as', package, 'rm', '-f', 'shared_prefs/chirp_history.xml', store)
