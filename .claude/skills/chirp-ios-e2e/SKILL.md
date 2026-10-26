---
name: chirp-ios-e2e
description: Run, recreate or extend end-to-end tests of Chirp on iPhone/iPad simulators against a throwaway real chirp-server. Use for "test ios", "run the simulator", "e2e on iphone/ipad", "check notes on ios", "test the keyboard in the simulator", "ios sweep", "screenshot the ios app", or after any change under ios/ or the mac ChirpCore sources iOS links.
---

# Chirp iOS/iPadOS end-to-end testing

Everything runs on **simulators** (never a device) against a **throwaway real `chirp-server`** (port 7899, temporary HOME, own token; never 7821 or the user's running server). Needs full Xcode, `uv`, `ffmpeg`, `say`, and the cached model at `~/.koi/voice-models/parakeet-mlx` (override `CHIRP_MODEL_DIR`). Long details and pitfalls: [reference.md](reference.md).

## One command

```sh
ios/scripts/e2e-all.sh            # portable checks, then iPhone + iPad: build, unit tests, full UI scheme + live server
ios/scripts/e2e-all.sh --phone-only --skip-portable --dark
```

Speaker labels alone (Live Notes "who said what"), a short batched run: portable checks, `LiveNotesControllerTests`, the synthetic speaker UI tests and the live one against the real server and WeSpeaker model (two `say` voices, Samantha then Daniel). The server downloads its 27 MB speaker model by itself on first use, so the first run needs network (Hugging Face; `HF_HOME` keeps it between runs) and takes a few extra minutes.

```sh
ios/scripts/e2e-all.sh --only speakers [--phone-only|--ipad-only] [--skip-portable]
```

It creates its own `iPhone chirp-e2e-<pid>` / `iPad chirp-e2e-<pid>` (simulator.sh only accepts devices whose name starts with iPhone or iPad) simulators (newest "iPhone N Pro" / "iPad Pro 13-inch" with a runtime that supports them), deletes them on exit (`--keep-devices` keeps them), prints a pass/fail table plus one row per UI test, and leaves evidence in `$CHIRP_E2E_OUT` (default `/tmp/chirp-ios-e2e-all.XXXX`). Use `CHIRP_E2E_IPHONE=<uuid>` / `CHIRP_E2E_IPAD=<uuid>` to reuse devices (those are never deleted). Run it with `koi run --` (about 20-40 minutes when nothing else is using the Mac; the first build is the slowest) and end your turn. Each stage that fails is retried once; a pass on retry is shown as such. Last sweep on this layout: iPhone 18 Pro and iPad Pro 13-inch (M5), iOS 27.0, all stages PASS, 47 unit tests each, 14 UI tests pass and 2 skip on iPhone, 11 pass and 5 skip on iPad. Skips (the table prints each reason): Spotlight does not open, no hardware keyboard for the ⌘ shortcuts, and on iPad the three synthetic keyboard-host tests ("System keyboard lost its globe key"; the live keyboard-in-Messages tests do cover the iPad keyboard).

## Cold start, step by step

1. `ios/scripts/toolchain.sh` — exits 2 `BLOCKED` while only Command Line Tools are selected. Prints SDK, Xcode version, simulators.
2. `python3 ios/scripts/generate-project.py` then `ios/scripts/check-project.py` (or `ios/scripts/check-sources.sh`, which does both plus plist and syntax checks). The `.xcodeproj` is generated and checked in; regenerate after adding or moving sources.
3. Simulators: **create your own**, other workers' devices may be booted and mid-test. Never run two UI suites on one simulator.
   ```sh
   RT=$(xcrun simctl list runtimes available | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]*' | tail -1)
   PHONE=$(xcrun simctl create chirp-e2e-phone com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro "$RT")
   PAD=$(xcrun simctl create chirp-e2e-pad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB "$RT")
   xcrun simctl bootstatus "$PHONE" -b
   # ... when done:
   xcrun simctl shutdown "$PHONE"; xcrun simctl delete "$PHONE" "$PAD"
   ```
   (Type and runtime names change with Xcode: `xcrun simctl list devicetypes runtimes`.)
4. Server and clean-up stand-in: `ios/scripts/simulator-e2e.sh` starts both (throwaway `$WORK` under `/tmp`, `chirp-server --port 7899`, `fake-cleanup.py` on 7898, `say`-generated audio, a per-device pairing named "Chirp simulator") and stops them on exit. To drive them by hand, copy its setup block; pairing link is `HOME=$WORK uv run chirp-server pair --name "Chirp simulator" --url http://127.0.0.1:7899`.
5. Run a flow (table below). Single test: `ios/scripts/simulator-e2e.sh "$PHONE" -only-testing:ChirpIOSUITests/ChirpLiveServerUITests/testLiveKeyboardDictationInMessages` (the target name `ChirpIOSUITests`, not the scheme `ChirpIOS-UI`).

## Scripts

| Script | Does |
|---|---|
| `ios/scripts/e2e-all.sh` | Whole sweep, results table, evidence dir, own simulators |
| `ios/scripts/simulator-e2e.sh UUID [xcodebuild args]` | Throwaway server + stand-in + `ChirpIOS-UI` scheme with live env; privacy check (server log has no transcript) |
| `ios/scripts/simulator.sh build\|test\|ui UUID [args]` | Ad-hoc-signed `xcodebuild` on one explicit simulator UUID (`ui` = synthetic UI tests, no server). Test runs pass `-collect-test-diagnostics never` (skips Xcode's ~10-minute post-test diagnostics; verified on Xcode 26 even though `-help` omits the flag). Terminate the app in UI-test tearDown too, and `xcrun simctl shutdown` the device when a run ends — the host is shared |
| `ios/scripts/ci-test.sh` | What CI runs: portable checks + unit tests on one iPhone |
| `ios/scripts/check-sources.sh`, `generate-project.py`, `check-project.py` | Project generation and structural checks |
| `ios/Shared/scripts/test.sh`, `swift test --package-path ios/Keyboard/Policy` | Portable package tests (no simulator) |
| `ios/scripts/fake-cleanup.py PORT` | Deterministic clean-up/Notes-structure stand-in (drops um/uh) |

## Flows and what covers them

| Flow | Covered by | Notes |
|---|---|---|
| Onboarding / pairing (pasted link, deep link, forget, per-device name) | `ChirpLiveServerUITests.testLivePairDictateCleanupRawHistoryAndEnd`, `ChirpUITests.testSyntheticPairDictateRawAndEnd` | Camera scan is not simulatable; paste path only |
| In-app dictation session ("bounce to app": the keyboard opens `chirp://session/start`, app arms the background audio session) | same live test; `SessionCoordinatorTests`, `LongDictationTests` (units); `testLiveLongDictationInMessages` | Simulator mic hangs, so `--chirp-sim-audio FILE` (Debug) plays speech through the capture sink |
| Chirp Keyboard in another app (Messages) | `ChirpKeyboardUITests` (synthetic), `testLiveKeyboardDictationInMessages`, `testLiveLongDictationInMessages` | Needs the keyboard enabled in simulator Settings (the tests do it); Safari never idles for XCUITest, so Messages is the host |
| Typing with the full keyboard (KeyboardKit keys, suggestions, autocorrect) | `ChirpKeyboardTypingUITests` (host `--chirp-keyboard-host-prose`), `KeyboardTypingTests` (units through KeyboardKit's handler), `TypingTests` in `Keyboard/Policy` | The accent long-press runs on iPhone only; caps lock (two taps < 0.5 s) is unit-tested, XCUITest taps are slower |
| Action Button / Control Center / Shortcuts intents, widgets | Intent logic in `SessionCoordinatorTests`; `testLiveToggleShortcutFromSpotlightThenPaste` (often skips); Control Center controls **not automatable** | Controls and Action Button need the system gallery; check by hand or accept as a device gate |
| Live Activity (lock screen) | `testLiveActivityOnLockScreen` | Content-free phase only |
| Notes library: record, pause/resume, continue, structure, export, recovery migration | `ChirpLiveNotesUITests` (live), `ChirpNotesUITests` (synthetic: record/pause/resume/stop/transcript/export, settings, rotation), `LiveNotesControllerTests`, `NotesStoreTests` | Sealed relaunch, delete/Undo/Restore, search, reading/tasks, kept replay, iPad inspector and AX5 screenshots are in ChirpNotesUITests; migration and late-AI isolation are unit tested |
| Speaker labels (on by default, no switch or consent; the Mac fetches its model itself) | `ChirpLiveSpeakersUITests` (live: default on → waits for "Speaker model on your Mac: ready" → exactly {Person 1, Person 2} → rename to Maya → kept-audio replay), `ChirpNotesUITests.testSpeakerChipsRenameMergeAndSeparate` and `testLabelSpeakersAreOnByDefaultAndSettingsTurnsThemOff` (synthetic), `LiveNotesControllerTests` and `SpeakersTests` (default on, legacy-`false` migration, explicit off, auto-download, Retry, old server) | Run with `e2e-all.sh --only speakers`. The live test needs a server whose model is **not** downloaded yet (the script's throwaway HOME is fresh; a warm `HF_HOME` only makes the fetch quick). Never read or paste names or text from it: it reads chip counts and labels only |
| History (encrypted, opt-in) | live test above, `ChirpUITests.testHistoryOffAndAdaptiveOrientation` | |
| iPad layouts, rotation | `ChirpUITests.testHistoryOffAndAdaptiveOrientation`, `ChirpNotesUITests.testNotesLibraryBatch`, `ChirpHardwareKeyboardUITests.testRotationDuringDictationKeepsUtterance`; everything runs on the iPad too | Split View/Stage Manager resizing is not automatable |
| Hardware-keyboard shortcuts | `ChirpHardwareKeyboardUITests` | Skips unless a hardware keyboard is connected |

## Faster shared-host runs

- `simulator.sh test` and `ui` pass `-collect-test-diagnostics never` by default. XCTest results and screenshot
  attachments remain available; only verbose simulator diagnostics (which can hang for ten minutes even on success)
  are disabled. Set `CHIRP_TEST_DIAGNOSTICS=on-failure` when investigating a simulator failure.
- Run one device per shared-host lock window (`e2e-all.sh --phone-only` or `--ipad-only`), release it, and let queued
  workers interleave. Keep the lock wait and the test command inside one `koi run`; never leave a detached lock holder.
- Notes screenshot helpers use the public `XCUIDevice.shared.appearance` API (iOS 15+) to capture light and dark inside
  the same test. `ChirpNotesUITests/testNotesLibraryBatch` batches recording/relaunch/trash, reading/search/replay,
  settings/rotation and AX5 in one method. For steady pixel evidence, set `simctl ui UUID appearance dark` before launch
  and `TEST_RUNNER_CHIRP_NOTES_APPEARANCE=dark` (or `light`); this avoids capturing UIKit's appearance crossfade.
  Use `XCUIScreen.main.screenshot()` so rotated iPad images have the screen's current bounds. Simulator teardown can still take five minutes per method; do not turn a successful test into a timeout just
  to shorten that overhead.

## Evidence

- Each test attaches screenshots (`keepAlways`). `e2e-all.sh` exports them: `$OUT/<device>-attachments/` (+ `manifest.json`). Manual: `xcrun xcresulttool export attachments --path X.xcresult --output-path DIR`.
- Ad hoc screenshot: `xcrun simctl io "$UDID" screenshot /tmp/shot.png` (then Read the PNG). Appearance: `xcrun simctl ui "$UDID" appearance dark`.
- Failure details: `xcrun xcresulttool get test-results tests --path X.xcresult` (skips carry the reason) and `... get test-results summary`.
- Accessibility tree: on failure the tests attach `app.debugDescription`. For a live look, drive the Simulator window with the `peekaboo` skill.
- App/keyboard logs: `xcrun simctl spawn "$UDID" log show --last 10m --predicate 'process == "Chirp" OR process == "ChirpKeyboard"' --style compact`. The app logs content-free phases only; **never paste transcript text** into issues, commits or reports.
- Server log: `$WORK/server.log` printed by `simulator-e2e.sh`; it must contain no spoken words (the script greps and fails).
- Keep screenshots in `/tmp` or the evidence dir; commit one to `docs/screenshots/ios/` only when the user wants it.

## Known pitfalls (short list; more in reference.md)

- **Unit tests "The test runner hung before establishing connection" (5-6 min, then exit 65)** while the same code passes elsewhere: the build products sit under `~/Documents` (macOS privacy protection). Set `CHIRP_DERIVED_DATA=/tmp/...` (`simulator.sh` honours it, `e2e-all.sh` does it by default). Do not bisect the source first.
- **MLX wheel error mentioning x86_64 on Apple Silicon**: the harness selects native CPython 3.13 explicitly, even
  when a newer Intel interpreter is on PATH. Override with `CHIRP_E2E_PYTHON` when needed. Startup failures clean up the
  stand-in before retrying, so a failed dependency sync cannot leave the port occupied.
- **Port 7899 "in use"**: other agents share the Mac. `e2e-all.sh` picks 7899 or the next free pair right before each live stage; pin one with `CHIRP_E2E_PORT`.
- **`simulator.sh` only accepts devices named `iPhone…`/`iPad…`**; name your own simulators that way.
- **iPad keyboard tests skip "System keyboard lost its globe key"**: iPadOS 27's system keyboard has an emoji key instead of a globe. On your own iPad simulator, make Chirp the default keyboard: shut it down, put `dev.chirp.ios.keyboard` first in `AppleKeyboards` of `data/Library/Preferences/.GlobalPreferences.plist` (PlistBuddy), boot. The tests then find Chirp already up.
- **A fresh simulator's "slide to type" tip** covers the keyboard on first use; `selectChirpKeyboard` taps its Continue.
- **Keyboard preview file** goes in the App Group's `Chirp` folder: `TEST_RUNNER_CHIRP_PREVIEW_FILE=$(xcrun simctl get_app_container UDID dev.chirp.ios groups | cut -f2)/Chirp/keyboard-preview`.
- **Keyboard memory**: `footprint -p $(pgrep -f "UDID.*ChirpKeyboard.appex/ChirpKeyboard")` on the Mac reads the simulator extension's footprint (Debug, not device numbers).

- **Headless UI-test flakiness.** The Simulator window does not need to be visible but a *booted, unlocked* device does. First run after boot is the flakiest: retry a failing UI test once with `-only-testing:` before calling it a bug. Never run two UI suites on one simulator, or `simulator-e2e.sh` twice at once (port 7899).
- **Keyboard enablement.** The tests walk Settings → General → Keyboard → Keyboards → Add New Keyboard → Chirp → Allow Full Access. Settings layout changes by OS: on mismatch the test **skips with a reason** rather than fails. Skips are not passes; read them. Reusing a simulator keeps the keyboard enabled.
- **Mic permission.** `simulator-e2e.sh` pre-grants it with `simctl privacy grant microphone dev.chirp.ios`; a new simulator may still show the system prompt once (springboard "Allow"). Real capture never arms on this Xcode (AudioToolbox hang); audio is injected with `--chirp-sim-audio`.
- **Secure fields** anywhere on screen make iOS drop third-party keyboards for the whole screen.
- **Spotlight, Control Center, Split View, hardware key events** cannot be driven by XCUITest here; those tests skip.
- `ux/modern` links Mac `ChirpCore`: re-run `build` + `test` after any `mac/Sources/ChirpCore` change.
- Public repo: no host names, tokens, team IDs or personal paths in issues, PRs or commits.
