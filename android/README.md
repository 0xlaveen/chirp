# Chirp Voice for Android

A Kotlin voice-only IME for the Galaxy Z Fold 8 (Android 12/API 31 minimum).
The phone streams 16 kHz mono PCM16 in 40 ms frames to the Mac over authenticated
HTTPS/WebSocket and Tailscale. Recognition runs on the Mac. No microphone, network
connection, foreground service, wake lock or recurring work is active while the
keyboard is hidden. While visible, Chirp warms an authenticated socket for up to
30 seconds idle so recording can start without a handshake.

## Build toolchain (macOS, user scoped)

Run from the repository root:

```sh
android/scripts/setup-toolchain.sh
source "$HOME/.local/share/chirp-android/env.sh"
cd android
./scripts/make-keystore.sh
./gradlew lint testDebugUnitTest assembleDebug assembleRelease
```

The idempotent script installs Azul Zulu JDK 21 under
`~/.local/share/chirp-android/jdk`, checksum-verifies vendor downloads, installs
Google command-line tools under `~/Library/Android/sdk/cmdline-tools/latest`,
accepts Android SDK licenses and runs these exact SDK package commands:

```sh
sdkmanager --sdk_root="$HOME/Library/Android/sdk" --licenses
sdkmanager --sdk_root="$HOME/Library/Android/sdk" \
  'platform-tools' 'platforms;android-37.2' 'build-tools;37.0.0'
```

No sudo, Android Studio or emulator images are needed. `CHIRP_TOOLS` and
`ANDROID_HOME` can override the install directories. Source the generated env
file before invoking Gradle/adb. `local.properties` is generated and ignored.
Pinned versions are in `gradle/libs.versions.toml`: AGP 9.4.1, Kotlin 2.4.21
(using AGP built-in Kotlin), Gradle 9.8.1, OkHttp 5.5.0, Robolectric 4.17 and
Google Play services code scanner 16.1.0. The wrapper distribution
is SHA-256 verified. Gradle filesystem watching is disabled because the worker
filesystem did not reliably deliver change notifications during validation. API 37.2 and build tools 37.0.0 are stable SDK packages.
Versions were checked against Google Maven, Maven Central and the Gradle/SDK
release metadata on 2026-10-17. AGP compatibility: <https://developer.android.com/build/releases/agp-9-4-0-release-notes>.
Built-in Kotlin: <https://developer.android.com/build/migrate-to-built-in-kotlin>.
The scanner's transitive Fragment dependency is constrained to stable 1.9.1 so
it remains compatible with Activity Result permission handling and passes lint.

Outputs:

- Debug: `app/build/outputs/apk/debug/app-debug.apk`
- Release configuration, signed for local installation: `app/build/outputs/apk/release/app-release.apk`
- Without the checkout's local keystore: `app/build/outputs/apk/release/app-release-unsigned.apk`

`make-keystore.sh` generates an RSA 3072-bit development signing key at
`keystore/local-debug.keystore` (mode restricted by umask 077), using `keytool
-genkeypair`, alias `androiddebugkey`, password `android`, validity 10000 days.
This is a local debug key, not a production distribution key. Keep it to install
future release builds as updates. Keystores and build outputs are gitignored.
Debug and release APKs have different keys: uninstall the other variant first
when switching (this removes pairing). Both use package `dev.chirp.android`.

## Validation on this Mac

On 2026-10-17, `./gradlew lint testDebugUnitTest assembleDebug assembleRelease`
passed on `chirp/android-r2`: lint reported **No issues found**, **81 JVM tests
passed**, and the two opt-in live-server tests were skipped (83 total). The
54 Robolectric cases cover the service and Setup at API 31 and 37, including
framework-driven fold view recreation. All three R2-07 regressions run without
an environment gate. Debug and unsigned release APKs built successfully; this
checkout has no local release keystore. No phone, microphone, camera, real
pairing credentials, TCC prompt, server process or Tailscale configuration was
used for this validation.

## Operator: wireless debugging and installation

These steps need the Fold in hand; no phone is attached to the build machine.

1. Enable Developer options (tap Build number seven times), then enable Wireless
   debugging. Put Mac and phone on the same Wi-Fi for adb pairing.
2. On the phone, choose **Pair device with pairing code**. Use its pairing address
   and code with `adb pair PHONE_IP:PAIR_PORT`. Enter the code interactively.
3. Back on the Wireless debugging screen, use the separate connection address:
   `adb connect PHONE_IP:DEBUG_PORT`. Check `adb devices`.
4. Install the APK:

   ```sh
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   # Or the signed local release:
   adb install -r app/build/outputs/apk/release/app-release.apk
   ```

