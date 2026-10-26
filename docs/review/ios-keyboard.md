# iOS keyboard, intents and activity evidence

Date: 2026-10-18. Track: `ios-keyboard`. Personal-install implementation for
M5; full iOS SDK build and simulator/runtime acceptance remain pending. No push,
PR, main merge, physical installation, Apple ID operation or service was performed.

## Source membership and integration contract

Deployment target is iOS/iPadOS 18. The project/configuration owner is `ios-app`.
Do not recursively compile all of `ios/` into every target.

| Sources/product | ChirpIOS app | ChirpKeyboard | ChirpWidgets |
|---|---|---|---|
| `Keyboard/ChirpKeyboardViewController.swift` | no | yes | no |
| `Keyboard/KeyboardBridgeClient.swift` | no | yes | no |
| Local package `Keyboard/Policy`, product `KeyboardPolicy` | no | link | no |
| Local package `Shared`, product `ChirpIOSCore` | link | link | no |
| `Intents/SessionIntents.swift` | yes | no | yes |
| `Intents/ChirpActivityAttributes.swift` | yes | no | yes |
| `Intents/ChirpLiveActivity.swift` | yes | no | no |
| `Widgets/ChirpWidgets.swift` | no | no | yes |

Do not add `Keyboard/Policy/Package.swift` or its `Tests/` as extension source
files. Its `Sources/KeyboardPolicy` are built by SwiftPM. Keyboard principal:
`$(PRODUCT_MODULE_NAME).ChirpKeyboardViewController`. Widget bundle:
`ChirpWidgetsBundle`, the **only** `@main` in the widget target. App retains its
separate app entry point. `ChirpShortcuts` exposes four App Shortcuts.

