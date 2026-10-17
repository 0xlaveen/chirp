# Chirp Keyboard 0.3.0 validation

Validated 2026-10-17 on branch `chirp/keyboard`. App ID `dev.chirp.android`,
IME `dev.chirp.android/.ChirpImeService`, version code 3. HeliBoard v4.2 at
`0c60dffb03a4e2e7a37cb82210f5299f93c03979`; source, licenses and patch are in
[android/keyboard/UPSTREAM.md](../android/keyboard/UPSTREAM.md).

## Checks

`source ~/.local/share/chirp-android/env.sh` then, from `android/`:

```sh
./gradlew lint testDebugUnitTest assembleDebug assembleRelease
```

PASS. 153 tests, 0 failures, 0 errors;
2 opt-in LiveServerTest cases skipped. Tests include API 31/37 lifecycle,
editor disconnect/raw replacement, two consecutive dictations, tap/hold, cancel,
late events after hide/destroy, selection safety, real PCM framing/release,
crash-log privacy/retention/delegation, resolved-address/VPN permission policy,
app initialization, real-keyboard touch routing/window insets, wizard and renders.
App lint stays strict. The vendored module's internal FIR lint crash workaround
is documented in its upstream record.

The explicitly authorized `emulator-5580` (Android 17 fold AVD) passed the separate
`android/scripts/emulator-check.py` run using real cached Parakeet, a throwaway HOME
and port 7899, Keystore pairing, debug-generated synthetic speech through the real
PcmCapture/StreamTransport path, live composing partials, committed finals, two
consecutive utterances, tap/hold/cancel/hide, ordinary QWERTY typing after dictation,
HeliBoard settings → Chirp setup, and viewing/copying Diagnostics. Light and dark
screenshots are in [screenshots/android](screenshots/android/README.md).
No Chirp Java/native crash was recorded. The emulator has an unrelated UWB HAL crash
loop; checks are scoped to Chirp. The throwaway server was stopped and its credentials
and synthetic-input preference removed; the emulator stays running with Chirp selected.

## First-use findings

- The old voice-only default explicitly switched back to Samsung after final/raw
  expiry. The full keyboard never auto-returns; the legacy preference defaults OFF
  and is used only by the test-source historical IME.
- A failing regression reproduced an uncaught editor disconnect during the verified
  raw composing-region replacement, including cleanup calls. ComposingSession now
  treats editor calls as fallible and preserves corrected text on refused replacement.
- The original emulator crash buffer was empty. The operator's reported phone crash
  cannot be assigned a definitive stack without phone Diagnostics; no claim is made
  that it hit the reproduced exception.
- Android 17's local-network permission is requested only for resolved local servers
  outside matching VPN routes. Denial does not gate Tailscale. No DNS lookup is added
  to the microphone press/capture path.

## Artifacts

Both APKs retain the existing local certificate, SHA-256
`28595ce7194f6cb21ddfd44213605f82c4d296864bfe0c1b20f412892a6d7c96`.
`apksigner verify --print-certs` succeeds for both, and `adb install -r` succeeded
on the already-installed emulator package. No keystore is committed.

| APK | Bytes | MiB | SHA-256 |
| --- | ---: | ---: | --- |
| debug | 39,935,887 | 38.09 | `be7d5e8ae9f3a74cf52d81a42fe9fa8cb5bfb888c3aa3de6d168d89eead1f7b3` |
| release | 26,149,508 | 24.94 | `b9301f55336c3076aa260a678a2adec65a949ba18b100a0b8faa9cd3eb53c2cf` |

Paths: `android/app/build/outputs/apk/{debug,release}/app-{debug,release}.apk`.
Use **release** for the phone. It contains neither the generated WAV, synthetic capture
class/UI nor the emulator cleartext configuration. HTTP is restricted to the debug
emulator's `10.0.2.2:7899`; release remains HTTPS-only.

## Exact phone acceptance steps

1. Install the signed release APK **as an update; do not uninstall**. Existing Keystore
   pairing remains in app storage.
2. Open Chirp Keyboard → **Enable Chirp Keyboard**. On Samsung: Settings → General
   management → Keyboard list and default → enable Chirp, then select it as default.
3. Allow microphone permission. Leave the optional floating accessibility mic off.
4. Keep existing pairing, or scan the Mac's existing Chirp QR and tap **Test connection
   & save pairing** with Tailscale connected. Local-network permission is needed only
   for a direct Wi-Fi server; the tailnet/VPN path works without it.
5. In the test field, type a word, tap the mic to start/stop, dictate again, hold/release
   for push-to-talk, and cancel once. Chirp stays selected after every final. If cleanup
   is enabled, try **Use raw** within five seconds.
6. Open HeliBoard settings and return through **Chirp setup & pairing**. If anything
   fails, open Setup → **Diagnostics → Copy diagnostics** and paste the bounded log.
7. Repeat in Samsung Notes and a browser, including hide/reopen and fold/unfold. Real
   Galaxy microphone, OEM accessibility/FGS behavior, battery and Tailscale latency
   remain phone acceptance work; emulator synthetic input does not measure them.
