# Chirp for iPhone and iPad

A native SwiftUI app plus a dictation-first custom keyboard for iOS/iPadOS 18.
Recognition and optional clean-up run on your existing Mac speech server — the
iPhone or iPad only captures audio, streams it over your tailnet, and inserts
text. Same trust model as the Android keyboard: nothing is retained by default,
pairing is a secret QR shown locally on the Mac, and the server never accepts a
public host.

This is a **personal install** target. No App Store distribution, TestFlight or
ad-hoc readiness is claimed or tested.

## Status: written, not yet installable (2026-10-18)

The source for the app, keyboard, widgets and intents is complete on the iOS
integration branch, but **no installable build exists yet**. The Mac used for
development has only the Command Line Tools — `xcode-select -p` returns
`/Library/Developer/CommandLineTools` — so there is no full Xcode, no iOS SDK
and no iOS Simulator runtime. **No iOS compile, simulator run, entitlement,
provisioning or on-device check is claimed anywhere in this repo.**

What has actually passed, on macOS with the CLT (see
[docs/review/ios-foundation.md](../docs/review/ios-foundation.md) and
[docs/review/ios-keyboard.md](../docs/review/ios-keyboard.md)):

| Check | Result |
|---|---|
| `ios/Shared/scripts/test.sh` (portable pairing/storage/history/bridge) | 20 tests in 5 suites, exit 0 |
| `mac/scripts/test.sh` + `cd mac && swift build -c release` | 380 tests in 61 suites + release build, exit 0 |
| `swift test --package-path ios/Keyboard/Policy …` (insertion safety) | 22 test functions (53 expanded cases), exit 0 |
| `swiftc -frontend -parse` on the six UIKit/Intents/Widgets sources | parse-only pass — **not** an iOS build |

These are macOS execution of portable logic and source parsing. They are not
simulator or hardware acceptance; every runtime claim below is implemented and
unit-tested, but pending Xcode and device gates. The manual acceptance
checklist for both iPhone and iPad lives in
[docs/milestones/M5-ios.md](../docs/milestones/M5-ios.md).

One server prerequisite: the server must run the updated source from this
branch, which accepts `"ios"` alongside `"mac"` and `"android"` as `client`
values. Restart `chirp-server` from this checkout before pairing iOS. The
production/launchd server on the Mac was not touched by any worker; updating it
is an operator step.

## Requirements

- A Mac running the Chirp speech server from this branch, with Tailscale on.
- iPhone and/or iPad on iOS/iPadOS 18+, on the same tailnet.
- For building and installing: a Mac with **full Xcode** and a matching iOS
  SDK/simulator runtime. The Command Line Tools alone cannot build any of this;
  `ios/scripts/toolchain.sh` exits with `BLOCKED` while CLT is selected.

## Install (operator steps)

Everything here is manual operator work on hardware you own. Agents never
operate devices, and there is intentionally **no auto-install script** — device
installation is Xcode's Run action, performed by you.

1. Verify the toolchain from `ios/`:

   ```sh
   cd ios
   ./scripts/toolchain.sh     # prints iOS Simulator SDK path, Xcode version, available simulators
   ```

   If it prints `BLOCKED: select a full Xcode installation…`, install Xcode,
   launch it once, accept the license, and run `sudo xcode-select -s
   /Applications/Xcode.app` (or `xcode-select` to the correct path).

2. The Xcode project is generated deterministically and checked in as
   `ios/Chirp.xcodeproj` (generator: `ios/scripts/generate-project.py`, Python 3
   standard library only, no XcodeGen). Regenerate after moving/adding sources:

   ```sh
   python3 scripts/generate-project.py
   ```

3. Choose your signing identity and identifiers. Defaults live in
   `ios/Config/Project.xcconfig`:

   | Setting | Default |
   |---|---|
   | `CHIRP_BUNDLE_ID` | `dev.chirp.ios` (keyboard `…keyboard`, widgets `…widgets`) |
   | `CHIRP_APP_GROUP` | `group.dev.chirp.ios` |
   | `CHIRP_KEYCHAIN_ACCESS_GROUP` | `$(AppIdentifierPrefix)dev.chirp.ios.shared` |
   | `DEVELOPMENT_TEAM` | empty — you must set it |

   Create an **untracked** `ios/Config/Local.xcconfig` (the project includes it
   if present) with at least `DEVELOPMENT_TEAM = <your team>`; change the bundle
   prefix, App Group and keychain group there too if `dev.chirp.ios` collides
   with another app on your Apple ID. Whatever you choose, the **same** team,
   App Group and keychain access group must apply to all three targets — app,
   keyboard and widgets — since they share the encrypted mailbox and Keychain.

