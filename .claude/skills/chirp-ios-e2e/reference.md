# chirp-ios-e2e reference

## What the sweep proves and does not
Proves: the app, keyboard and widgets build and unit-test on an iPhone and iPad simulator; the full UI scheme passes against a real local server; the server log holds no transcript. Does not prove: the real microphone, signing/provisioning, background audio on a device, lock-screen behaviour, Control Center/Action Button, App Store acceptance (operator device gates, `docs/milestones/M5-ios.md`).

## Debug-only simulator hooks
- Pairing accepts `chirp://pair?url=http://127.0.0.1:PORT&token=…` (Debug, Simulator).
- `--chirp-sim-audio FILE` plays a 16 kHz mono WAV through the capture sink in place of the microphone.
- `--chirp-ui-test` seeds a paired, synthetic transport (no server) for the synthetic UI suites.
- `--chirp-keyboard-host[-empty|-send]`, `--chirp-auto-enter`: in-app text host for the keyboard UI tests.

## Reading a result bundle
```sh
xcrun xcresulttool get test-results summary --path R.xcresult        # counts, failures
xcrun xcresulttool get test-results tests --path R.xcresult           # per test, with skip messages
xcrun xcresulttool get test-results test-details --path R.xcresult --test-id ID
xcrun xcresulttool export attachments --path R.xcresult --output-path DIR
```
`simulator.sh` accepts extra xcodebuild args, so `-resultBundlePath DIR/x.xcresult` (path must not exist) works through `simulator-e2e.sh` too.

## Manual poking
```sh
xcrun simctl install "$UDID" ios/DerivedData/Build/Products/Debug-iphonesimulator/Chirp.app
xcrun simctl launch "$UDID" dev.chirp.ios --chirp-ui-test
xcrun simctl openurl "$UDID" 'chirp://pair?url=http://127.0.0.1:7899&token=…'   # link from `chirp-server pair`
xcrun simctl io "$UDID" screenshot /tmp/a.png
xcrun simctl privacy "$UDID" grant microphone dev.chirp.ios
xcrun simctl ui "$UDID" appearance dark|light
xcrun simctl ui "$UDID" content_size accessibility-extra-large
```
Orientation, tab bar vs. top tabs (iPad) and Dynamic Type are worth a screenshot each when reviewing layouts.

## Stale state
`ios/DerivedData` is per checkout. If a build misbehaves after switching branches: delete it. A reused simulator keeps the app's Keychain, pairing and keyboard settings: `xcrun simctl erase "$UDID"` (shut down first) for a clean start.

## Speaker labels in the simulator
- Labels are on by default (`NotesPreferences.labelSpeakers == nil` means on; only Turn off stores `false`). Nothing asks: when health says `speakers_model.state == not_downloaded` the app sends `POST /v1/speakers/model {"action":"download"}` itself, shows "Getting the speaker model ready (27 MB, once)…" in the note, and Settings → Notes follows the model ("Speaker model on your Mac: downloading / ready / couldn’t download").
- `simulator-e2e.sh` hands the live test `TEST_RUNNER_CHIRP_LIVE_SPEAKERS_AUDIO` (a looped Samantha + Daniel WAV at 16 kHz) and plays it through `--chirp-sim-audio`; the real server compares voices with its WeSpeaker ResNet34-LM model. Chips are `chirp.notes.speaker.chip.*`; the live test expects exactly `{Person 1, Person 2}`.
- Synthetic UI tests (`--chirp-ui-test`) use `LiveNotesController.syntheticHealth` (speakers on, model ready), so every synthetic recording is labelled.
- A stored `false` from before the `speakerLabelsDefault` marker is cleared once on load; test it as JSON in `SpeakersTests`, not in the simulator.
- Accessibility ids: `chirp.notes.speakers.setting` (Settings switch), `chirp.notes.speakers.toggle` (⋯ menu), `chirp.notes.speakers.model` (Settings status), `chirp.notes.speakers.note` / `.retry` / `.turnoff` (the note's status line).

## Shared saved voices
- `--only speakers` includes `SavedVoicesTests`, the batch naming-sheet UI flow and the Saved voices screen through Settings → Notes. The screen’s switch, rename and forget actions all call the server; the phone has no voiceprint store.
- `ChirpLiveSpeakersUITests.testNamingRemembersAndRecognisesInANewNote` uses the longer `CHIRP_LIVE_VOICES_AUDIO` fixture, whose duration is passed as `CHIRP_LIVE_VOICES_DURATION`. Six `say` turns per person exceed the 20-second enrolment minimum. It names Person 1, verifies the server list, starts a different note session, then requires the same synthetic voice to be auto-named with a recognised checkmark and correctable with Not X. Each live method first clears only its throwaway server’s library, so order does not affect the chips.
- The sweep gives each test 600 seconds (maximum 900), including the initial model download. Use `CHIRP_E2E_IPHONE` / `CHIRP_E2E_IPAD` to pass your own simulators. Each server has a temporary HOME, its own token and a free port pair; never use the operator’s runtime.
- Synthetic UI only: `--chirp-voices-gallery` enables an in-memory fake server library. Fixed screenshot runs set the simulator appearance before launch and `TEST_RUNNER_CHIRP_NOTES_APPEARANCE=light|dark`; the app launch uses that style so captures avoid an appearance crossfade.
- Accessibility: `chirp.notes.voices.open`, `.enabled`, `.menu.<id>`, `.forgetAll`, `.empty`; a recognised speaker chip’s value is `Recognised`. The naming sheet’s `chirp.notes.speakers.remember.<person>` switch is hidden for old servers or while remembering is off.
