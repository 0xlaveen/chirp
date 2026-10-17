# Chirp Keyboard for Android

Chirp 0.5.0 combines HeliBoard 4.2's full keyboard with in-keyboard dictation to your
Mac over Tailscale. The application ID and IME component remain
`dev.chirp.android` / `dev.chirp.android/.ChirpImeService` so the signed APK installs
as an update and preserves Android Keystore pairing. Version code is 6.

## Phone setup

1. Install the **signed release APK as an update**, without uninstalling Chirp.
2. Open Chirp Keyboard. In step 1, **Enable Chirp Keyboard**, then **Select it as default**.
   On Samsung: Settings → General management → Keyboard list and default.
3. Allow microphone permission. If already paired, pairing stays saved. Otherwise,
   turn on Tailscale on both devices, scan the existing Mac QR, and **Test connection & save pairing**.
4. Tap the test field. Type normally, then tap the mic in the suggestion row to start.
   The **stop icon** finishes and **✕** discards dictation. Long press the toolbar mic
   to choose a style, toggle clean-up (when offered by the Mac), or open Chirp settings. A configured keyboard voice key still
   supports push-to-talk.
5. Dictate twice. The full keyboard always stays selected after a final, including
   when an old installation had auto-return enabled. **Use raw** is available for
   five seconds after a corrected final; moving/editing the field invalidates it.