4. Open `ios/Chirp.xcodeproj` in Xcode, sign in with your personal Apple ID
   (Settings → Accounts), and pick that team for the ChirpIOS,
   ChirpKeyboard and ChirpWidgets targets (automatic signing).

5. Connect the iPhone by cable, trust the computer, enable Developer Mode on the
   device (Settings → Privacy & Security → Developer Mode), select the device,
   choose the **ChirpIOS** scheme and press ⌘R (Run). Check that both embedded
   extensions got profiles with your App Group and keychain access group.

6. Repeat on the iPad: same project, same team and identifiers, select the
   iPad, Run. It is one universal app (iPhone + iPad device families).

7. **Updates (both devices):** build again and Run over the existing install.
   Never delete the app to update it — the pairing token and history key live
   in the Keychain/App Group container, and uninstalling destroys them, forcing
   a re-pair and losing saved history.

Sign-in, provisioning and device trust are operator-only actions; no worker
performs Apple ID login. Free Personal Team profiles expire after **seven
days**, after which the app stops launching on device — rebuild and Run again
to re-install. App Groups (and sometimes keychain sharing) are **not guaranteed
on free accounts**: check the actual provisioning profile Xcode generates. If
the capability is missing, the app and keyboard will report that shared storage
is unavailable rather than silently degrading. TestFlight or ad-hoc
distribution needs a paid Apple Developer Program membership and matching
profiles; nothing here is validated for that path.

Simulator checks (never devices) are scripted:

```sh
./scripts/simulator.sh build|test|ui SIMULATOR-UUID
```

It regenerates the project, then runs an **unsigned** `xcodebuild` against an
explicit available iPhone/iPad simulator UUID (`ChirpIOS` scheme for build and
unit tests, `ChirpIOS-UI` for UI tests). Get UUIDs from
`xcrun simctl list devices available`.

## Pair with your Mac

1. Connect Tailscale on the Mac and on the iPhone/iPad.
2. On the Mac, from `server/`, publish the pairing QR (printed locally only):

   ```sh
   uv run chirp-server pair --url https://<your-mac>.<tailnet>.ts.net/chirp
   ```

3. In Chirp, open the **Pair Mac** tab → **Scan pairing QR**. Grant camera
   permission when asked; if it is denied, the scanner tells you and you can
   paste the secret link into **Secret pairing link** and tap **Test connection
   and save pairing** instead.
4. Pairing is saved to the Keychain only after the authenticated health check
   succeeds; the "Mac pairing saved in Keychain" state means the Mac was
   verified. **Check Mac connection** re-verifies later; **Forget pairing**
   clears the token.

Accepted links are exactly `chirp://pair?url=…&token=…` with an HTTPS
`*.ts.net` host and a simple unencoded base path such as `/chirp` (nondefault
HTTPS ports allowed). Public hosts, plain HTTP, userinfo/query/fragment and
encoded paths are rejected, and all redirects are refused. There is no
supported way to point iOS at a public server.

## Enable the keyboard

On the device: **Settings → General → Keyboard → Keyboards → Add New Keyboard →
Chirp Keyboard**, then select Chirp Keyboard and enable **Full Access**.

Full Access is required because the keyboard talks to the app through the
encrypted App Group mailbox — it never gives the keyboard a microphone; Apple's
sandbox denies keyboard audio access even with Full Access. Without Full Access
the keyboard keeps Space, Delete, Return and the globe (next keyboard), and
shows "Dictation needs Full Access". Secure fields and hosts that disallow
custom keyboards automatically use Apple's keyboard.

## Dictate in the app

The **Dictate** tab is the session owner. **Start keyboard session** arms the
microphone for the keyboard; **Dictate** starts an in-app utterance directly.
Status line and Live Activity show the phase: Session armed · microphone
active, Connecting…, Listening…, Polishing…, Finished · microphone still
active.

Honest microphone behavior: during an armed session the app keeps its capture
engine running so it is ready when a keyboard command arrives. Idle audio is
discarded immediately and **no audio leaves the device between utterances** —
but iOS shows the microphone indicator throughout the armed session. That is
expected; only **End session** turns the microphone off. Every surface (app,
keyboard, Live Activity) exposes End session.

Session length (Settings tab): **5 minutes (default), 15 minutes, 1 hour,
Never**. Never lasts until ended, interrupted, terminated or revoked — iOS may
still suspend the app; indefinite background execution is not guaranteed.
Interruptions (calls, Siri, route changes), expiry and transport failure all
end the session safely; the notice tells you to reopen Chirp.

While dictating: **Stop dictation** finalizes (⌘Space toggles, Esc cancels).
After the final you get explicit **Copy**, **Share** and — when clean-up
changed the text — **Use raw** for 5 seconds (⌘⇧Z); the original transcript is
expandable below. ⌘⇧E ends the session. The app never writes the clipboard by
itself. Utterances are capped at 120 seconds and stop automatically.

