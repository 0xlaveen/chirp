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
(using AGP built-in Kotlin), Gradle 9.8.1, OkHttp 5.5.0. The wrapper distribution
is SHA-256 verified. Gradle filesystem watching is disabled because the worker
filesystem did not reliably deliver change notifications during validation. API 37.2 and build tools 37.0.0 are stable SDK packages.
Versions were checked against Google Maven, Maven Central and the Gradle/SDK
release metadata on 2026-10-17. AGP compatibility: <https://developer.android.com/build/releases/agp-9-4-0-release-notes>.
Built-in Kotlin: <https://developer.android.com/build/migrate-to-built-in-kotlin>.

Outputs:

- Debug: `app/build/outputs/apk/debug/app-debug.apk`
- Release configuration, signed for local installation: `app/build/outputs/apk/release/app-release.apk`

`make-keystore.sh` generates an RSA 3072-bit development signing key at
`keystore/local-debug.keystore` (mode restricted by umask 077), using `keytool
-genkeypair`, alias `androiddebugkey`, password `android`, validity 10000 days.
This is a local debug key, not a production distribution key. Keep it to install
future release builds as updates. Keystores and build outputs are gitignored.
Debug and release APKs have different keys: uninstall the other variant first
when switching (this removes pairing). Both use package `dev.chirp.android`.

## Validation on this Mac

On 2026-10-17, `./gradlew lint testDebugUnitTest assembleDebug assembleRelease`
passed: lint reported **No issues found** and all **24 JVM tests** passed
(including the startup-latency revision).
`apksigner verify --verbose app/build/outputs/apk/release/app-release.apk`
verified the local release APK (v2 signature, one signer). The setup script was
rerun successfully without reinstalling tools. `adb devices -l` listed no phone;
its temporary adb daemon was stopped after the check. No persistent service or
Tailscale configuration was installed or changed.

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
`chirp-server pair` locally on the Mac. Paste the resulting
`chirp://pair?url=…&token=…` link in Chirp's masked pairing field and tap **Test
connection & save pairing**. Opening the link on Android also fills this field.
The primary path is paste; QR camera scanning is not included. Do not put a real
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
edits. Password fields refuse dictation.

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

JVM tests cover v1 protocol/health, URI validation, tap/hold boundaries, composing
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
