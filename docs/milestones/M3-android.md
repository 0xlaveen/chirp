# M3: Android voice IME (`chirp/android`)

Goal: `android/` is a Gradle project producing **Chirp Voice**, a minimal Kotlin voice-only input method for the Samsung Galaxy Z Fold 8. It streams mic audio to the Mac's `chirp-server` over Tailscale (`wss://<your-mac>.<tailnet>.ts.net/chirp/v1/stream`). Partials appear live as composing text in the focused field; the final is committed. The interaction mirrors Koi's dictation ([architecture §6](../architecture.md)). Battery use must be minimal: no mic, socket or CPU work unless the user is dictating.

## Constraints and toolchain

- This Mac has no Java, no Android SDK and no adb. Install them **locally and user-scoped**, e.g. Homebrew `openjdk@21` and `android-commandline-tools` (or the cask `android-commandlinetools`), then `sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"` (use the latest stable platform/build-tools available).
  - Document the exact commands in `android/README.md`, plus a `android/scripts/setup-toolchain.sh` that is idempotent.
  - Disk is limited (~138 GB free), so do not install emulator system images unless needed. A headless emulator for instrumented tests is optional.
- Use the Gradle wrapper with the latest stable Gradle, AGP and Kotlin, and a version catalog.
  - minSdk 31, target/compileSdk the latest stable (36+).
  - Single module `app`, package `dev.chirp.android`.
- Dependencies, kept small:
  - OkHttp (WebSocket)
  - AndroidX core/appcompat/activity
  - Kotlin coroutines
  - ZXing or ML Kit barcode, optional, for scanning the pairing QR. A paste field for the `chirp://pair?...` link is acceptable as the primary path.
  - No Compose inside the IME unless it is clearly simpler and light; a View-based IME is fine. Compose is fine for the setup Activity.
- The phone is not attached yet. Pairing via `adb pair` (Wireless debugging) needs the operator. Build everything, unit-test it and produce an APK. Write the exact install and enable steps for the operator.

## Scope

1. **`ChirpImeService : InputMethodService`:**
   - IME XML with a `voice` subtype (`android:imeSubtypeMode="voice"`) so it is offered as a voice input method, plus an English subtype.
   - The view is one large mic button, a partial-text strip, ✕ cancel, ⌫ backspace, ↵ enter/action, space, and "⌨ back" (`switchToPreviousInputMethod`, falling back to `showInputMethodPicker`).
   - The layout adapts to the Fold cover and inner screen widths and survives configuration changes.
2. **Interaction:**
   - A tap under 300 ms toggles; a hold is push-to-talk.
   - Partials go out via `currentInputConnection.setComposingText`, using the `stable` prefix if useful. The final goes via `commitText` and replaces the composing region. Cancel calls `finishComposingText` after clearing the composing text, so nothing is inserted.
   - Handle a lost InputConnection or a changed field mid-utterance (cancel cleanly).
   - Optional haptic on start and stop.
   - Silence guard as in Koi: if peak/RMS stays at zero for 1.5 s, show "No microphone signal".
3. **Audio:**
   - `AudioRecord` with `MediaRecorder.AudioSource.VOICE_RECOGNITION`, 16 kHz mono PCM16, 40 ms frames on a dedicated thread, sent as binary WS frames.
   - Release the recorder on stop, on `onFinishInputView` and on `onWindowHidden`.
   - Use no foreground service and no wake lock.
4. **Network:**
   - OkHttp WebSocket. Connect on mic press; optionally pre-warm the connection when the IME view shows, with a short timeout, and close it after 30 s idle.
   - Send the bearer header on the upgrade.
   - Reconnect once on failure with a clear error state ("Mac unreachable — is Tailscale on?").
   - Measure and keep round-trip and stop→final timings for the debug overlay only.
5. **`SetupActivity`** (launcher):
   - Steps: grant `RECORD_AUDIO`; enable Chirp in the system keyboard settings (`Settings.ACTION_INPUT_METHOD_SETTINGS`); pick it (`showInputMethodPicker`).
   - Pair: paste or scan the `chirp://pair?url=…&token=…` link, which is also registered as an intent filter. Test the connection with `/v1/health`, then run a test dictation box.
   - Toggles: correction (off by default; shows "sends text to <host>" when health says it leaves the machine), haptics, debug overlay.
   - When the server reports `debug_retention`, show a persistent red **DEBUG: recordings kept on Mac** banner in the IME and the Activity.
6. **Secrets:** the token is encrypted with an Android Keystore AES-GCM key and stored in app-private SharedPreferences or DataStore. Exclude it from backups (`android:allowBackup="false"`, data extraction rules). Never log the token or transcripts.
7. **Tests:**
   - JVM unit tests for the protocol codec, the tap/hold state machine, pairing-URI parsing and the composing/commit logic (with a fake InputConnection).
   - `./gradlew lint testDebugUnitTest assembleDebug` must pass.
   - Also produce a release-signed APK with a **local** debug keystore under `android/keystore/` (gitignored). Document how it is generated.
8. **Battery and latency instrumentation:** `android/scripts/battery-session.sh` uses adb to reset batterystats, prompt the operator through N utterances, dump stats for `dev.chirp.android`, and grab an optional Perfetto trace. It writes a summary to stdout for `docs/bench.md`.

## Acceptance

- `cd android && ./gradlew lint testDebugUnitTest assembleDebug` passes. The APK is at `app/build/outputs/apk/debug/`.
- `android/README.md` covers:
  - toolchain setup
  - adb wireless pairing for the Fold 8
  - `adb install -r …`
  - enabling the IME and granting permissions
  - pairing with `chirp-server pair`
  - how to dictate
  - the battery measurement procedure
- Report exactly which steps need the operator (phone in hand).