If the server runs with `--debug-retain`, a persistent red banner "DEBUG: Mac
keeps recordings" stays on screen in the app, keyboard and Live Activity.

## Dictate from any app (keyboard)

Switch to Chirp Keyboard in your editor. Its keys: **Start dictation / Stop
dictation**, **Cancel**, **Use raw**, **Style**, **End session**, **Open
Chirp**, Space, Delete, Return and the globe.

1. Arm a session in the app first (see above). The keyboard shows "Session
   armed".
2. Tap **Start dictation**. The first tap when no session exists tries to open
   Chirp via `chirp://session/start`; iOS may refuse this from a keyboard
   extension. The keyboard then tells you to open Chirp manually and return
   with the system Back-to-app affordance or the app switcher — automatic
   return is not possible.
3. Live text appears in the field as partials and is replaced by the final.
   **Stop dictation** finalizes; **Cancel** retracts the partial; **Use raw**
   (5 s window, only when clean-up changed the text) swaps the original back;
   **Style** picks the server's clean-up profile; **End session** stops the
   microphone.

The keyboard edits only a verified owned suffix: it binds what it inserted to
the exact editor context and refuses to delete anything it cannot prove it
wrote. Some hosts expose short, truncated or asynchronous editor context; in
those the automatic replacement can stop with a partial already inserted — the
keyboard shows "Text kept in place" and leaves your text alone. Recover
explicitly in the Chirp app (the last transcript stays there); the keyboard
never blindly deletes by length. Size bounds: results up to 8,192 UTF-16 units,
per-side context evidence up to 16,384 UTF-16 units, results up to 65,536 UTF-8
bytes — oversized input is refused before any edit rather than half-written.

## Companion controls (Action Button, Control Center, Shortcuts)

Two iOS 18 controls — **Chirp dictation** (start) and **End Chirp session** —
can be added to Control Center and the Action Button (supported hardware). App
Shortcuts phrases: "Start dictation with Chirp", "Stop dictation with
Chirp", "Cancel dictation with Chirp", "End session with Chirp". While a
session runs, a Live Activity on the lock screen/Dynamic Island shows the
content-free phase (e.g. "Microphone active · dictating") with Start/Stop/
Cancel/End buttons; enable Live Activities for Chirp in system settings or
session start refuses.

Companion start requires the app in the foreground for permission/setup — the
intent opens Chirp rather than recording cold in the background. Companion
**Stop** is the one path that explicitly copies its own fresh final to the
clipboard; keyboard and in-app dictation never write the clipboard implicitly.
Nothing transcript-like ever appears on the lock screen.

## Clean-up and styles

**Styles** tab. Clean-up starts off. The disclosure line says where it runs —
"Sends final text to \<host\>" for an external destination — and enabling an
external destination takes an explicit per-destination consent that suspends
when the destination changes. Styles come from your Mac's authenticated
profile list (Default, Chat, Email, … plus custom server profiles); each has an
editable prompt with a **Reset to server default** button. The keyboard's
**Style** menu mirrors the same server profiles. On clean-up failure or
timeout, the raw transcript is kept and offered instead.

## History (off by default)

**History** tab: "Keep encrypted history on this device" is off initially.
When on: at most 200 nonempty finals, 4 MiB total, retention 24 hours / 7 days
(default) / 30 days, searchable, with per-entry copy, copy-original, delete and
a Clear all action. Entries are AES-GCM encrypted with a device-only Keychain
key, excluded from backups and never synced. Turning history off deletes the
ciphertext and the key. Cancelled and empty utterances are never recorded, and
the **Private session** toggle (Settings) keeps an utterance out of history —
but Chirp cannot detect every editor's private mode, so switch it on yourself
when it matters; surrounding editor text is never collected.

## Privacy & security

- **Nothing retained by default.** No audio or transcripts on disk outside the
  server's opt-in debug retention, which both clients banner in red. Idle audio
  is discarded on device, never streamed.
- **Pairing is a secret.** The QR/link is printed locally on the Mac only;
  treat it like a password. The token lives in the iOS Keychain (this-device,
  after first unlock, never synced) and is never rendered or logged. Do not
  paste real pairing links or tokens into issues, docs or chat.
- **Tailnet-only.** HTTPS `*.ts.net` hosts with simple paths; no HTTP, no
  public hosts, no redirects, TLS validation always on.
- **IPC is encrypted.** The keyboard/app mailbox is AES-GCM sealed with a
  shared Keychain key; no transcript ever touches UserDefaults or plaintext
  files. Mailbox contents are transient with opportunistic expiry deletion on
  next access — there is no background purge daemon.
- **Diagnostics are content-free.** Version, OS, phase, fixed local error
  codes, durations and counts only — no transcripts, prompts, audio, URLs,
  hosts, tokens or device identifiers.
