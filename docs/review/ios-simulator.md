# iOS 27 simulator UI gate — 2026-10-19

Issue: https://github.com/araa47/chirp/issues/7. Based on
`koi/chirp-ios-keyboard-9895aa`; this change does not modify `ios/Keyboard/**`.
This report supersedes the pending simulator checks in `ios-app.md` for the
commands and configurations below. It makes no physical-device claims.

## Changes

App dictation, Stop, Use raw, End and history controls have stable accessibility
identifiers. The pairing form dismisses its secure-field keyboard when saving;
otherwise that keyboard obscures the iPhone tab bar and taps never change tabs.
UI tests distinguish content controls from tab controls, handle iPadOS 27's top
tab buttons (which have no TabBar ancestor), and query the history toggle by
identifier across element types. History remains asserted off in both portrait
and landscape. The transcript/raw/End assertions are retained.

The DEBUG-only keyboard host requires both `--chirp-ui-test` and
`--chirp-keyboard-host`, and the latter is enabled only on a simulator. Its real
UITextView is `chirp.host.text`, initially `Host prefix. `. The synthetic
coordinator uses the real App Group container, shared Keychain and encrypted
mailbox in this mode, including normal command observation and heartbeat work.
HTTP and WebSocket replies and audio remain synthetic; no microphone permission,
recording, real server or real pairing secret is needed. Ordinary app UI tests
continue to use isolated temporary storage and in-memory secrets.

`ChirpKeyboardUITests` runs in `ChirpIOS-UI`. It opens the real Settings app,
navigates General → Keyboard → Keyboards, adds Chirp if absent, enables Full
Access (including the system confirmation), returns to the host and selects
Chirp in the system globe/input-mode list. Setup is idempotent on the two
disposable simulators, so keyboard state did not need a reset. iOS 27 exposes
nested switches in Settings: tap the child control, then verify the containing
switch value. A setup attachment records whether the real shared session armed.

After the keyboard status identifier is available, the test checks the keyboard
controls, armed status, primary action and real mailbox partial/final insertion:
`Host prefix. synthetic words` → `Host prefix. Synthetic words.`. Ending the
session must leave the final text untouched. These insertion assertions are
written but **not yet exercised on this head**, because the parallel keyboard
identifier change has not been integrated. Only identifiers from issue #7 are
used to query extension content; system Settings and input-mode menu labels are
used to configure/select the extension.

## Simulator signing experiment

`CHIRP_SIMULATOR_SIGNING=unsigned ios/scripts/simulator.sh ui
828F0310-54C8-4DD6-8D96-4C32F03448DB` passed the two app tests but the fixture
attachment reported `Simulator shared App Group/Keychain unavailable`.
The unsigned run log is
`~/.koi/run-logs/23f5689e-2493-4715-916c-857850746d7e-20261019T054429-75028.log`.

The default is now simulator ad-hoc signing: `CODE_SIGN_IDENTITY=-`,
`CODE_SIGNING_ALLOWED=YES`, `CODE_SIGNING_REQUIRED=YES`, `CODE_SIGN_STYLE=Manual`,
`DEVELOPMENT_TEAM=`. Xcode emits App Group/shared-Keychain simulated entitlements
into the simulator executable (`*-Simulated.xcent` / `__TEXT,__entitlements`),
including its own simulator application-identifier prefix. No team identifier
is invented by the script. The fixture attachment reports
`Synthetic shared session armed` with this configuration on both simulators.
`codesign -d --entitlements -` alone shows an empty signature entitlement dict
on this SDK; inspect the simulated entitlements and runtime evidence instead.
No Apple ID, provisioning update, physical device or signing account was used.

## Full validation

Host: Xcode 27 (`27A266a`), iPhoneSimulator27.0 SDK, iOS 27.0 (`24A434`).
Exact successful command, launched through `koi run -- sh -c '…'`:

```sh
set -eu
ios/scripts/check-sources.sh
for id in 828F0310-54C8-4DD6-8D96-4C32F03448DB 3BFCBCF2-7FAF-4397-A367-06522D11B150; do
  ios/scripts/simulator.sh build "$id" &&
  ios/scripts/simulator.sh test "$id" &&
  ios/scripts/simulator.sh ui "$id"
done
ios/Shared/scripts/test.sh
```

| Check | Result |
| --- | --- |
| Source/project/plist/entitlement/syntax checks | Pass; 5 targets, 2 test schemes, 19 Swift memberships |
| iPhone 17 `828F0310-54C8-4DD6-8D96-4C32F03448DB` build | Pass |
| iPhone 17 app unit tests | 15 tests in 2 suites passed |
| iPhone 17 UI tests | 2 passed, 1 skipped, 0 failures |
| iPad Pro 11-inch (M5) `3BFCBCF2-7FAF-4397-A367-06522D11B150` build | Pass |
| iPad Pro 11-inch (M5) app unit tests | 15 tests in 2 suites passed |
| iPad Pro 11-inch (M5) UI tests | 2 passed, 1 skipped, 0 failures |
| Shared core SwiftPM tests | 20 tests in 5 suites passed |

Both UI skips have exactly this reason: `Installed keyboard has no
chirp.keyboard.status yet; waiting for the parallel keyboard identifier change.`
Settings addition, Full Access and input-mode selection reached completion on
both devices in this final run. The missing-identifier wait is 10 seconds.
After the keyboard worker's change is integrated, status existence makes the
test assert the end-to-end path. Genuine simulator Settings/entitlement setup
limitations also produce a specific XCTSkip reason rather than a false pass.

Successful full-gate job: started `2026-10-19T05:46:58Z`, exit 0 in 4m27s.
Log:
`~/.koi/run-logs/23f5689e-2493-4715-916c-857850746d7e-20261019T054658-76537.log`.
Results in `ios/DerivedData/Logs/Test/`:

- `Test-ChirpIOS-2026.10.19_12-47-04-+0700.xcresult` (iPhone unit)
- `Test-ChirpIOS-UI-2026.10.19_12-47-25-+0700.xcresult` (iPhone UI)
- `Test-ChirpIOS-2026.10.19_12-49-07-+0700.xcresult` (iPad unit)
- `Test-ChirpIOS-UI-2026.10.19_12-49-28-+0700.xcresult` (iPad UI)

Only the two simulator UUIDs above were used by this worker. Real microphone,
background recording, physical-device entitlements and real-server dictation
remain outside this simulator evidence.