5. Open **Chirp Voice**. Grant microphone permission. Tap **Enable Chirp** and
   enable it in keyboard settings. On Samsung the manual path is **Settings →
   General management → Keyboard list and default → Chirp Voice**. Keep Samsung
   Keyboard enabled for typing. Tap **Pick Chirp Voice** or use the navigation-bar
   keyboard icon when a text field is focused.

Optional command-line enable after the user has reviewed the system warning:

```sh
adb shell ime enable dev.chirp.android/.ChirpImeService
adb shell ime set dev.chirp.android/.ChirpImeService
```

## Pair with the Mac and dictate

Connect Tailscale on both devices. Start the configured Mac server and its
Tailscale Serve route as described in the integration docs, then run
`chirp-server pair` locally on the Mac. Tap **Scan pairing QR** in Setup and scan
the displayed QR code, or paste the resulting `chirp://pair?url=…&token=…` link
in Chirp's masked pairing field. Then tap **Test connection & save pairing**.
Opening the link on Android also fills this field. Both scan and link opening
validate through `Pairing.parse`; neither saves credentials before the connection
test. The scanner UI and camera access are owned by Google Play services, so
Chirp does **not** request the camera permission. Scanning requires Google Play
services (present on the Fold 8), and its scanner module may need a download on
first use. If unavailable or cancelled, paste remains available.
See [Google code scanner](https://developers.google.com/ml-kit/vision/barcode-scanning/code-scanner).

**Pairing-secret handling (for approval review).** The QR encodes the bearer token. With **Scan pairing QR**, the token is decoded on the device inside Google Play services' scanner process and returned to Chirp. Chirp never logs it. **Paste** keeps the token out of any other app's process, apart from the clipboard you pasted from; prefer it if that matters. The merged release manifest declares only `INTERNET`, `RECORD_AUDIO` and `ACCESS_NETWORK_STATE` (from Play services). It does **not** declare `CAMERA` (verified on `chirp/integration` 0851833).
Do not put a real
pairing link in shell history, issues, screenshots or logs. The usual server base
is `https://mainframe.tail676ff2.ts.net/chirp`.

The authenticated health check verifies the connection and securely stores the
token using an Android Keystore AES-256-GCM key and a fresh random IV. Backups and
device transfer of app settings are disabled. **Forget pairing** removes the key
and credentials. A lost Keystore key requires pairing again.

Tap the test dictation box in Setup, select Chirp and tap the mic. A tap shorter
than 300 ms toggles recording; a hold records until release. Partial text appears
underlined in the target field and is replaced by the final result. **✕** clears
that utterance's composing text. Backspace, space and enter/editor action are
available; **⌨ back** returns to the previous keyboard, with picker fallback.
**Return to previous keyboard after dictation** defaults ON. Turn it OFF in
Setup to stay in Chirp after each final and reuse the socket for the next
utterance. A corrected result leaves a **Use raw** button for five seconds;
auto-return waits for that button or its expiry when the setting is ON. Moving
the cursor or
changing the field invalidates this replacement so it cannot overwrite later
edits. Raw replacement marks the verified corrected range as composing and
replaces it in one commit, so a rejected region or commit leaves the corrected
text intact (R2-07). Failed replacement can be retried within the original
five-second window. Password fields refuse dictation.

Correction and haptics default off. An external correction service is labeled
**sends text to HOST**, and its host must be available before it can be enabled.
The setting resets if the health response changes the destination. Audio goes
only to the Mac. Both Setup and the IME show a persistent red **DEBUG: recordings
kept on Mac** banner if the server reports debug retention. Disable retention on
the server to stop it; the phone never stores audio or transcripts. The pairing
field and test box do not save text across Activity recreation.

Mic capture starts immediately on press. Until Ready, up to five seconds of PCM
are buffered in memory, then flushed in order before live frames. Sent or
discarded buffer frames are zeroed, including on cancel or overflow. Overflow
aborts instead of dropping the first words. Releasing a hold before Ready stops
the mic and sends the complete buffered utterance followed by stop after Ready.
The recorder releases before the stop frame is sent, and on cancellation,
hidden keyboard or changed field. Folding/resizing
recreates the view while preserving the active service and utterance. A zero
signal for 1.5 s aborts with **No microphone signal**; initial digital silence is
not sent. Utterances stop at 120 s. The stream upgrade retries once before Ready,
while captured frames are still
buffered locally. A failure after Ready discards the utterance (no audio replay),
and the user starts again. The socket is prewarmed on view show (TLS and bearer
authentication only, no start), reused across normal start/final pairs, and
closed after 30 seconds idle or immediately on hide. A small connection pool
allows TLS reuse while visible and is evicted on hide. Cancellation retires its
socket because v1 has no cancel acknowledgement to distinguish late finals.
Health refresh runs in the background on view show; cached health labels and
Ready retention metadata are used during dictation, without a per-press health
round trip. Health, startup and finalization have finite deadlines. Both the
pre-Ready buffer and network queue are bounded to five seconds of PCM each.

## Tests and phone acceptance

```sh
./gradlew lint testDebugUnitTest assembleDebug
./gradlew assembleRelease
adb shell ime list -s
```

Robolectric 4.17 service and Setup tests run at API 31 and 37 with fake capture,
transport, scanner and `InputConnection`; no microphone, camera, device or
live server is used. They cover tap/hold start and stop, recorder release before
the stop frame, cancel and stale events, partial composition and final commit,
hide/finish cleanup, fold/view recreation, field changes, password refusal,
auto-return on/off and the five-second raw undo window. Setup tests cover QR
parse/feed, malformed or missing payloads, cancellation/failure fallback, deep
links, late callbacks and the absence of camera permission. Robolectric's
[latest stable release](https://github.com/robolectric/robolectric/releases/tag/robolectric-4.17)
was checked on 2026-10-17.

Other JVM tests cover v1 protocol/health, URI validation, tap/hold boundaries, composing
replacement, cancellation, out-of-order events, unavailable connections and
bounded raw undo with a fake `InputConnection`, selected-text restoration on
cancel, and HTTPS/WebSocket authentication, frame ordering, upgrade retry,
redirect rejection, prewarming without start, two utterances on one socket,
and cancellation with a local TLS test server. Buffer tests cover ordered
flush/live delivery, the five-second bound, cancellation zeroing, duplicate
Ready and failed sends. Hardware acceptance needs the
operator: dictate in Samsung Notes and a browser field, cancel, change fields,
hide the keyboard, fold/unfold while recording, interrupt Tailscale, disable
auto-return and dictate twice, stop before Ready,
verify a prewarmed socket expires after 30 seconds idle, reject a
bad token, enable retention on the server and verify both banners, exercise
external correction and raw undo, and verify the mic privacy indicator goes away
immediately on every stop/hide/cancel path. No hardware battery or latency result
is claimed without this run.

## Battery and latency

Enable **Debug overlay** to see press→first-partial, stop→final, stop→commit
and background authenticated health round-trip latency in the IME. Only numbers
are displayed; no transcript logging is used.
Keep this off for battery measurement. Run an unplugged phone at fixed brightness
and charge level, first over Wi-Fi, then LTE with Tailscale connected:

```sh
NETWORK=wifi ./scripts/battery-session.sh 10
NETWORK=lte ./scripts/battery-session.sh 10
# Optional separate 120s Perfetto power/scheduling sample (Samsung support varies):
NETWORK=wifi PERFETTO=1 ./scripts/battery-session.sh 10
```

For LTE, Wi-Fi adb may disconnect; use a USB cable with a charge blocker or record
that USB charging affects the result. Each run resets batterystats, prompts for
10 utterances of 10 s, dumps package counters, then prompts for at least five
minutes idle with the keyboard visible. Stats and optional Perfetto trace go to
`~/Library/Caches/Chirp/battery/`, outside the repo. Inspect package UID estimated
mAh and divide by actual dictation minutes; compare the after-idle delta and
report display/radio cost separately. Copy the stdout row and measured mAh/min
to `docs/bench.md`. Leave unavailable power rails or unmeasured values marked TBM.

## Reuse

The capture design adapts Koi's `ui/src/studio/chat/voiceRecorder.ts` streaming
sink, 16 kHz PCM, RMS diagnostic and explicit stop/cancel cleanup patterns. Native
AudioRecord supplies the sample format without browser resampling/fallback code.
OkHttp handles TLS, WebSocket framing and queues; system InputMethodService and
Keystore own editor integration and secrets. No Koi runtime dependency is added.

## JVM live check (no phone)

`LiveServerTest` drives the IME's real transport (`ChirpNetwork`, `StreamTransport`, `Protocol`) against a running `chirp-server`. A WAV file stands in for `AudioRecord`, so no device, microphone or permission is involved. It checks authenticated health, a pre-warmed socket, two utterances on one socket, and that a wrong token is refused before any audio is sent. It is skipped unless `-Pchirp.live.url` is given:

```sh
./gradlew testDebugUnitTest --tests '*LiveServerTest*' -i \
  -Pchirp.live.url=http://127.0.0.1:7821/ -Pchirp.live.tokenFile=$HOME/.config/chirp/token \
  -Pchirp.live.wav=/path/to/16k-mono.wav -Pchirp.live.expect=someword
```
