#!/usr/bin/env python3
"""Fold layout geometry regression and screenshots; emulator-only.

Run after build-ui-probe.sh with the desired APK installed. --before captures
the unmodified 0.5.2 default, including the tablet arrangement at 600–767 dp.
"""
import argparse
import importlib.util
import os
import re

spec = importlib.util.spec_from_file_location('smoke', __file__.replace('emulator-fold-layout.py', 'emulator-smoke.py'))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
adb = smoke.adb


def focus_editor():
    # A just-scrolled Compose field may expose only a sliver of its hit rectangle.
    # Require a usable target and retry if its first focus request races layout.
    for _ in range(8):
        hierarchy = smoke.nodes()
        editor = next((n for n in hierarchy if n.get('class') == 'android.widget.EditText'
                       and smoke.visible(n) and smoke.bounds(n)[3] - smoke.bounds(n)[1] >= 80), None)
        if editor is not None:
            x, y = smoke.center(editor)
            adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                'dev.chirp.smoke.UiHierarchy', 'tap', str(x), str(y))
            try:
                smoke.wait_for('Microphone: tap to dictate', 8)
                return
            except AssertionError:
                continue
        w, h = smoke.size()
        adb('shell', 'input', 'swipe', str(w // 2), str(h * 3 // 4), str(w // 2), str(h // 3), '250')
    raise AssertionError('Could not focus the Fold test editor')


def choose_look(label):
    w, h = smoke.size()
    # HeliBoard can restore the settings scroll offset from the previous visit.
    for _ in range(3):
        adb('shell', 'input', 'swipe', str(w // 2), str(h // 3), str(w // 2), str(h * 4 // 5), '300')
    for _ in range(14):
        node = smoke.find(label)
        if node is not None and smoke.bounds(node)[3] - smoke.bounds(node)[1] >= 40:
            smoke.tap(node)
            return
        # Small increments keep a radio row from being skipped between dumps.
        adb('shell', 'input', 'swipe', str(w // 2), str(h * 3 // 4), str(w // 2), str(h // 2), '300')
    raise AssertionError('Missing keyboard look: ' + label)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--serial')
    parser.add_argument('--before', action='store_true')
    parser.add_argument('--look', choices=('gboard', 'samsung'), default='gboard')
    opt = parser.parse_args()
    assert os.environ.get('ANDROID_SERIAL', smoke.SERIAL) == smoke.SERIAL
    assert adb('get-serialno').strip().decode() == smoke.SERIAL
    originals = {name: adb('shell', 'wm', name).decode() for name in ('size', 'density')}
    night = adb('shell', 'cmd', 'uimode', 'night').decode()
    rotation = adb('shell', 'settings', 'get', 'system', 'accelerometer_rotation').strip().decode()
    user_rotation = adb('shell', 'settings', 'get', 'system', 'user_rotation').strip().decode()
    try:
        adb('shell', 'settings', 'put', 'system', 'accelerometer_rotation', '0')
        adb('shell', 'settings', 'put', 'system', 'user_rotation', '0')
        # Select through the production chooser, including in the minified release APK.
        adb('shell', 'wm', 'size', '1968x2184')
        adb('shell', 'wm', 'density', '420')
        smoke.fresh_editor()
        adb('shell', 'input', 'keyevent', '4')
        smoke.click('Keyboard layouts & settings')
        smoke.wait_for('Pairing & connection')
        choose_look('Samsung-like' if opt.look == 'samsung' else 'Gboard-like · default')
        for form, resolution, density in (
            ('avd-native', 'reset', 'reset'),
            ('inner-portrait', '1968x2184', '420'),
            ('inner-landscape', '2184x1968', '420'),
            ('cover-portrait', '1080x2520', '420'),
            ('cover-landscape', '2520x1080', '420'),
        ):
            adb('shell', 'wm', 'size', resolution)
            adb('shell', 'wm', 'density', density)
            for theme in ('light', 'dark'):
                adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
                adb('shell', 'am', 'force-stop', smoke.PACKAGE)
                adb('shell', 'ime', 'enable', smoke.IME)
                adb('shell', 'ime', 'set', smoke.IME)
                adb('shell', 'am', 'start', '-n', smoke.PACKAGE + '/.SetupActivity', '--es', 'section', 'try')
                # The editor's heading starts below the viewport on cover landscape.
                smoke.wait_for('Try it', 60)
                focus_editor()
                keys = [n for n in smoke.nodes() if n.get('class') == 'helium314.keyboard.keyboard.Key']
                geometry = {n.get('content-desc'): smoke.bounds(n) for n in keys}
                def row(label):
                    return geometry[label][1]
                tablet = opt.before and form.startswith('inner-')
                assert row('Delete') == row('1' if tablet else 'Z'), 'Backspace row changed'
                assert row('Return') == row('A' if tablet else 'Space'), 'Enter row changed'
                if not tablet:
                    assert geometry['Delete'][0] > geometry['M'][0], 'Backspace must end row 3'
                    assert geometry['Return'][0] > geometry['.'][0], 'Enter must be bottom-right'
                    for label in ('Symbols', ',', '.', 'Return'):
                        assert row(label) == row('Space'), 'Bottom row changed'
                    shifts = [smoke.bounds(n) for n in keys if n.get('content-desc') == 'Shift']
                    assert len(shifts) == 1 and shifts[0][0] < geometry['Z'][0], 'Shift must start row 3'
                    assert '!' not in geometry and '?' not in geometry, 'Tablet punctuation added to phone row'
                    # Keep normal letter keys at about a tenth of the full width or smaller.
                    assert geometry['W'][2] - geometry['W'][0] <= smoke.size()[0] * .105, 'Letter keys too wide'
                if form == 'inner-landscape':
                    assert geometry['Y'][0] - geometry['T'][2] > smoke.size()[0] * .1, 'Landscape split missing'
                print('PASS:', opt.look, form, theme, 'tablet' if tablet else 'phone',
                      {k: geometry[k] for k in ('Q', 'Z', 'Delete', 'Space', 'Return')}, flush=True)
                data = adb('exec-out', 'screencap', '-p')
                target = smoke.OUT / ('fold-layout-' + ('before' if opt.before else 'after') + '-' + opt.look + '-' + form + '-' + theme + '.png')
                target.write_bytes(data[data.index(b'\x89PNG'):])
                assert target.stat().st_size < 2_000_000
    finally:
        for name, original in originals.items():
            override = re.search(r'Override (?:size|density): (\S+)', original)
            adb('shell', 'wm', name, override.group(1) if override else 'reset')
        adb('shell', 'cmd', 'uimode', 'night', 'yes' if 'yes' in night else ('auto' if 'auto' in night else 'no'))
        for name, value in (('accelerometer_rotation', rotation), ('user_rotation', user_rotation)):
            if value == 'null':
                adb('shell', 'settings', 'delete', 'system', name)
            else:
                adb('shell', 'settings', 'put', 'system', name, value)


if __name__ == '__main__':
    main()
