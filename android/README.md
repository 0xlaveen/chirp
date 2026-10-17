# Chirp Keyboard for Android

Chirp 0.3.0 combines HeliBoard 4.2's full keyboard with in-keyboard dictation to your
Mac over Tailscale. The application ID and IME component remain
`dev.chirp.android` / `dev.chirp.android/.ChirpImeService` so the signed APK installs
as an update and preserves Android Keystore pairing. Version code is 3.

## Phone setup

1. Install the **signed release APK as an update**, without uninstalling Chirp.
2. Open Chirp Keyboard. In step 1, **Enable Chirp Keyboard**, then **Select it as default**.
   On Samsung: Settings → General management → Keyboard list and default.
3. Allow microphone permission. If already paired, pairing stays saved. Otherwise,
   turn on Tailscale on both devices, scan the existing Mac QR, and **Test connection & save pairing**.
4. Tap the test field. Type normally, then tap the mic above the keys to start/stop.
   Hold the mic for push-to-talk; release to finish. **✕** discards dictation.
5. Dictate twice. The full keyboard always stays selected after a final, including
   when an old installation had auto-return enabled. **Use raw** is available for
   five seconds after a corrected final; moving/editing the field invalidates it.

English (US) QWERTY is the first-run default. The number-row and emoji preferences
remain HeliBoard defaults. Light/dark follows the system. Keyboard layouts & settings
opens HeliBoard's settings; **Chirp setup & pairing** there returns to the wizard.
Correction and timing diagnostics remain in Chirp's test step. A red debug-retention
banner appears when the server reports that it retains audio/text.

The floating accessibility mic is **optional and off by default**; keyboard dictation
needs no Accessibility permission. Enable it only if you choose to use another keyboard.
For sideload restrictions: Apps → Chirp Keyboard → ⋮ → Allow restricted settings,
then Accessibility → Installed apps. An already-enabled optional service remains
under the user's Android setting; the app does not enable it on update.

## Android 17 Wi-Fi permission

Android 17/API 37 needs `ACCESS_LOCAL_NETWORK` for servers reached directly over
Wi-Fi/Ethernet. Chirp checks the paired server's resolved addresses and matching VPN
routes in its network workers, never on the microphone press path. Setup requests
permission only after a connection targets a local address outside a VPN. This includes
RFC1918, link-local and local CGNAT/IPv6 addresses. Loopback JVM test servers are exempt.

**Needed only for servers on your Wi-Fi. Tailscale works without this permission.**
Android explicitly excludes VPN traffic from its local-network definition, so the
operator's `.ts.net` server resolving to 100.x through Tailscale is not permission-gated.
Denial never prevents trying that tailnet connection. No DNS result or server address
is added to diagnostics. Sources: [Android local-network definition](https://developer.android.com/privacy-and-security/local-network-definition)
and [Android 17 permission behavior](https://developer.android.com/privacy-and-security/local-network-permission).

## Diagnostics and the reported first-use failure

The previous voice-only keyboard defaulted to auto-return, explicitly switching to
Samsung after a final (or after the raw chip's five-second expiry). This is removed
from the full keyboard. The old voice-only implementation lives only in test sources;
it is not registered or shipped. Its historical preference now defaults OFF.

A reproducible uncaught exception existed if an editor disconnected during the raw
composing-region replacement or its cleanup. The first regression failed before the
fix. All editor calls in `ComposingSession` now fail safely without exposing editor
exceptions, losing the corrected text on a rejected replacement, or allowing late
callbacks to insert into another field. Lifecycle coverage includes final, repeated
utterances, hide/unbind/destroy, stale capture/transport callbacks, cancel and raw expiry.
The original installed emulator crash buffer was empty; this does **not** establish
that the operator's phone hit that same exception.

Setup → **Diagnostics** shows/copies the last five local uncaught crashes. The handler
writes synchronously before delegating termination. Stored fields are time, app version,
exception class and at most 48 message-free class/method/line frames. It does not store
exception messages, cause messages, filenames, thread names, text, audio, URLs or tokens.
The private, backup-excluded log survives an app restart/update. HeliBoard's original
crash handler and keyboard logger are disabled so they cannot retain a second content log.

## Build and test

```sh
source ~/.local/share/chirp-android/env.sh
cd android
./gradlew lint testDebugUnitTest assembleDebug assembleRelease
```

Use the **existing** `keystore/local-debug.keystore` to sign updates; never generate a
replacement key for an already-installed app. Debug and release both use that key in
this local build. APKs are `app/build/outputs/apk/{debug,release}/app-{debug,release}.apk`.
The host and library use NDK 28.0.13004108; the app setting is needed to strip JNI symbols.
The release supports arm64 phones and x86_64 emulator validation. See
[keyboard/UPSTREAM.md](keyboard/UPSTREAM.md) for the pinned source, license, adapter,
upstream patch and vendor-only lint workaround. App lint remains strict.

Robolectric runs on API 31 and 37 with fake input connections, transport and capture.
The integrated keyboard renders actual HeliBoard keys and the production Chirp strip
in idle/listening/final states, light/dark, under `../docs/screenshots/android/`.
Existing transport tests use isolated TLS loopback servers. LiveServerTest stays
opt-in; no production Chirp server or port 7821 is used by the default check.

## Explicit emulator speech check (debug only)

The operator-authorized emulator is **emulator-5580 only**. The helper refuses other
serials, starts the actual server with a throwaway HOME on port 7899, uses the existing
cached speech model, pairs through the QR deep-link path, and feeds generated speech
through the real `PcmCapture` framing, buffer, `StreamTransport` and composing/final path.
All subprocess/intent output that could contain a credential is suppressed. The test
server and test credentials are removed in cleanup; the emulator is left running.

```sh
source ~/.local/share/chirp-android/env.sh
uv run --no-project --with pillow python android/scripts/emulator-check.py \
  --python /path/to/chirp/server/.venv/bin/python \
  --model-dir /path/to/cached/parakeet-mlx \
  --apk android/app/build/outputs/apk/debug/app-debug.apk
```

The debug test-step switch **Debug: synthetic speech (no microphone)** selects a
say-generated 16 kHz mono WAV. The asset is generated into `app/build/`, never committed.
On macOS the debug build invokes `say`/`afconvert`; other hosts may set
`CHIRP_SYNTHETIC_WAV` to a generated synthetic-only WAV. This file source, switch and
asset are excluded from release. The release capture uses AudioRecord only.
The debug cleartext policy permits only `10.0.2.2`; URL validation further restricts
HTTP to port 7899. Release permits HTTPS only and has no cleartext exception.

Emulator screenshots are independent of the deterministic Robolectric renders. Neither
run establishes Galaxy hardware microphone quality, battery cost or Tailscale latency;
those still need operator acceptance on the phone.

## License

The combined Android app includes GPL-3.0 HeliBoard code. Personal use; corresponding
source is available in this repository. Keep the upstream licenses/notices intact.
See [keyboard/UPSTREAM.md](keyboard/UPSTREAM.md).