Set `CHIRP_APP` in **app only** `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, retaining
inherited settings. Each intent conforms to `AudioRecordingIntent` and
`LiveActivityIntent`, selecting the containing app process. The app compilation
calls `try await SessionCoordinator.shared.perform(action:)` with `SessionAction`
`.start/.stop/.cancel/.end`, returning a content-free local status `String`.
The widget compilation has no coordinator dependency and throws a fixed setup
message if incorrectly run there. Never include coordinator or capture sources
in the widget. Start uses `openAppWhenRun = true` for foreground permission/setup;
Stop/Cancel/End can act on the existing session in the app process. This does not
promise cold background microphone access. Companion Stop explicitly copies
only that companion utterance's fresh final; stopping a keyboard utterance must
not copy it. `ios-app` confirmed this routing/ownership contract.

`@MainActor ChirpLiveActivity` is app-only: `begin(debugRetention:) throws`,
`update(phase:debugRetention:) async`, `end() async`, `isActive: Bool`.
App must begin successfully **before** capture, update on its two-second heartbeat
and state changes, stop capture when `isActive` is false, and end activity on
teardown. Disabled/unavailable Live Activities refuse session recording. A
15-second `staleDate` prevents indefinite healthy status after a crash; lock screen,
compact and minimal presentations expose expiry. Staleness is a UI warning,
not proof that a crashed process can be commanded. Activity state contains only
an allowlisted phase enum and debug-retention boolean; attributes contain no
transcript, hostname, URL, prompt, credential or arbitrary coordinator string.

Shared APIs are owned by `ios-foundation`, separately committed and merged by
the parent. `KeyboardBridgeClient` uses `SharedConfiguration(bundle: .main)`,
`containerURL()`, `KeychainSecretStore(accessGroup:)`, and
`SharedBridge(root:secrets:role: .keyboard)`. It calls `state()`, `send(_:)`, and
`takeResults(generation:utteranceID:)`. Keep configured App Group and Keychain
group identical across app and keyboard. Shared bridge encrypts mailbox contents;
keyboard never writes transcript defaults/files itself. Signal is
`DarwinSignal(name: DarwinSignal.bridgeChanged)`, with retained observation and
payload-free `post()`. App posts after publishing; keyboard re-reads on appearance,
signal, and a visible-only 0.5-second reconciliation timer. Appearance invalidates
and replaces any prior timer; disappearance stops it and releases the observer.

App preserves the keyboard-created UUID on `.start` and publishes increasing
`BridgeResult.sequence` per utterance. `BridgeState` includes generation,
utteranceID, lease, phase, debugRetention, styleID and authenticated
`availableStyleIDs` (including custom/server profiles). App validates/persists
`.style(id)` using its preferences/consent rules and retains finished utteranceID
for final/Use raw consumption. Keyboard never selects an undisclosed cleanup
destination or edits prompts. Shared `takeResults` atomically consumes results;
replay receipts remain encrypted. Command TTL is at most five seconds and bounded
by the current app lease. Lease expiry or generation change invalidates ownership.

## Behavior and safety

### Voice-first layout and presenter

> **Superseded in part by #245:** Chirp Keyboard is now a full typing keyboard (KeyboardKit 9.9.1's MIT core under
> Chirp's strip; see `ios/README.md` and `ios/Keyboard/Typing`). The primary control moved into the strip, the chips
> take over the suggestion row, End session sits behind ⓘ and KeyboardKit owns Space, Delete (repeat), Return and the
> globe. The ownership and presenter rules below still hold.

The keyboard was voice-first (no QWERTY; users kept Apple's keyboard for typing).
All decisions live in the pure `KeyboardPresenter.screen(_:)` in the
`KeyboardPolicy` package (no UIKit, no ChirpIOSCore): `KeyboardInputs` mirrors
phase, lease, session expiry, style, debug retention, error code, ownership
flags, raw window, start-pending, fallback, recording start, globe and compact
height, plus `now`; `KeyboardScreen` returns the status/detail/warning text,
primary action (kind, title, SF symbol, hint, enabled), enabled flags, raw
countdown, style menu items and the visibility flags. `KeyboardPhase` and
`KeyboardError` mirror `SessionPhase`/`DiagnosticCode` raw values (a test pins
them). `ChirpKeyboardViewController` only gathers inputs and applies the result.
Also in the package: `RecordingClock` (keyboard-local elapsed timer), `ClockText`,
`KeyRepeat` (Delete cadence) and `KeyboardMetrics` (layout rules).

- Primary button (≥ 64 pt): *Open Chirp to start session* (no session or lease) → *Start dictation* (armed/finished; *Starting…* while the
  start is pending) → *Stop dictation* (connecting/listening) → disabled
  *Polishing…*. The separate Open Chirp key is gone; a small *Open Chirp* link
  shows only when a fallback message or recovery state is on screen. Without
  Full Access the primary is a disabled *Full Access required*.
- Status: phase, elapsed time (only for an utterance this keyboard owns,
  from its first observation of connecting/listening) and `sessionExpiresAt`
  remaining (omitted for Never), joined with " · ". Raw shows its remaining
  whole seconds (rounded up) during the 5 s window.
- Secondary row: Cancel, Use raw, Style. Bottom row: globe (only when
  `needsInputModeSwitchKey`), Space, Delete, Return, End session.
- Delete repeats while held (0.4 s pause, then accelerating to ~28/s). It stops
  on touch-up/cancel, on hide, when ownership is invalidated, and if the keyboard
  acquires an utterance; its edits are local and never touch an owned suffix.
  Space/Delete/Return still invalidate ownership. VoiceOver activation performs
  one press and release.
- `BridgeState.errorCode` maps to fixed, short guidance with no content from the
  transcript, host or server (`KeyboardError.guidance`); recovery/fallback
  messages outrank it.
- Light `UIImpactFeedbackGenerator` haptic on start/stop, only with Full Access.
- iPad (width ≥ 600, regular height): larger keys, 12 pt spacing, 24 pt insets,
  primary capped at 440 pt and centered. Compact height (landscape iPhone):
  36 pt secondary keys, 6 pt spacing and the detail line collapses.
- Dynamic Type text styles, VoiceOver labels/hints/values, and identifiers
  `chirp.keyboard.{primary,status,detail,cancel,raw,style,end,space,delete,return,globe}`
  (plus `chirp.keyboard.open` for the fallback link). `chirp.keyboard.status`
  carries the full composed status line.

### UIKit nil context (empty field, caret at start/end)

Found by the simulator UI test: `UITextDocumentProxy` returns `nil` for
`documentContextBeforeInput` at the start of a document, usually `nil` for the
after context at the end, and `nil` for both in an empty field. `CursorContext.isUsable`
refused any `nil`, so dictating into an empty field or at the start of text was
silently refused (the keyboard showed "Text kept in place"). `CursorContext.init`
now takes `hasText` (the adapter passes `textDocumentProxy.hasText`) and
normalises `nil` to `""` only where that is provable:

| before | after | hasText | result |
|---|---|---|---|
| nil | text | any | caret at start: before = "" |
| text | nil or "" | any | caret at end: after = "" |
| nil | nil | false | empty field: both "" |
| nil | nil | true or unknown | ambiguous: still unusable |
| any | any | contradicts context (e.g. false with text, true with both empty) | unusable |

Selection, `uncertain`, size bounds and grapheme rules are unchanged. Safety still
rests on `VerifiedEditor`: every edit re-reads the host and stops on any mismatch.
A host that lies about being empty gets at most one insertion that is then checked
(refused if the context disagrees) and never a deletion of text it did not insert;
a host that ignores an insertion produces zero deletions (tested). A host that
hides text *after* the caret can still not be distinguished from end-of-document,
but deletion only ever touches the owned suffix before the caret. Tests:
`CursorContextTests.swift` (normalisation table, equality across `nil`/`""`
spellings, a UIKit-like fake host for empty field, caret at start, middle and end
with `nil` or `""` after, ambiguous nil refused before any edit, ignored insert,
cancel in an empty field). Simulator evidence: `ChirpKeyboardUITests` dictates
into the real keyboard with a prefix and with an empty host field
(`--chirp-keyboard-host-empty`); the caret in the prefix case is placed by tapping
below the text, as a user would. No device claims.

No IPC message, audio, network or clipboard was added; `OwnedInsertion`,
`VerifiedEditor` and the bridge protocol and bounds are unchanged. Layout and
accessibility behaviour have only been compiled for the simulator SDK, not
exercised.

No keyboard audio or network capture exists. With Full Access denied/revoked,
keyboard immediately drops the bridge and ownership, performs no IPC, explains
setup, and retains space/delete/return/globe. Revocation means cancellation cannot
be guaranteed; use the app/activity End control to stop the armed session. On hide
with access, best-effort cancel is limited to a matching generation and current
keyboard-owned active utterance. It never cancels another app/companion UUID or
ends the armed session. An unaccepted pending start cannot safely be canceled as
an unrelated current utterance; its short command TTL and app lease still apply.

The first mic without a valid session attempts `chirp://session/start` using only
`NSExtensionContext.open`. Both initial UI and completion failure explain opening
Chirp manually. There is no UIApplication responder chain, private selector,
automatic return promise or guaranteed keyboard URL handoff. Keyboard URL opening
is an App Store review risk; this milestone targets personal installation.