English (US) QWERTY, autocorrect at moderate confidence, suggestions, next-word
prediction, auto-capitalisation, double-space period, key popups and symbol/accent
long presses work out of the box. Personalised suggestions learn typed words on this
device; turn them off in Keyboard layouts & settings → Text correction. Dictation
finals bypass keyboard autocorrection and learning. The already-bundled English US
dictionary is pinned to Codeberg, with an added English emoji suggestion dictionary;
see [dictionary provenance and licenses](keyboard/UPSTREAM.md#english-typing-and-emoji-dictionaries-2026-10-17).

The number row defaults on at inner-screen widths (600 dp and wider). Unfolded
landscape defaults to split; cover layouts stay compact. One-handed, split, clipboard
history and emoji are reachable from the expandable toolbar. Haptics follow Android's
system setting. Light/dark follows the system. **Swipe typing: not available**; no
proprietary gesture library is bundled. No compatible open-source HeliBoard decoder is
currently available; the source review is recorded in `keyboard/UPSTREAM.md`.

Setup opens the first unfinished prerequisite and advances after returning from system
settings. QR pairing is primary; paste is secondary. A saved pairing shows the Mac host
and reported engine. HeliBoard settings start with a Chirp section: pairing, test
field, clean-up and styles (only when supported), per-app styles, sounds/haptics, and diagnostics. The mic shares the suggestion
row, and active dictation replaces suggestions with waveform, status, cancel and done.
Partials appear only in the text field. Recoverable errors offer Pair Mac, Open mic
settings, or Check Tailscale. Debug retention stays visible in the row while reported.

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
scripts/emulator-smoke.sh
```

Use the **existing** `keystore/local-debug.keystore` to sign updates; never generate a
replacement key for an already-installed app. Debug and release both use that key in
this local build. APKs are `app/build/outputs/apk/{debug,release}/app-{debug,release}.apk`.
The host and library use NDK 28.0.13004108; the app setting is needed to strip JNI symbols.
The release supports arm64 phones and x86_64 emulator validation. See
[keyboard/UPSTREAM.md](keyboard/UPSTREAM.md) for the pinned source, license, adapter,
upstream patch and vendor-only lint workaround. App lint remains strict.

Robolectric runs on API 31 and 37 with fake input connections, transport and capture.
The integrated keyboard renders actual HeliBoard keys and the production Chirp row
in idle/listening/final states, light/dark, under `../docs/screenshots/android/`.
Existing transport tests use isolated TLS loopback servers. LiveServerTest stays
opt-in; no production Chirp server or port 7821 is used by the default check.

## Mandatory release smoke

Run `android/scripts/emulator-smoke.sh` with the toolchain sourced after every change.
It builds and installs the minified release APK, clears only the authorized disposable
emulator's Chirp data, walks state-aware setup, opens/backs out of the real Google QR
scanner, opens the native editor, checks keyboard/mic/recovery/options, and exercises
actual HeliBoard keys: `teh` → `the` (sentence-cased at field start), `im` → `I'm`,
next-word suggestions, clipboard history and emoji. It checks inner and cover layouts
in both themes, settings/diagnostics, packaged dictionary hashes, absence of debug
assets/proprietary glide libraries and the Chirp crash buffer. Failure exits non-zero.
Every ADB call pins `emulator-5580`; other serials are refused. It changes no phone,
Mac configuration, production server or Tailscale state.

A tiny shell-only UiAutomator probe reads all accessibility windows because Android 17's
stock `uiautomator dump` returns the editor window without the IME. It is built under a
temporary directory, pushed to the disposable emulator and removed in cleanup. It ships
in neither APK. Real release captures are `docs/screenshots/android/release-*.png`, each
under 2 MB. Release has no synthetic capture source or emulator cleartext policy.

## Explicit emulator speech check (debug only)

The operator-authorized emulator is **emulator-5580 only**. The helper refuses other
serials, starts the actual server with a throwaway HOME on port 7899, uses the existing
cached speech model, pairs through the QR deep-link path, and feeds generated speech
through the real `PcmCapture` framing, buffer, `StreamTransport` and composing/final path.
All subprocess/intent output that could contain a credential is suppressed. The test
server and test credentials are removed in cleanup; the emulator is left running.

```sh
source ~/.local/share/chirp-android/env.sh
python3 android/scripts/emulator-check.py \
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

## Round 4 validation (2026-10-17)

The full `lint testDebugUnitTest assembleDebug assembleRelease` path passes: 175 tests,
0 failures/errors, 2 pre-existing opt-in skips. Release
smoke passes scanner open/back, state-aware setup, actual autocorrect/next-word keys,
clipboard, emoji, the integrated mic and recovery, inner/cover light/dark, unfolded
landscape split, one-handed control reachability, settings/diagnostics and crash checks.
`emulator-talkback.py` additionally enables actual TalkBack, validates mic/status/cancel
labels and native click/long-click actions, then restores accessibility/notification
settings. Run it after release smoke with the shell probe rebuilt:

```sh
android/scripts/build-ui-probe.sh
python3 android/scripts/emulator-talkback.py
```

Debug synthetic E2E passed against the isolated real Parakeet server with Keystore
pairing, live composing text, repeated committed finals, cancellation, quick options,
normal typing after dictation, light/dark and IME retention. The throwaway server was
stopped. It does not claim live speech transport over HTTPS from the release build;
the release APK uses AudioRecord and smoke validates its UI without a live HTTPS
speech session or the debug synthetic/cleartext facilities.

Release APK: **26,684,648 bytes (25.45 MiB)**, containing arm64-v8a and x86_64. The
English US dictionary adds **0 bytes** because the pinned file was already bundled;
the new emoji dictionary is 45,272 bytes before APK compression (21,095 packaged bytes). The typing/defaults
phase adds 25,068 bytes relative to the pre-typing UX release build (26,659,580 bytes).
Screenshots in `../docs/screenshots/android/release-*.png` are from the real release
emulator, each below 2 MB. No phone, production server, Mac app or Tailscale setting was
used or modified.


## Clean-up, styles and streaming (0.5.0)

The mic changes colour and icon while listening, with a waveform and subtle pulse.
Start, manual stop and successful insertion use haptic cues when enabled. Showing the
keyboard prewarms the bearer-authenticated socket without sending `start` or capturing
sound. An unused warm socket closes after 30 seconds or when the keyboard hides.
Capture still starts on press, before the server's `ready`, through the bounded buffer.

Partials are coalesced to one editor update per 16 ms, retaining the latest sequence.
Verified editors receive only the changed suffix; UTF-16 pairs remain intact. A server
`stable` prefix becomes normal editor text while the remaining tail composes. A final or
cancel re-marks the utterance so cleanup replaces it atomically and cancel restores the
selection. Editors that cannot verify their composing text use full composition updates.
Underlining and a slightly dimmed tail are supplied as spans when the editor supports them.

On `correcting`, the full raw transcript remains underlined in the field. The suggestion
row shows **Polishing…**, an animated shimmer and the selected style chip. State changes
fade/slide over 180 ms; polishing stays readable for at least 450 ms for very fast finals.
Reduced-motion settings disable the pulse, shimmer and transition animations. Final commits
cleaned text and shows **cleaned · Use raw** for five seconds. The raw action is one tap,
exposed to TalkBack, and invalidated by edits or cursor changes. Correction errors,
disconnects and a 12-second polishing timeout commit the raw text with **kept original**.
Recovery/error notices dismiss after five seconds to restore normal suggestions.

Long press the mic to select any health-advertised style plus Custom for the current editor.
Chirp settings provide a default style and editable package-based overrides. Initial defaults
cover Slack/WhatsApp/Discord/Google and Samsung Messages (Chat), Gmail/Outlook/Samsung Email
(Email), Termux and code editors (Code), and Samsung Notes/Keep/Obsidian/Notion (Notes).
Matching uses `EditorInfo.packageName` exactly; removed rows inherit the default. Styles
missing from current health fall back to the selected default or Default. Styles stay hidden
when cleanup is unavailable, including an undisclosed external correction destination.

**Clean-up styles** loads editable defaults from the authenticated
`GET /v1/correction/profiles`. Every style shows its description; its prompt editor offers
an Edited badge, a Unicode character count, the server's limit (at most 4000), and Reset to
default. Fixed safety rules always apply. Existing Custom instructions migrate into Custom's
prompt. Only edited styles send optional `start.correction_prompt`; resetting omits the field
so future server defaults apply. The legacy `correction_instructions` protocol limit remains
2000 characters. Health caches only profile metadata, not default prompts. User edits are
private app preferences excluded from backup. Text and prompts are never logged.

The new prompt endpoint/override protocol is covered with an isolated TLS fake server. A
server that does not yet expose the endpoint still supports normal styles; the editor shows
a retry action. Prompt loading requires the corresponding server addition.

### 0.5.0 validation (2026-10-17)

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed with **198 tests,
zero failures/errors, two opt-in skips**. Tests cover protocol metadata and editable prompts,
TLS bearer requests, omission/reset/migration, Unicode limits, exact package mapping,
prewarming/expiry, coalescing, suffix edits with a real `BaseInputConnection`, stable-prefix
rollback, cancellation, polishing fallback, readable transitions and reduced motion.

Managed cleanup E2E passed against a real Parakeet/Qwen server on **7899** with a temporary
HOME, `[correction] mode="managed"`, and the shared offline HF cache. The helper is warmed
before UI captures to exclude first-use model/Metal setup; the app still has its normal
12-second polishing deadline. The capture helper requires `ffmpeg` to keep the exported recording below ten seconds.
The debug asset uses messy synthetic speech generated under
`app/build/`. No audio is committed. Both themes captured underlined raw composition,
Polishing + style, cleaned + Use raw, and native accessible raw replacement. The test removes
its server, credentials and device probes and re-selects Chirp after force-stop.

```sh
source ~/.local/share/chirp-android/env.sh
ANDROID_SERIAL=emulator-5580 python3 android/scripts/emulator-check.py --cleanup-only \
  --python /path/to/server/.venv/bin/python \
  --model-dir /path/to/cached/parakeet-mlx \
  --apk android/app/build/outputs/apk/debug/app-debug.apk
# Same setup without recording/accessibility polling during speech:
# replace --cleanup-only with --frames-only
```

Release `scripts/emulator-smoke.sh` and actual `emulator-talkback.py` also passed on
**emulator-5580 only**. Release smoke covers the signed minified APK, setup/scanner, typing,
clipboard/emoji, mic recovery/options, inner/cover themes, landscape split, settings and no
crash. Release remains AudioRecord-only and HTTPS-only; live managed speech was exercised
through the debug synthetic/cleartext path. APK: **26,716,080 bytes (25.48 MiB)**, version
**0.5.0 (6)**, arm64-v8a and x86_64, signed with the existing local key.

Artifacts are under `../docs/screenshots/android/`:

- `emulator-cleanup-{polishing,cleaned,styles}-{light,dark}.png` — actual emulator states.
- `emulator-cleanup-streaming.mp4` — a silent 9.54-second screen recording (10-second capture cap).
- `emulator-cleanup-gfxinfo.txt` — recorded run: 194/199 janky frames, p50 85 ms.
- `emulator-cleanup-uninstrumented-gfxinfo.txt` — no capture/polling during speech:
  161/170 janky frames, p50 133 ms.
- `emulator-release-typing-gfxinfo.txt` — ordinary release typing baseline:
  83/95 janky frames, p50 32 ms.

These measurements do **not** establish smooth 60 fps. The authorized AVD has
`hw.gpu.enabled=no`; ordinary typing is also substantially janky, and its host concurrently
runs ASR/cleanup. The source recording averages about 14.9 fps. GPU-backed device validation remains
necessary to assess animation smoothness. The emulator's GPU configuration was not changed.
No phone, production Chirp configuration/server, Mac app, LaunchAgent or Tailscale setting was
modified.


### Selected launcher and themed icons (0.5.0)

The release now uses the operator's **full-bleed moonlit pond bird** artwork. The adaptive
icon has that complete composition as its background, navy overscan to keep the moon and
bird inside the safe viewport, and an empty foreground (the explicitly approved fallback).
No rounded tile is added; the launcher supplies its own mask. Legacy density variants use
the same opaque source, with resource aliases sharing normal/round names. App-level overlays
replace HeliBoard's icon IDs, including the About/settings icon, and the IME service references
the new launcher mipmap explicitly.

Android 13+ monochrome uses the selected round fin-bird glyph **with** waves. The floating
microphone notification uses the **same original alpha without the detached waves**, retaining
its eye/pupil, fins and feet. The exact supplied sources, deterministic packaging script and
asset paths are documented in [artwork/chirp-icons/README.md](artwork/chirp-icons/README.md).
Built-in imagegen cutout attempts were discarded; generated replacements do not ship.

The full lint/unit/debug/release path passes with **202 tests, zero failures/errors, two
opt-in skips**. Icon tests on API 31/37 verify application and IME service icon resolution,
HeliBoard's resource overlay, visible orange bird/yellow moon under the adaptive mask,
monochrome availability and notification alpha. Release smoke passes after the icon update.
`scripts/emulator-icons.py` also passes on emulator-5580, leaving Chirp selected. It captures:

- `release-launcher-icon.png` — actual app drawer with the selected artwork.
- `release-app-icon-settings.png` — actual Android app-info icon.
- `release-keyboard-picker-icon.png` — native picker; this Android build uses text-only rows,
  while the IME's icon metadata is verified by the API tests.

To repeat after release smoke: run `scripts/build-ui-probe.sh`, then
`python3 scripts/emulator-icons.py` with the toolchain sourced and
`ANDROID_SERIAL=emulator-5580`. Current signed release APK: **26,949,136 bytes (25.70 MiB)**,
still **0.5.0 (6)** with the existing signing key. App lint retains warnings-as-errors; two
narrow icon-style exceptions cover the v26 vendor-overlay qualifier and deliberately
full-bleed legacy artwork.
