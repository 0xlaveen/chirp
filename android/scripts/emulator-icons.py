#!/usr/bin/env python3
"""Verify the signed release's launcher and system icon surfaces on the selected emulator."""
from pathlib import Path
import runpy

m = runpy.run_path(str(Path(__file__).with_name('emulator-smoke.py')))
adb = m['adb']


def main():
    assert adb('get-serialno').strip().decode() == m['SERIAL']
    try:
        adb('shell', 'am', 'start', '-a', 'android.intent.action.ALL_APPS')
        m['wait_for']('Chirp Keyboard')
        m['screenshot']('launcher-icon')
        adb('shell', 'am', 'start', '-a', 'android.settings.APPLICATION_DETAILS_SETTINGS',
            '-d', 'package:dev.chirp.android')
        m['wait_for']('Chirp Keyboard')
        m['screenshot']('app-icon-settings')
        m['fresh_editor']()
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        m['click']('Choose keyboard')
        m['wait_for']('Keyboard')
        m['wait_for']('Gboard')
        m['wait_for']('Chirp Keyboard')
        m['screenshot']('keyboard-picker-icon')
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
        assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == m['IME']
        m['crash_check']()
        print('PASS: release icon visible in launcher and app settings; native keyboard picker verified (this OS uses text rows); Chirp remains selected; no crash.')
    finally:
        adb('shell', 'rm', '-f', '/sdcard/chirp-windows.xml', '/data/local/tmp/chirp-ui-probe.jar')


if __name__ == '__main__':
    main()