`OwnedInsertion` binds generation, utterance UUID, documentIdentifier, exact
before/after context and selection evidence. It refuses unavailable, changed,
selected, oversized or known-truncated context, stale/foreign/repeated events,
expired leases, post-terminal partials/finals, and leading combining/ZWJ text that
would absorb user graphemes. It never reacquires ownership merely because text
looks identical after a field switch/hide/reload. The UIKit adapter calls the
same `VerifiedEditor` exercised by fake-proxy tests. Every delete checks both the
current document/context and expected remaining suffix, then verifies the host's
actual result before issuing another delete. Swift extended grapheme boundaries
are used; a host deleting another unit stops the edit immediately. Insertions are
also verified before ownership transfers.

Cancel retracts only an active, still-verified suffix; a final/Use raw result is
committed and survives Cancel and End. End sends the session command and invalidates
local ownership without deleting text. Use raw requires an explicit request and
expires five seconds after successful final application (also subject to the
app/bridge's expiry). Any ambiguity preserves remaining content and directs
manual recovery in Chirp. No clipboard recovery happens automatically here.

UIKit supplies no complete-context/truncation flag and some hosts use short or
asynchronous context windows. Resource bounds are 16,384 UTF-16 units per context side, 8,192 UTF-16 units
per result and 65,536 UTF-8 bytes per result (inclusive). These accommodate
multi-sentence dictation within the 120-second utterance limit. The byte bound
matches SharedBridge; with the current UTF-16 cap, valid Swift strings use at
most 24,576 UTF-8 bytes (BMP scalars use at most three bytes per UTF-16 unit;
emoji typically use four bytes per two units), so the UTF-16 cap is reached
first. Oversized input is refused before any edit rather than partially written.
The bounds do not prove context completeness: exact anchor/post-edit verification
remains required. An actually shifting/truncated window may leave an already-
inserted partial and refuse the final; recover explicitly in the app. No claim is made
that documentIdentifier detects every host bug or that callbacks prove all edits.
Context is transient in-memory evidence only and never sent to the server.

## Executed validation

Environment: Apple Swift 6.4 (`arm64-apple-macosx27.0.0`),
`xcode-select -p` = `/Library/Developer/CommandLineTools`. No full Xcode/iOS SDK.

```
swift test --package-path ios/Keyboard/Policy \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Run through `koi run`: **22 Swift Testing test functions passed**, including
parameter matrices (53 executed cases counting parameter expansions), exit 0.
After the voice-first presenter was added, a later run on a full-Xcode machine
(`swift test --package-path ios/Keyboard/Policy`, no plugin flags needed) passed
**62 test functions in 9 suites (142 expanded cases)**: the 40 new functions
(89 cases) cover every phase × Full Access × lease state, every error code,
raw countdown rounding/closure, status-line timers, style menu, fallback/recovery
precedence, compact height, `RecordingClock`, Delete repeat cadence and metrics,
and the UIKit nil-context conventions below.
The initial run failed in mutating-method `#expect` macro expansion; evaluating
those booleans before assertion corrected the test code (the same applies to
mutating calls inside `#require`). Latest successful follow-up run log:
`~/.koi/run-logs/d1a70343-19bf-471a-9a08-02ba13ed91e7-20261018T055536-17156.log`.

Coverage: partial/correcting/final/cancel/raw, duplicate/reordered/foreign/stale
results, stale lease, fixed-clock raw deadline at +4/+5 seconds, hide/reload and
late final, identical context in another document, selection/cursor/user edits,
context truncation/unavailability, non-BMP and extended graphemes, regional
indicators, combining marks, ZWJ families, every actual deletion step, host ignored
or altered deletion, document/selection/context change during deletion, final/raw
survival after Cancel/End, empty finals and oversized-result manual recovery.
The long fake-host regression applies a 2,048-character partial, correcting,
final and explicitly requested raw result, preserving preexisting contexts over
256 characters and checking every one of 6,144 deletion steps. Measured
`ContinuousClock` duration was **0.06373075 seconds** (runner: 0.064 seconds);
this is Mac fake-host evidence, not iOS performance. Separate tests expose an
actual 64-character context window during insertion and after established
ownership; both refuse further replacement without deleting additional content.
ASCII, emoji and BMP boundary matrices accept exactly 8,192 UTF-16 units and
refuse the next unit before edits. A greater-than-64-KiB emoji result is also
refused before any write.

`swiftc -frontend -parse` passed for all six UIKit/Intents/Widgets source files;
`git diff --check` passed. Parsing is syntax-only, **not** SDK typechecking or an
iOS build. Shared bridge/API agreement was source-reviewed in the foundation
worktree; shared tests are the foundation track's evidence, not this test count.

After Xcode is available, run this package's tests on disposable iPhone and iPad
simulators (select `KeyboardPolicy` package scheme), and the containing app's
unsigned simulator build/unit/UI schemes. Check compiler-generated App Intents
metadata, dual target membership, process routing and extension embedding.
Exercise real UITextDocumentProxy in Notes/test-host plain and rich text fields:
partial/final, every Unicode family above, selection, cursor, same-text field
switch, hide/reappear, final after hide, short context windows, Full Access denial,
permission/setup rejection, repeated appearance, 5-second raw expiry, custom style,
VoiceOver/large text, narrow iPad/landscape and light/dark. Verify mic indicator
through armed idle, visible End, dismissed/stale activity, killed/relaunched app,
Control Center Start/End and Shortcuts Start/Stop/Cancel/End. These simulator and
runtime checks were **not run**. Simulator tests cannot establish hardware handoff,
background survival, OS throttling, lock-screen behavior or App Store acceptance.

## Primary Apple sources checked 2026-10-18

- [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent):
  iOS/iPadOS 18+, audio recording intents; an active Live Activity is required
  throughout recording. Armed idle capture still records, so its activity stays.
- [LiveActivityIntent](https://developer.apple.com/documentation/appintents/liveactivityintent):
  iOS/iPadOS 17+, app-process execution and activity-start behavior. This permits
  app execution but does not remove microphone permission/background restrictions.
- [Creating controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system):
  iOS 18 control button uses `StaticControlConfiguration` and
  `ControlWidgetButton(action:label:)` with an AppIntent.
- [Adding interactivity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities):
  interactive activity intents belong in the app target; LiveActivityIntent runs
  in the containing app process.
- [Displaying live data](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
  and [Activity.request](https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:)):
  ActivityAttributes/ContentState, ActivityConfiguration/DynamicIsland, activity
  authorization, `ActivityContent`, throwing request, async update/end.
- [App Shortcuts provider](https://developer.apple.com/documentation/appintents/appshortcutsprovider/appshortcuts):
  `@AppShortcutsBuilder static var appShortcuts: [AppShortcut]`.
- [UITextDocumentProxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy):
  before/after context, selectedText, documentIdentifier, insertion/deletion APIs.
- [Custom keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html):
  microphone unavailable to keyboard extensions, even with Full Access.
- [NSExtensionContext.open](https://developer.apple.com/documentation/foundation/nsextensioncontext/open(_:completionhandler:)):
  URL open completion reports success; support depends on the extension point,
  and the documented supported examples do not guarantee keyboard handoff.

Apple pages were checked through the logged-in ego browser and Apple-only web
search. Ego task space was closed after research. No new toolchain was installed.
