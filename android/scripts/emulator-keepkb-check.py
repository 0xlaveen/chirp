#!/usr/bin/env python3
"""Keep-my-keyboard paths. Debug APK and disposable emulator only; never print field text.

Each path is independent so floating-mic and entry-point checks can extend check().
The caller owns the disposable server and deep-link credentials.
"""
from contextlib import contextmanager
from pathlib import Path
import shlex
import time
import urllib.parse

PACKAGE = 'dev.chirp.android'
CHIRP = PACKAGE + '/.ChirpImeService'
GBOARD = 'com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME'
SERVICE = PACKAGE + '/.ChirpAccessibilityService'


@contextmanager
def secure_settings(m):
    adb = m['adb']
    originals = {key: adb('shell', 'settings', 'get', 'secure', key).decode().strip()
                 for key in ('enabled_accessibility_services', 'accessibility_enabled', 'default_input_method')}
    try:
        yield originals
    finally:
        for key, value in originals.items():
            if key == 'default_input_method' and value not in ('null', ''):
                adb('shell', 'ime', 'set', value)
            elif value == 'null':
                adb('shell', 'settings', 'delete', 'secure', key)
            else:
                adb('shell', 'settings', 'put', 'secure', key, value)


def probe(m, action, label):
    m['adb']('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
             'dev.chirp.smoke.UiHierarchy', action, shlex.quote(label))


def onboarding(m, base, token, output):
    adb, wait, click = m['adb'], m['wait_for'], m['click']
    adb('shell', 'pm', 'clear', PACKAGE)
    adb('shell', 'settings', 'delete', 'secure', 'enabled_accessibility_services')
    adb('shell', 'settings', 'put', 'secure', 'accessibility_enabled', '0')
    adb('shell', 'ime', 'set', GBOARD)
    adb('shell', 'ime', 'disable', CHIRP)
    adb('shell', 'am', 'start', '-n', PACKAGE + '/.SetupActivity')
    wait('Get started'); click('Get started')
    wait('How you’ll dictate')
    continuation = wait('Continue')
    button = next((n for n in m['nodes']() if n.get('clickable') == 'true' and any(c.get('text') == 'Continue' for c in n.iter('node'))), None)
    assert button is not None and button.get('enabled') == 'false', 'Choice must start unanswered'
    click('Keep Gboard'); click('Continue')
    wait('Turn on the floating mic')
    assert m['find']('Enable Chirp Keyboard') is None
    m['screenshot']('keepkb-disclosure')
    click('Open Accessibility settings')
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        foreground = adb('shell', 'dumpsys', 'activity', 'activities')
        if b'mResumedActivity' in foreground and b'AccessibilityDetailsSettings' in foreground:
            break
    else:
        raise AssertionError('Accessibility details screen did not open')
    adb('shell', 'input', 'keyevent', '4')
    wait('Turn on the floating mic')
    # Disclosure is long on the cover screen: scroll to the returned-off help.
    click('Did Android say “Restricted setting”?')
    click('Open Chirp app info')
    assert b'InstalledAppDetails' in adb('shell', 'dumpsys', 'activity', 'activities'), 'App info deep link failed'
    adb('shell', 'input', 'keyevent', '4')
    adb('shell', 'settings', 'put', 'secure', 'enabled_accessibility_services', SERVICE)
    adb('shell', 'settings', 'put', 'secure', 'accessibility_enabled', '1')
    # Leave and return so live service state is read exactly as on a system settings return.
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    adb('shell', 'am', 'start', '-n', PACKAGE + '/.SetupActivity')
    wait('Allow microphone')
    click('Allow microphone')
    permission = wait('While using the app'); m['tap'](permission)
    wait('Scan code')
    adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.ACCESS_LOCAL_NETWORK')
    adb('shell', 'am', 'force-stop', PACKAGE)
    adb('shell', 'run-as', PACKAGE, 'mkdir', '-p', 'shared_prefs')
    adb('shell', 'run-as', PACKAGE, 'sh', '-c', shlex.quote('cat > shared_prefs/debug_capture.xml'),
        data=b'<map><boolean name="synthetic" value="true" /></map>')
    link = 'chirp://pair?' + urllib.parse.urlencode({'url': base, 'token': token})
    adb('shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', shlex.quote(link))
    wait('Finish'); click('Finish')
    assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == GBOARD
    print('PASS: fresh choice, disclosure, Accessibility details, restricted help/app info, enable/resume, microphone, deep-link pairing, Gboard retained.', flush=True)


def settings(m, output):
    adb, wait, click = m['adb'], m['wait_for'], m['click']
    adb('shell', 'am', 'start', '-n', PACKAGE + '/.SetupActivity', '--es', 'section', 'input')
    wait('How you dictate')
    click('Use Chirp Keyboard')
    click('Choose keyboard')
    wait('Gboard'); wait('Chirp Keyboard')
    assert b'InputMethod' in adb('shell', 'dumpsys', 'window', 'windows'), 'Keyboard picker missing'
    adb('shell', 'input', 'keyevent', '4')
    click('Keep Gboard')
    print('PASS: Settings mode switches and system keyboard picker.', flush=True)


def ime_visibility(m, output):
    adb = m['adb']
    adb('shell', 'ime', 'enable', CHIRP)
    adb('shell', 'ime', 'set', CHIRP)
    adb('shell', 'am', 'start', '-n', PACKAGE + '/.EditorProbeActivity')
    m['click']('Plain field')
    m['wait_for']('Microphone: tap to dictate')
    assert m['find']('Chirp microphone:') is None, 'Floating mic duplicated Chirp IME mic'
    adb('shell', 'ime', 'set', GBOARD)
    m['wait_for']('Chirp microphone:')
    assert adb('shell', 'settings', 'get', 'secure', 'default_input_method').decode().strip() == GBOARD
    m['screenshot']('keepkb-gboard-bubble')
    print('PASS: bubble hidden with Chirp selected and present with Gboard; Gboard retained.', flush=True)


def check(m, work, output, base, token):
    with secure_settings(m):
        onboarding(m, base, token, output)
        settings(m, output)
        ime_visibility(m, output)
        m['crash_check']()
    print('PASS: keep-keyboard checks; secure settings restored. Real restricted blocking, Advanced Protection and OEM policy need device acceptance.', flush=True)
