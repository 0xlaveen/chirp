# iOS integration handoff — 2026-10-18

Source is integrated on `chirp/ios`, based on `main` at `e4d9e6d`. This is a
source handoff awaiting full Xcode and operator acceptance, **not an installable
iOS release**. No iOS SDK build, simulator execution, signing/profile validation
or physical-device operation has occurred. No push, PR or merge into main.

## Integrated work

- Foundation `7736656`, `5419f3b`: iOS-capable ChirpCore, strict tailnet pairing,
  Keychain credentials, AES-GCM history/mailbox, replay/expiry fencing and Darwin
  wake notifications. Mac hotkey/insertion APIs retain their macOS implementations.
- Keyboard `0edf93d`, `f58e97c`: UIKit dictation controls, exact-context text
  replacement with per-delete checks, app-process intents/Shortcuts, Live Activity
  and Control Center controls. Long results are bounded at 8,192 UTF-16 units;
  actual context truncation still stops automatic replacement safely.
- App `c4cf80a`, test refinement `8182867`: SwiftUI iPhone/iPad app, microphone
  session owner, QR/paste pairing, styles/consent, copy/share/raw, opt-in history,
  private-session control and inactive-scene covers. Reproducible checked-in
  project embeds both extensions and packages the approved existing icon.
- Documentation through `9390fad`: [operator guide](../../ios/README.md),
  repository indexes and [M5 spec/checklist](../milestones/M5-ios.md).
- Integration glue `530bce0`: server accepts `client: "ios"` alongside existing
  values; protocol stream/reuse tests cover all three. `c4aadd6` corrects the
  file-protection API argument label found by the compiler aid.

Reviews led to completed-text preservation on End/Cancel, concurrent Stop waiter
handling, atomic history Use raw updates, stale callback/clipboard fencing,
bounded capture/flush, expiring activity state, fewer mailbox rewrites and
accurate privacy/validation documentation. No shipping code changed after the
app merge `59d208a`; subsequent changes were tests and documentation.

## Integrated validation

Detached Koi job `/tmp/chirp-ios-verify.sh` exited **0** after **2m22s**.
Log: `/Users/rex/.koi/run-logs/a23a9a66-3474-4dcf-b157-ea8216d0bfb6-20261018T060915-50085.log`.
Portable suites ran on the integrated shipping sources; the test-only follow-up
and docs landed during the job. Final per-target syntax checks include the app
test files. The working tree was clean after the job.

| Command/check | Actual result |
|---|---|
| `mac/scripts/test.sh` | 380 tests in 61 suites passed |
| `cd mac && swift build -c release` | Release build passed |
| `ios/Shared/scripts/test.sh` | 20 tests in 5 suites passed |
| KeyboardPolicy SwiftPM tests with CLT Testing plugin | 22 test functions passed |
| 2K-character partial/correcting/final/raw fake-host flow | Passed; 6,144 checked deletes, about 78 ms in this run |
| `ios/scripts/check-sources.sh` | 5 targets, 2 embedded extensions, 2 test schemes, 18 Swift memberships; project/plist/entitlement/icon checks and syntax passed |
| `ios/scripts/typecheck-catalyst.sh` | Focused compiler aid passed, no warnings |
| Server `pytest -q` using existing environment and this checkout's `PYTHONPATH=src` | 256 passed, 7 real-model tests deselected |
| Server `ruff check .` / `ruff format --check .` | Passed; 51 files formatted |
| `ios/scripts/toolchain.sh` | Expected exit 2: full Xcode/iOS Simulator SDK absent |
| `git diff --check` | Passed |

The Mac build retains existing CLT search-path and AppKit animation/sendability
warnings. The focused Catalyst aid uses existing Mac SDK headers and substitutes
only a temporary Activity facade. It checks Core/Shared iOS branches and the
coordinator, capture, scanner, fixtures and privacy-window code. It **does not**
validate SwiftUI views, actual ActivityKit, keyboard UIKit, App Intents, Widgets,
linking, extension process routing or any iOS runtime behavior. Full-view
compilation lacks the SwiftUIMacros plugin under CLT.

Fifteen app unit-test functions (including blank-final parameter cases) and two
UI tests are written but **unexecuted**. Track detail:
[foundation](ios-foundation.md), [keyboard](ios-keyboard.md), [app](ios-app.md).

## Remaining operator gates

The required single Koi question requested permission/install method for full
Xcode, operator-owned Apple ID login, developer membership/Team ID and iPhone/iPad
models/OS versions. No toolchain installation or account operation was attempted.

After Xcode is available, follow [the install guide](../../ios/README.md#install-operator-steps):

1. Select/initialize full Xcode and matching iOS SDK/runtime; regenerate/open
   `ios/Chirp.xcodeproj`. Set the team and consistent bundle/App Group/keychain
   identifiers in untracked `ios/Config/Local.xcconfig`.
2. Run `ios/scripts/simulator.sh build`, `test` and `ui` with explicit available
   simulator UUIDs for **both** iPhone and iPad. Fix SDK/compiler/runtime findings
   before hardware installation. Check the shared/policy packages on simulators too.
3. Operator connects/trusts each device, enables Developer Mode, chooses ChirpIOS
   and Runs in Xcode over the existing install. Verify every extension profile;
   actual free-account capabilities are not guaranteed. Free profiles expire
   after seven days; distribution options need appropriate membership/profiles.
4. Run M5's on-device checklist: background capture/interruptions/expiry, honest
   microphone indicator, first-tap manual handoff fallback, safe text ownership,
   activity/intent routing, clipboard ownership, history/privacy, snapshot covers,
   accessibility and iPad multitasking/hardware-keyboard behavior.

The running production speech server was untouched. Before iOS dictation,
operator must run the updated server accepting the new client label. No Tailscale,
LaunchAgent or production configuration was changed.

All four child workers completed and were reaped after review. Their branches
and commits remain available; no workers or validation jobs remain outstanding.