- **No telemetry, no background sync, no analytics.**

## Troubleshooting

| Symptom | Meaning / fix |
|---|---|
| "Dictation needs Full Access" | Enable Full Access for Chirp Keyboard in Settings → General → Keyboard → Keyboards. |
| "Start a session in Chirp" in the keyboard | No armed session (or the lease expired). Open Chirp, tap Start keyboard session, return to your editor. |
| "iOS could not open Chirp from this keyboard" | Expected fallback; open Chirp manually and return via app switcher. |
| "Text kept in place" | The editor's context changed or is unreliable; recover the dictation in the app. Your text is never auto-deleted. |
| "Protected storage unavailable. Unlock and reopen Chirp." | Keychain/App Group not accessible (device locked or missing capability). Check the provisioning profile includes the App Group and keychain access group. |
| "Connection failed. Check Tailscale and your Mac." | Tailnet down or server not running the updated source; use Check Mac connection after fixing. |
| "The Mac did not finish in time." | Finalization/clean-up deadline hit; raw text is kept when possible. |
| Arming fails or the session ends immediately | Check microphone permission, that Live Activities are enabled for Chirp, and Tailscale; the Dictate tab shows the local error. |

## Develop and test

Runs today with only the Command Line Tools (macOS execution of portable
logic — not iOS runtime evidence):

```sh
ios/Shared/scripts/test.sh                 # 20 tests / 5 suites
mac/scripts/test.sh && (cd mac && swift build -c release)   # 380 tests / 61 suites + release
swift test --package-path ios/Keyboard/Policy \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
cd ios && ./scripts/check-sources.sh        # regenerate + structural, plist and per-target syntax checks
./scripts/typecheck-catalyst.sh             # optional Catalyst compiler aid (see below)
```

`check-sources.sh` regenerates the project, runs the structural project check
(`check-project.py`), lints every plist/entitlement and the pbxproj, parses
each target's Swift sources and shell/Python syntax — its own output says "no
iOS typechecking claimed". `typecheck-catalyst.sh` is an optional compiler
aid: it compiles the session coordinator, microphone capture, pairing scanner
and debug-fixture sources for the Mac Catalyst target, substituting a
temporary ActivityKit facade in a scratch directory (shipping sources are
unmodified). It has already caught one real conditional-API mistake, but it
does not validate the iOS SDK, signing, the simulator, SwiftUI view macro
expansion, App Intents or ActivityKit, and it is not runtime evidence.

After full Xcode is installed: `./scripts/toolchain.sh`, then
`./scripts/simulator.sh build|test|ui <simulator-uuid>` on disposable iPhone
and iPad simulators (unsigned), plus the `KeyboardPolicy` package tests on the
simulator. Those gates have **not** been run; simulator results also cannot
establish hardware keyboard handoff, background-audio survival, lock-screen
behavior or App Store acceptance. Evidence and exact logs:
[docs/review/ios-foundation.md](../docs/review/ios-foundation.md),
[docs/review/ios-keyboard.md](../docs/review/ios-keyboard.md), shared-package
API contract in [Shared/README.md](Shared/README.md).

## Layout

```
ios/
  App/        SwiftUI app: session coordinator, microphone capture, pairing scanner, views
  Keyboard/   Keyboard extension + Keyboard/Policy (verified-insertion logic under test)
  Intents/    App Intents, App Shortcuts, Live Activity (app-process execution)
  Widgets/    WidgetKit bundle: Live Activity UI, Control Center controls
  Shared/     ChirpIOSCore package: pairing, Keychain, preferences, encrypted history/bridge
  Config/     Project.xcconfig, Info.plists, entitlements (per target)
  scripts/    toolchain.sh, generate-project.py, simulator.sh,
              check-sources.sh, check-project.py, typecheck-catalyst.sh
  Tests/      Simulator unit tests (app)
  UITests/    Simulator UI tests
```

## Known limits

- **Not installable yet.** Full Xcode and an iOS SDK are absent on the build
  machine; no iOS compile/simulator/device validation has run.
- **Personal install only.** No App Store readiness; the keyboard's URL-open
  handoff is a known App Store review risk.
- **The keyboard has no microphone, ever** (Apple sandbox). A session must be
  armed in the app; the first-tap handoff can fail and needs a manual open.
- **No automatic return** to your editor and no guaranteed cold/background
  microphone start from companion controls.
- **"Never" session length is not forever**: iOS may suspend or terminate the
  app; the microphone indicator stays on for the whole armed session by design.
- **Free provisioning expires every 7 days** and App Group availability on
  free accounts is not guaranteed — verify the actual profile.
- Editor-context quirks (short/truncated/asynchronous context windows) can stop
  automatic replacement and leave a partial; recovery is manual in the app.
