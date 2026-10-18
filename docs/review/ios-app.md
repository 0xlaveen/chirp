# iOS app/project track — 2026-10-18

Owned implementation: `ios/App`, `ios/Config`, `ios/scripts`, generated
`ios/Chirp.xcodeproj`, app unit/UI tests. Foundation and keyboard owners' changes
were integrated from `chirp/ios`; their directories were not edited by this track.
No push, PR, main merge, toolchain install, physical-device install or Apple login.

## Runtime implementation

`@MainActor SessionCoordinator` is the single app-process audio/session owner.
It uses the real local `ChirpIOSCore` stores/bridge and `ChirpCore.StreamSession`,
`PCMConverter`, health/profile/protocol/timing types. No duplicated wire codec.
Only Debug compiles synthetic in-memory test dependencies; Release constructs
real Keychain, App Group, authenticated HTTPS/WebSocket and AVAudioEngine adapters.

- Camera QR and secret paste input both use strict shared pairing validation;
  authenticated connection verification precedes Keychain storage. No token or
  pairing link is rendered in diagnostics. Production uses ephemeral sessions,
  system TLS and the shared no-redirect delegate. Saved Mac host/engine is visible.
- The recording audio session and engine remain active throughout an armed
  session. Idle buffers are discarded before conversion, queuing or networking.
  One locked capture sink serializes converter use, ready gating and flush;
  no task is created per audio frame. No audio is written to disk.
- Pre-ready PCM is capped at 64 KiB; StreamSession independently bounds queued
  PCM and total bytes. Capture requests stop at 119 seconds wall time or 119.8
  seconds PCM, reserving 200 ms up to the protocol's hard 120 seconds for flush.
  Stop before Ready retains bounded audio/tail until Ready and then sends Stop.
  Ready deadline is 10 seconds in shared StreamSession, final wait 20 seconds,
  polishing 12 seconds. Correcting timeout/disconnect keeps the raw result.
- Capture limit/failure callbacks are bound to lifecycle AND utterance UUID;
  old callbacks cannot stop/fail a subsequent utterance in the same armed session.
  Interruptions, route changes, engine changes, permission loss, expiry and End
  stop/reconcile capture safely. Own category-change/startup notifications are
  excluded; interrupted capture never silently resumes.
- Session choices are 5 minutes, 15 minutes, 1 hour and Never. Expiry has its own
  task plus foreground/heartbeat reconciliation. Never remains subject to iOS
  suspension, interruption and process termination. End clears transient text,
  timing data, clipboard target, waiters and encrypted mailbox payloads.
- A successful Live Activity start is required before capture. The app refreshes
  its content and 15-second stale date on each 2-second heartbeat, including armed
  idle; a dismissed/stale activity ends capture. App Group lease is 8 seconds.
  An expired generation cannot be resurrected by a late heartbeat.
- Keyboard commands use the shared encrypted mailbox and payload-free Darwin
  wake hints. UUID/generation checks and monotonic per-utterance result sequences
  fence stale events. Finished utterance ownership remains published for final
  and 5-second Use raw consumption. Available styles come from authenticated
  profiles; keyboard-selected styles are validated and persisted.
- Clean-up starts off. Enabling requires explicit destination consent; unknown
  external destinations are unavailable. Health is checked before each utterance,
  and destination changes suspend consent. Authenticated profile prompts support
  scalar limits, empty edits and reset. Use raw updates the same encrypted history
  entry by its retained ID; it never synthesizes a replacement entry after disable.
- Normal app/keyboard finals never write the clipboard. Explicit Copy/Share and
  history Copy are user actions. Companion starts mark only their own utterance
  for explicit final copying. Cancel/End/expiry clear that marker, and delayed
  finals cannot copy. Concurrent Stop callers have separate continuations.
- Opt-in history uses shared AES-GCM storage, 200-entry cap, 24-hour/7-day/30-day
  retention, search, original/copy/delete/clear and delete-key-on-disable. Private
  session mode suppresses history. Hidden/background history clears its in-memory
  list/search and does not reload. Opaque scene shields cover inactive/background
  content, including the camera sheet. A scene privacy window is installed on
  willResignActive to also cover system share sheets before app-switcher snapshots.
- Native adaptive scrolling layouts, Dynamic Type, large controls, VoiceOver
  labels and local status updates, Reduce Motion handling, and keyboard shortcuts
  are implemented. Word timing state is retained internally. Diagnostics export
  only version/OS, phase, fixed local codes, durations and counts.

## Coordinator/extension contract

App and app-process intents use:

```swift
@MainActor SessionCoordinator.shared.perform(action: SessionAction) async throws -> String
enum SessionAction { case start, stop, cancel, end }
```

Errors propagate rather than claiming success. Returned strings are content-free
local status, never transcript text. Stop of an app/keyboard utterance does not
copy it merely because Stop was invoked by an intent. The app calls the keyboard
owner's `ChirpLiveActivity` begin/update/isActive/end facade.

App target includes `App/**` and `Intents/*.swift`, with `CHIRP_APP`. Keyboard
target includes its two root Swift files and links `KeyboardPolicy`. Widget
target includes `Widgets/ChirpWidgets.swift`, `SessionIntents.swift` and
`ChirpActivityAttributes.swift`, without the coordinator, capture code,
`ChirpLiveActivity.swift` or `CHIRP_APP`. App-process routing of intent buttons
remains an iOS SDK/device acceptance check; extension fallback throws setup error.

## Reproducible project

Python 3 standard library generates the checked-in project without XcodeGen:

```sh
python3 ios/scripts/generate-project.py
ios/scripts/check-sources.sh
ios/scripts/toolchain.sh
ios/scripts/simulator.sh build EXPLICIT_SIMULATOR_UUID
ios/scripts/simulator.sh test EXPLICIT_SIMULATOR_UUID
ios/scripts/simulator.sh ui EXPLICIT_SIMULATOR_UUID
```

Only available iPhone/iPad Simulator UUIDs from `simctl` are accepted. Build/test
uses unsigned `iphonesimulator`, never a physical-device destination. Repeat test
and UI commands with one explicit iPhone and one explicit iPad UUID after Xcode is
available. Schemes: `ChirpIOS` (unit) and `ChirpIOS-UI` (UI). Debug explicitly enables
testability; Release disables it. Both schemes explicitly build their test target.

`Config/Local.xcconfig` is untracked and can override `CHIRP_BUNDLE_ID`,
`CHIRP_APP_GROUP`, `CHIRP_KEYCHAIN_ACCESS_GROUP` and `DEVELOPMENT_TEAM`. Default
keychain prefix is `$(AppIdentifierPrefix)`; no team ID is invented. Both embedded
extensions have CodeSignOnCopy/RemoveHeadersOnCopy and matching group settings.
App has microphone/camera strings, background audio, Live Activity support,
`chirp` URL scheme, iPhone+iPad families and no arbitrary ATS exception. Keyboard
has the source principal class, Full Access declaration and no microphone usage
or background mode. Asset catalog reuses the exact approved 1024px Mac PNG;
structural check verifies SHA-256 equality and app-icon/resource settings.

## Actual evidence and pending checks

Host: Apple Swift 6.4, `/Library/Developer/CommandLineTools`; full Xcode absent.

- `ios/scripts/check-sources.sh`: **PASS**. Project graph, 5 targets, both embedded
  extensions, 2 test schemes, 18 Swift memberships, all plists/entitlements,
  package/config/testability/test-host/icon checks and per-target Swift syntax.
  This is structural/syntax evidence, **not an iOS compile or test execution**.
- Regeneration twice produced identical `project.pbxproj` bytes (SHA-256
  `47821565063abb9c233ac8f8483db3b5b1a3e8ad67c052427d8cba9214c371e1`).
- `ios/scripts/toolchain.sh` exits 2 with “BLOCKED: select a full Xcode
  installation with an iOS Simulator SDK.” No toolchain was installed.
- `ios/scripts/typecheck-catalyst.sh`: **PASS with zero warnings** after fixes.
  This is an optional reproducible compiler aid
  using the **existing Mac SDK's Catalyst headers**. It emits modules for Core,
  Shared (including `#if os(iOS)` paths), then typechecks SessionCoordinator,
  MicrophoneCapture, PairingScanner, DebugFixtures and PrivacyController. ActivityKit is unavailable
  on Catalyst, so a temporary compiler-only facade supplies its signatures; it
  is never part of the iOS project. No runtime is exercised.
- This aid found shared `setAttributes(_:atPath:)` in an iOS-only branch;
  orchestrator corrected it to `ofItemAtPath:` on `chirp/ios`. It also identified
  the scanner's cross-queue output capture, now owned by its serialized camera
  session. A full-view Catalyst attempt is blocked by absent `SwiftUIMacros`
  plugin in CLT. Actual ActivityKit, SwiftUI views, App Intents, Widgets and
  keyboard UIKit compile paths remain pending the iOS SDK.
- Fourteen app unit-test functions and two UI tests are written, not executed.
  Synthetic inputs cover Ready/partial/correcting/final/timings, explicit copy,
  companion ownership, repeated Stop waiters, delayed finals, expiry, permissions,
  Live Activity loss, duplicate starts, stale capture callbacks, history/raw/privacy,
  pre-ready overflow, flush ordering and the 120-second byte limit. UI tests use
  Debug-only injected transport/audio and private temporary storage; no real
  mic, server, Keychain credentials or TLS relaxation.

Full unsigned iOS Simulator build/unit/UI runs on both form factors, accessibility
inspection, all shipping framework availability and signing/profile validation
are **pending**. No simulator/hardware execution is claimed. Shared/Mac/policy
test evidence belongs to the respective track review reports; this track did
not rerun those unchanged suites.

Final successful source/compiler job: Koi run 2026-10-18T06:06:39Z, exit 0
in 6 seconds; 18 memberships (app10/keyboard2/widget3/unit2/UI1), all structural,
plist, parse and focused Catalyst checks passed. Log:
`/Users/rex/.koi/run-logs/416b5f88-d92d-4f5f-ba2e-33d2b3464dce-20261018T060639-43332.log`.
No runtime test count is attributed to that job. Privacy covers are explicitly
sized from each UIWindowScene coordinate space, without UIScreen.main.

## Operator acceptance after Xcode

In addition to M5's device matrix: verify denied/retried camera and microphone;
scan/paste pairing; own category changes versus real interruptions; app-owned
armed idle recording with zero idle PCM network traffic; explicit keyboard
handoff/manual fallback; companion-only fresh clipboard writes; each expiration
choice; Live Activity dismissal/stale status; no delayed copy after End; cleanup
destination changes; history retention, disable and Use raw; light/dark, maximum
Dynamic Type, VoiceOver, Reduce Motion, hardware shortcuts and narrow iPad.

For snapshot privacy, open a final transcript, expanded history result/search,
edited prompt and camera sheet separately, switch away and inspect app-switcher
cards on iPhone and iPad. Only the opaque Chirp shield should appear. Return and
verify history search was cleared/reloaded only when its tab is visible. Simulator
checks cannot establish microphone background survival, keyboard URL handoff,
provisioning capability or locked-device intent routing on hardware.
