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
