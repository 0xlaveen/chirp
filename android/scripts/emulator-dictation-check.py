#!/usr/bin/env python3
"""Native watcher for real IME tap/hold, partial/final, Ripple evidence and typing."""


def check(p, work, output):
    adb = p['adb']
    failures = []
    for theme in ('light', 'dark'):
        adb('shell', 'cmd', 'uimode', 'night', 'yes' if theme == 'dark' else 'no')
        p['fresh_editor']()
        for mode in ('tap', 'hold'):
            # #172: press-and-hold on the strip mic is the reachable push-to-talk gesture (release finishes).
            target = p['wait_for']('Microphone: tap to dictate')
            x, y = p['center'](target)
            remote = '/sdcard/chirp-listening.png'
            adb('shell', 'rm', '-f', remote)
            try:
                adb('shell', 'CLASSPATH=/data/local/tmp/chirp-ui-probe.jar', 'app_process', '/',
                    'dev.chirp.smoke.UiHierarchy', 'dictation-cycle', mode, str(x), str(y), remote)
            finally:
                try: adb('pull', remote, str(output / (theme + '-' + mode + '-listening.png')))
                except RuntimeError: pass
            # Keep the all-window dump beside the post-final screenshot; only synthetic text.
            p['nodes']()
            (output / (theme + '-' + mode + '-final.xml')).write_bytes(adb('shell', 'cat', '/sdcard/chirp-windows.xml'))
            print('PASS:', theme, mode, 'partial/final; listening screenshot captured on device', flush=True)
    p['crash_check']()
    assert not failures, '; '.join(failures)
