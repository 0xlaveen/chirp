# Chirp Keyboard for Android

A full HeliBoard keyboard for the Galaxy Z Fold with a microphone key that streams your voice to the `chirp-server` on your Mac — over Tailscale, from any app. Live text appears underlined in the focused field while you speak; the final replaces it. An optional clean-up pass on the Mac polishes the final text, and an opt-in history keeps recent dictations on the phone, encrypted.

The application ID and IME component stay `dev.chirp.android` / `dev.chirp.android/.ChirpImeService`, so a signed APK installs as an **update** and preserves your pairing (the token is encrypted under an Android Keystore key). Current version: **0.6.0**, version code 10.

| At a glance | |
|---|---|
| Keyboard base | HeliBoard 4.2 (GPL-3.0), vendored and patched — see [Upstream](#upstream) |
| Looks | **Gboard-like** default, a **Samsung-like** option, three classic HeliBoard looks |
| Fold layout | Phone-style function keys on the inner screen, number row ≥ 600 dp, split landscape |
| Swipe typing | Not bundled; you can load a user-supplied library — see [Keyboard](#keyboard) |
| Clean-up | On by default after pairing when the Mac cleans up locally; external endpoints need explicit opt-in |
| History | Opt-in, on-device only, AES-GCM encrypted under an Android Keystore key |
| Retention | Nothing written by default; diagnostics carry exception classes and frames only |

**Contents**

- [Install](#install) — build the APK, put it on the phone, update over Tailscale, enable the keyboard · [Pair](#pair) — QR, paste, Wi-Fi servers
- [Dictate](#dictate) — start/stop/cancel, quick options, clean-up, styles, Undo, Use raw
- [Keyboard](#keyboard) — typing, looks, Fold layout, swipe typing, floating mic
- [Dictation history](#dictation-history) · [Privacy](#privacy) · [Troubleshoot](#troubleshoot)
- [Develop and test](#develop-and-test) — toolchain, gradle, emulator harnesses
- [Upstream](#upstream) — HeliBoard, patches, dictionaries, license
- [Validation records](#validation-records) — dated runs, measurements and APK sizes

## Install

### Build the APK (once, on the Mac)

```sh
source ~/.local/share/chirp-android/env.sh   # toolchain; see "Develop and test"
cd android
./gradlew assembleRelease
```

The build produces two signed APKs in `app/build/outputs/apk/release/`: `app-arm64-v8a-release.apk` for the phone (arm64-v8a only) and `app-x86_64-release.apk` for emulator validation. Install the **arm64** APK on the phone — the ABI split makes it smaller than the former dual-ABI APK (25.7 MiB; measured sizes in [Validation records](#validation-records)). Signing uses `keystore/local-debug.keystore` (create it once with `scripts/make-keystore.sh`; without it the release build is unsigned). **Never generate a replacement key for an app that is already installed** — Android would refuse the update. Debug and release builds both use this local key.

### Put it on the phone

Install **as an update, without uninstalling Chirp** — that is what keeps the saved pairing. Either works:

- **Over Tailscale (Taildrop):** from the Mac, `tailscale file cp app/build/outputs/apk/release/app-arm64-v8a-release.apk <phone>:` — the file arrives as a notification in the phone's Tailscale app. Tap it to open the installer.
- **adb:** `adb install -r app/build/outputs/apk/release/app-arm64-v8a-release.apk` over USB or wireless debugging.

- **From your Mac, in the app (updates):** see [Update over Tailscale](#update-over-tailscale).

Opening a sideloaded APK can trigger a **Play Protect** screen warning about an unknown developer. Choose **More details → Install anyway** to continue. (A separate, optional sideload restriction can affect the floating microphone only — see [Optional floating microphone](#optional-floating-microphone).)

### Update over Tailscale

Once the first install is on the phone, later builds can update it in place from the paired Mac.

On the Mac, stage the signed arm64 release APK (`app-arm64-v8a-release.apk`, the phone split) and its manifest, then host that folder yourself at `/chirp-apk/` on the same tailnet host as the pairing (for example with your existing static file server behind `tailscale serve`; this script hosts and publishes nothing):

```sh
./gradlew assembleRelease
scripts/make-update-manifest.sh                       # → build/chirp-apk/chirp-<version>.apk + latest.json
```

`latest.json` holds `version_code`, `version_name`, `file` (a plain `*.apk` name in that folder), `sha256` and `size`. The script refuses an unsigned APK or one that isn't `dev.chirp.android`, and writes the manifest last.

On the phone, setup step 4 → **Updates** checks `https://<paired host>/chirp-apk/latest.json` when it opens, and **Check for updates** checks on demand. **Download and install** fetches the file, verifies its size and SHA-256 and that it is this app at the announced version, then hands it to Android's installer. Android shows its own confirmation and accepts the update only if it is signed with the installed key, so pairing is kept. The first time, Android asks you to allow Chirp to install updates.

- Only a pairing on a tailnet host (`*.ts.net` or a Tailscale address) gets update checks; the host is always the pairing's own, and the manifest can name only a file in that folder, never another URL. Redirects are not followed.
- The pairing token is never sent to the update path. Nothing about your text or audio is involved; the only request is the version file, and only when you open setup or tap check.
- Update logs, URLs and versions are not written to diagnostics.

### First launch

Chirp Keyboard's setup has four steps — *Chirp Keyboard, Microphone, Pair Mac, Try it* — and always opens on the first unfinished one, advancing automatically after you return from system settings.

1. **Enable Chirp Keyboard**, then **Select it as default**. On Samsung: Settings → General management → Keyboard list and default.
2. **Allow the microphone.** The mic opens only when you start dictation and is released as soon as you stop.
3. **Pair your Mac** — see [Pair](#pair). If the phone was already paired, the saved pairing survives the update.
4. **Try it:** tap the test field, type, then dictate. This step also holds the Stop dictation choice, the keyboard-look chooser, swipe-typing setup, history setting and Diagnostics.

HeliBoard's own settings (Keyboard layouts & settings) start with a **Chirp section**: pairing, test field, clean-up and styles (only when the Mac offers them), per-app styles, sounds/haptics, and diagnostics.

## Pair

On the Mac, print the secret pairing QR (see [server/README.md](../server/README.md#pair-a-device); the server must be published on your tailnet, e.g. `https://<your-mac>.<tailnet>.ts.net/chirp`):

```sh
uv run chirp-server pair --url https://<your-mac>.<tailnet>.ts.net/chirp
```

On the phone, setup step 3 (*Connect your Mac*) — with Tailscale on, on both devices:

- **Scan pairing QR** is primary (the scanner uses Google Play services). **Paste pairing link instead** works without it.
- **Test connection & save pairing** verifies the connection before anything is stored.
- A saved pairing shows the Mac host and the engine it reports, and offers **Check Mac connection** and **Forget pairing**.

The token is stored encrypted (AES-GCM) under the Android Keystore alias `chirp_pairing_v1`; pairing links are parsed strictly (`chirp://pair?url=…&token=…`, HTTPS only) and never rendered into logs. Recoverable connection problems offer **Pair Mac**, **Open mic settings** or **Check Tailscale** (which opens the Tailscale app when it is installed).

### Tailscale off when the keyboard opens

When the pairing points at a tailnet host (`*.ts.net`, `100.64.0.0/10` or `fd7a:115c:a1e0::/48`) and no VPN is applied to Chirp, the suggestion row shows **Tailscale is off** with a **Turn on** button. This check is local only, with no DNS lookup or network call. LAN or other pairings are never prompted.

- **Turn on** sends an explicit broadcast to the Tailscale app (`com.tailscale.ipn.CONNECT_VPN` to its exported `IPNReceiver`, the same hook Tasker-style automation uses). Tailscale connects only if you have already granted it Android's VPN permission and signed in. Chirp can't grant that permission or skip Android's consent dialog. Without it, Tailscale posts its own "open Tailscale" notification.
- The row says **Connecting Tailscale…**. When a VPN network appears it says **Tailscale connected** and reconnects to the Mac. If nothing connects within 10 seconds it offers **Open Tailscale**, so you can finish in the app.
- If Tailscale isn't installed, the row offers **Set up**, which opens Chirp setup's connection step.
- ✕, or typing past the prompt, hides it until Tailscale is next seen connected. Tapping the mic while Tailscale is off shows the prompt again instead of a generic *Mac unreachable* error.

Detection is conservative. It only knows whether *some* VPN applies to Chirp, because Android doesn't say which app owns another app's VPN. If a different VPN is active, Chirp shows no prompt, and a failed dictation still offers **Check Tailscale**. A successful Mac health check clears the prompt.

### Servers on your Wi-Fi (Android 17)

Android 17/API 37 needs `ACCESS_LOCAL_NETWORK` for servers reached directly over Wi-Fi/Ethernet. Chirp checks the paired server's resolved addresses and matching VPN routes in its network workers, never on the microphone press path. Setup requests permission only after a connection targets a local address outside a VPN. This includes RFC1918, link-local and local CGNAT/IPv6 addresses. Loopback JVM test servers are exempt.

**Needed only for servers on your Wi-Fi. Tailscale works without this permission.** Android explicitly excludes VPN traffic from its local-network definition, so an operator's `.ts.net` server resolving to 100.x through Tailscale is not permission-gated. Denial never prevents trying that tailnet connection. No DNS result or server address is added to diagnostics. Sources: [Android local-network definition](https://developer.android.com/privacy-and-security/local-network-definition) and [Android 17 permission behavior](https://developer.android.com/privacy-and-security/local-network-permission).

## Dictate

### Start, stop, cancel

- Tap the **mic in the suggestion row** to start. The mic changes colour and icon while listening, with a waveform and a subtle pulse.
- Tap the **stop icon** the mic becomes to finish and insert. **✕** discards the dictation.
- **Long press the mic** for quick options: **Clean-up: on ✓ / Clean-up: off** (or *Mac has clean-up off*), the styles the Mac advertises (`Style · <name>`, with `· rewrites` where it may restructure, ✓ on the active one), and **Chirp settings**.
- A configured keyboard **voice key** still supports push-to-talk: press-and-hold to talk, release to finish; a short tap toggles.
- Haptic cues fire on start, manual stop and successful insertion when haptics are enabled (they follow Android's system setting).
- **Chirp settings → Stop dictation** (also in setup's *Try it* step): **When I tap** (default) or **When I pause** with a pause of 1, 1.5, 2, 3 or 5 s (2 s default). Pause mode is a port of the Mac's auto-stop: speech is judged against the room's own noise floor, so steady background noise never counts as talking; it never stops before you have spoken, and gives up after 10 s of silence. Tapping stop still works in both modes.
- **Time limit**: the Mac accepts 120 s per dictation, so Chirp stops at 119 s. From 105 s the status adds **N s left** with one haptic tick (TalkBack hears it only at 15, 10, 5, 3, 2 and 1 s), and the dictation is finished and inserted like a normal stop.

The full keyboard always **stays selected after a final** — including when an old installation had the voice-only keyboard's auto-return enabled. (That auto-return is gone; the old voice-only implementation lives only in test sources and is not registered or shipped, and its historical preference now defaults OFF.) **Use raw** is offered for five seconds after a corrected final; moving the cursor or editing the field invalidates it.

### Mid-sentence casing and spoken commands

Finals (never partials) get a small local pass before they are inserted. When the text before the cursor shows a sentence under way (a word, digit, comma or semicolon, even behind a closing quote), the first word is lower-cased, so dictating *"And then we went"* after *"I woke up"* inserts `and then we went`. Field start, a new line, `. ! ?` and similar terminals, opening quotes/brackets, colons and list markers keep the capital. It is deliberately conservative: only common sentence starters (*and, but, so, we, the, it's, don't, …*) are lowered; "I" and its contractions, acronyms and mixed-case words (`NASA`, `GitHub`), and anything that could be a name (*Paris, Monday, Will*) are left as the Mac sent them. Other languages are left alone, and nothing changes if the editor can't show the text before the cursor.

**Spoken commands** are off by default (Chirp settings → *Spoken commands*). When on, a final that is exactly, or ends with, *new line* or *new paragraph* (any case, optional trailing punctuation) inserts one or two line breaks in place of those words, e.g. *"Okay, new line."* → `Okay,` + ⏎. The match is exact, so *new lines* or *a new line of work* are untouched, but a dictation that merely ends in the words does become a break. This runs on the phone after clean-up, so the Mac never sees the commands as text to polish. **Use raw** and dictation history keep the unmodified text the Mac returned.

### Dictated text is never lost

- **Undo** sits in the row for five seconds after every final, cleaned or not. It removes exactly what the dictation inserted, including the space Chirp added before it, and puts back any selection the dictation replaced. Typing, moving the cursor or starting another dictation ends the offer, like **Use raw**.
- **Failures keep what was heard.** If the connection drops, the Mac reports an error (engine, busy, 120-second limit…) or a deadline passes after at least one live partial, the last partial is committed as plain text (no clean-up) and the row shows **Connection lost — kept what I heard** (or the reason, e.g. **Dictation limit is 120 seconds — kept what I heard**) with **Undo**. With history on, the entry is marked **partial**. **✕**, typing over a live dictation, hiding the keyboard and switching to another field still discard it.
- **Moving the cursor stops instead of cancelling.** Tapping elsewhere in the field while listening sends stop; later partials no longer touch the field, and the final replaces the underlined text where you spoke it while your cursor stays where you put it. If the app dropped the underlined text, the final is inserted at your new cursor instead.

### What you see while you speak

Partials appear only in the text field, underlined with a slightly dimmed tail (supplied as spans when the editor supports them); the suggestion row is replaced by the waveform, status, ✕ and stop. Partials are coalesced to one editor update per 16 ms (latest sequence wins). Editors that can verify their composing text receive only the changed suffix; UTF-16 surrogate pairs stay intact. A server `stable` prefix becomes normal committed text while the remaining tail composes. A final or cancel re-marks the whole utterance so clean-up replaces it atomically and cancel restores the selection.

Showing the keyboard prewarms the bearer-authenticated socket without sending `start` or capturing sound; an unused warm socket closes after 30 seconds or when the keyboard hides. Capture still starts on press, before the server's `ready`, through a bounded buffer. Reduced-motion settings disable the pulse, shimmer and transition animations.

### Clean-up

Clean-up asks the Mac to polish the **final** text only; partials always stay raw. After pairing it is **on by default when the Mac's correction stays on that Mac**; an external correction endpoint requires explicit opt-in and a known host. Your toggle is recorded (`correction_explicit`) and persists across refreshes and restarts; if the Mac loses clean-up availability or its correction destination changes, clean-up suspends until you enable it again, and a server reporting clean-up off always dictates with `correction=false`.

While it runs, the raw transcript stays underlined in the field and the row shows **Polishing…**, an animated shimmer and the selected style chip; polishing stays readable for at least 450 ms even for very fast finals, and state changes fade over 180 ms. The final commits the cleaned text and shows a **cleaned** notice with a **Use raw** button for five seconds — one tap, exposed to TalkBack, invalidated by edits or cursor changes. Correction errors, disconnects and a 12-second polishing timeout commit the raw text with a **kept original** note. Recovery and error notices dismiss after five seconds to restore normal suggestions. An empty or blank final cancels the composition, inserts nothing (not even a separator or a deletion of a selection) and briefly shows **Didn't catch that**.

### Styles

Long press the mic to pick any health-advertised style plus Custom for the current editor. Chirp settings provide a default style and editable package-based overrides; matching uses `EditorInfo.packageName` exactly, and removed rows inherit the default. Initial defaults:

| Style | Packages |
|---|---|
| Chat | Slack, WhatsApp, Discord, Google Messages, Samsung Messages |
| Email | Gmail, Outlook, Samsung Email |
| Code | Termux and code editors (Acode, RHMsoft, Spck, DroidEdit) |
| Notes | Samsung Notes, Keep, Obsidian, Notion |

Styles missing from current health fall back to the selected default (or Default), and stay hidden when clean-up is unavailable — including an undisclosed external correction destination.

### Editable style prompts

**Clean-up styles** loads editable defaults from the authenticated `GET /v1/correction/profiles`. Every style shows its description; its prompt editor offers an **Edited** badge, a Unicode character count, the server's limit (at most 4000) and **Reset to default**. Fixed safety rules always apply. Existing Custom instructions migrate into Custom's prompt. Only edited styles send the optional `start.correction_prompt`; resetting omits the field so future server defaults apply. The legacy `correction_instructions` field remains limited to 2000 characters. Health caches only profile metadata, not default prompts. User edits are private app preferences excluded from backup; text and prompts are never logged. A server that does not yet expose the endpoint still supports normal styles; the editor then shows a retry action.

## Keyboard

### Typing

English (US) QWERTY, autocorrect at moderate confidence, suggestions, next-word prediction, auto-capitalisation, double-space period, key popups and symbol/accent long presses work out of the box. Personalised suggestions learn typed words on this device; turn them off in Keyboard layouts & settings → Text correction. Dictation finals bypass keyboard autocorrection and learning. The already-bundled English US dictionary is pinned to Codeberg, with an added English emoji suggestion dictionary; see [dictionary provenance and licenses](keyboard/UPSTREAM.md#english-typing-and-emoji-dictionaries-2026-10-17).

One-handed, split, clipboard history and emoji are reachable from the expandable toolbar. Light/dark follows the system.

### Keyboard look

Chirp settings (the Chirp section at the top of Keyboard layouts & settings) and the last setup step have a **Keyboard look** chooser with a small preview of each option:

| Look | HeliBoard settings it writes |
| --- | --- |
| **Gboard-like** (default) | Rounded style, key borders on, *Dynamic* (Material You) colours day and night |
| **Samsung-like** | Rounded style, key borders on, user colour themes `Samsung-like` / `Samsung-like dark` |
| HeliBoard classic | Material style, no borders, Light / Dark (HeliBoard's own defaults) |
| HeliBoard rounded | Rounded style, borders, Light / Dark |
| HeliBoard Holo | Holo style, Holo White |

Every look is applied only through HeliBoard's existing theme preferences (`theme_style`, `theme_key_borders`, `theme_colors`, `theme_colors_night`, `theme_auto_day_night`) and its user colour themes; nothing in the vendored keyboard was changed for this. The Gboard-like look follows the wallpaper through Android's dynamic colours: neutral keys with gaps on a tinted background, accent-tinted Shift/Backspace/?123 keys, an accent Enter key and long-press hint labels. The Samsung-like look uses neutral white/grey (light) or charcoal (dark) keys, grey function keys and a blue Enter key. Both can be fine-tuned under Appearance, which also still offers every HeliBoard colour, style and background; when Appearance holds anything other than a preset, the chooser shows it as a custom look. Key height, number row, one-handed and split settings are unchanged.

The migration `chirp_keyboard_look_v1` runs once in `ChirpApplication`, next to the existing `chirp_keyboard_defaults_v1` / typing defaults. An install with no theme preference at all (fresh, or 0.5.x that never opened Appearance) switches to the Gboard-like look; any theme preference already written was chosen explicitly and is kept. Later choices are never overwritten.

The Chirp row takes its colours from the active HeliBoard theme instead of a fixed green palette. Its background is transparent, so HeliBoard's own suggestion-row colour (or a background image) shows through. The idle mic uses the key text colour like Gboard's toolbar icons; while listening it becomes an accent pill with a contrasting icon. The waveform and Polishing… shimmer use the accent, darkened or lightened until it reaches 3:1 contrast against the row. **Use raw** and the style chip use a translucent accent chip. The red debug-retention banner is unchanged.

### Fold inner/cover layout

Unfolding keeps the cover keyboard's function-key arrangement in both looks: **Shift starts the third letter row, Backspace ends it, and Enter sits after the period at bottom-right** — instead of HeliBoard's tablet arrangement. Chirp seeds HeliBoard's phone functional layout once (migration `chirp_functional_layout_v1`); explicitly chosen global or per-language functional layouts remain yours. The number row defaults on at inner-screen widths (600 dp and wider; an explicit choice wins). Unfolded landscape defaults to split; cover layouts stay compact. See [Fold layout details](keyboard/UPSTREAM.md#fold-function-key-arrangement-2026-10-18) and the `fold-layout-*.png` before/after emulator captures in [docs/screenshots/android](../docs/screenshots/android).

### Swipe typing

HeliBoard's gesture typing needs a native decoder, and HeliBoard 4.2 ships none. It supports `System.load` of a user-supplied library (`JniUtils`, `LoadGestureLibPreference`), normally Google's proprietary `libjni_latinimegoogle.so`, with a SHA-256 check against a known release for each ABI. **Chirp must not bundle or download that file**, so no gesture library is bundled — but setup and Chirp settings can load one you supply. Options reviewed (2026-10-18):

- **User-supplied library through HeliBoard's loader (implemented).** Same mechanism and checksums as HeliBoard's *Load gesture typing library*. You obtain the file and choose it; Chirp does not distribute, download or link to it. Quality matches Gboard's decoder, because it is that decoder.
- **HeliBoard's own open-source decoder** ([NLnet GestureTyping](https://nlnet.nl/project/GestureTyping/)): planned as a GPL drop-in for the same JNI interface. Gesture data gathering runs until November 2026; no release exists yet. Preferred future option — it would need no Chirp UI change beyond bundling it.
- **[CleverKeys](https://github.com/tribixbite/CleverKeys)** (GPL-3.0, fork of Unexpected Keyboard): an on-device CTC/transformer swipe model with ONNX Runtime (MIT), about 89% top-1 on its own English benchmark. Licence-compatible but a different keyboard: porting its decoder, model and ONNX Runtime into HeliBoard's batch-input path means several MB of APK and a separate maintenance burden. Not release-ready; needs an operator decision.
- **FlorisBoard `StatisticalGlideTypingClassifier`** (Apache-2.0, GPL-3.0 compatible): small and pure Kotlin, but FlorisBoard labels glide typing alpha, disabled by default; its quality does not justify replacing the option above.
- **AnySoftKeyboard** (Apache-2.0): separate architecture with widely reported accuracy problems. **FUTO Keyboard**'s decoder uses the Source First licence, which is not open-source compatible — rejected.

**Enable swipe typing** (setup → last step, or Chirp settings):

1. The card explains that Chirp has no built-in swipe typing, that a compatible library is usually Google's `libjni_latinimegoogle.so` from a GApps package, that Chirp never downloads or includes it, and that using it is your choice under that library's own licence. It names the ABI the phone needs (`arm64-v8a` on the Fold).
2. **Add gesture library…** opens the system file picker. The file is copied privately (64 MB limit) and checked: an ELF shared object for this ABI, then SHA-256.
3. A matching checksum shows **Verified gesture library**. Anything else shows **Unknown library**, with the start of its hash and a warning, and needs an explicit **Use anyway**. A wrong ABI or a non-library file is rejected and deleted.
4. Chirp installs the file exactly where HeliBoard's loader expects it (read-only `files/libjni_latinime.so`, checksum in `lib_checksum`) and restarts, because native code loads once per process. HeliBoard's Gesture typing settings then appear.
5. When the library is active, the card offers a **Swipe to type** switch and **Remove gesture library**. A file that fails to load is reported, with a Remove action.

The card warns that the library runs inside Chirp with Chirp's permissions, including network access — use only a file from a source you trust — and that a user-supplied library may not be built for 16 KB memory pages and so can fail to load on Android 15+ devices that use them (Chirp's own packaged libraries are checked for 16 KB alignment at every build). Release smoke still asserts that no `libjni_latinimegoogle` file is packaged.

### Optional floating microphone

The floating accessibility mic is **optional and off by default**; keyboard dictation needs no Accessibility permission. Enable it only if you choose to use another keyboard — it reads the focused field locally to insert safely, runs as a microphone foreground service with a notification, and field contents stay on the phone. For sideload restrictions: Apps → Chirp Keyboard → ⋮ → Allow restricted settings, then Accessibility → Installed apps. An already-enabled optional service remains under your Android setting; the app does not enable it on update. Design notes on this and the other input paths considered are in [docs/android-input-options.md](../docs/android-input-options.md).

## Dictation history

Dictation history is **off by default**. When enabled, committed finals (plus the raw text when on-Mac clean-up rewrote them) are stored **on the phone only**, encrypted with AES-GCM under a dedicated Android Keystore alias (`chirp_history_v1`) in credential-encrypted storage — never sent to the Mac, never logged, and excluded from backup and device transfer (`data_extraction_rules.xml` excludes the root, file and sharedpref domains). The store keeps at most **200 entries** and prunes by age: **24 hours, 7 days (default) or 30 days**. Password and incognito fields (`TYPE_TEXT_VARIATION_PASSWORD` variants and `IME_FLAG_NO_PERSONALIZED_LEARNING`) are never recorded, and cancelled dictations leave no entry. While the device is locked the store is unavailable and the panel says so ("Unlock your phone to see dictation history.").

- **Keyboard**: a clock button sits next to the mic in the Chirp row. It opens an in-keyboard panel (over the key area, like HeliBoard's clipboard panel, so height and insets are unchanged). First use offers one-tap **Keep history on this phone** — nothing is written before that. Tapping an entry reinserts it through the same boundary and selection path as a dictated final; long-press offers **Copy**, **Insert raw** (when the entry was cleaned) and **Delete**. **Use raw** after a cleaned dictation updates the stored entry. Back or the keyboard button closes the panel; plaintext stays in memory only while the panel is open, and the keys are hidden from accessibility while it is up.
- **Settings**: the Chirp section has a **Keep dictation history on this phone** switch, the retention chooser, **Open history** (a full screen with search, copy, copy-raw and per-entry delete, excluded from recents thumbnails) and **Clear history**. Turning the feature off asks first and then deletes the file and the Keystore key.

A small pre-existing fix shipped with it: moving the cursor after a cleaned final used to dismiss the raw-undo chip but leave the "cleaned" notice pinned open forever, hiding the row's idle buttons. The notice now expires on its five-second timer.

## Privacy

- **Nothing is retained by default.** Audio and transcripts live in memory for the length of an utterance. No text, audio, URLs or tokens are logged; server error strings are never rendered into diagnostics. While the Mac runs with debug retention, a red **DEBUG: recordings kept on Mac** banner stays visible in the Chirp row.
- **The mic opens only when you start dictation** and is released as soon as you stop. The optional floating mic declares the same rules in its accessibility description.
- **History is opt-in and on-device.** Entries never leave the phone, are AES-GCM encrypted under a Keystore key, and are excluded from backup and device transfer.
- **Pairing secrets are encrypted at rest** (Android Keystore) and redacted from any `toString`. Pairing links are treated as secrets; they are parsed strictly and never logged.
- **Crash diagnostics are bounded.** Setup → Diagnostics shows/copies the last five local uncaught crashes: time, app version, exception class and at most 48 message-free class/method/line frames. The handler writes synchronously before delegating termination. It does not store exception messages, cause messages, filenames, thread names, text, audio, URLs or tokens. The private, backup-excluded log survives an app restart/update. HeliBoard's original crash handler and keyboard logger are disabled so they cannot retain a second content log.
- **Clean-up disclosure.** Styles stay hidden when clean-up is unavailable, including an undisclosed external correction destination; external correction always requires explicit opt-in and shows its host.

## Troubleshoot

Setup → **Diagnostics** copies the bounded crash log (see [Privacy](#privacy)). Common messages on the suggestion-row status bar:

| Bar message | What it means | What to do |
|---|---|---|
| "Pairing refused — pair again in Chirp setup" | Server `auth` error | Re-pair from setup (**Pair Mac**) |
| "Didn't catch that" | Empty/blank final or server `bad_audio` | Speak again; nothing was inserted |
| "Speech engine hiccup" | Server `engine` error | Retry; check `chirp-server doctor` on the Mac |
| "Mac is busy — try again" | Server `busy` (engine occupied) | Retry after a moment |
| "Dictation limit is 120 seconds" | Server `too_long` | Split long dictations |
| "Clean-up prompt too long — shorten it in Chirp settings" | Server `bad_request` on the prompt | Edit the style prompt |
| "Mac speech engine unavailable — try again" | Unknown server error | Retry; check the server |
| "Mac took too long to finish — try again" | Final timed out locally | Retry; check the Mac's load |
| "Mac offline · tap to retry" (mic drawn with a slash) | The last health check or prewarm failed in the past 30 s | Tap the mic or the row: it re-checks for up to 3 s, then dictates or names the reason |
| "Can't find your Mac on the tailnet — is it online?" | DNS lookup of the pairing host failed | Check Tailscale on the phone; check the Mac is online and signed in to the same tailnet |
| "Mac may be asleep, or Chirp isn't running" | Connect timeout or refused connection, or no Ready within 7 s | Wake the Mac; check Chirp is running (see the Mac tip below) |
| "Couldn't make a secure connection to your Mac" | TLS handshake or certificate error | Check the pairing URL is the Mac's `tailscale serve` HTTPS address; re-pair if it changed |
| "Mac connection is too slow — try again" | Transport stalled | Check Tailscale (**Check Tailscale**) |
| "Connection lost — kept what I heard" (or another reason) | The socket dropped, the Mac errored or timed out after partials arrived | The last partial was inserted as plain text; tap **Undo** to remove it |
| "kept original" after Polishing… | Clean-up failed, timed out (12 s) or the socket dropped | Raw text was inserted; edit the style or check the Mac |
| "Unlock your phone to see dictation history." | History store is credential-encrypted | Unlock the device |

**Mac tip:** on the Mac, turn on System Settings → Battery → Options → *Wake for network access* and let Chirp launch at login, so the phone can reach it while the Mac is idle.

**Offline mic.** Failure reasons come from exception classes only (no messages, hosts or URLs are kept) and are worded as possibilities, since Android sees the symptom, not the cause. A failed health check or prewarm marks the Mac offline for 30 seconds: the suggestion row shows **Mac offline · tap to retry** and the mic is drawn with a slash, with TalkBack reading "Mac offline, double-tap to retry". ✕ or typing hides the row; the slash stays until the Mac answers or 30 seconds pass. Tapping never waits: it re-checks health for at most 3 seconds, then dictates, or shows the specific reason; a second tap during the check dictates at once. A Mac that answers over HTTP (even with an error) is not offline. **Tailscale is off** keeps priority over this row. Dictation gives up on a Mac that is not Ready within 7 seconds (the pre-Ready buffer holds only 5 seconds of audio).

Recoverable errors also offer **Pair Mac**, **Open mic settings** and **Check Tailscale** actions. With a tailnet pairing and no VPN up, the row shows **Tailscale is off** with **Turn on** instead (see [Tailscale off when the keyboard opens](#tailscale-off-when-the-keyboard-opens)). A historical note: a reproducible 0.5.1-era crash (`NetworkOnMainThreadException` during TLS teardown on stop/keyboard-hide) was fixed by moving all HTTP cancellation, pool eviction and dispatcher shutdown to one process-wide background queue — see the [validation record](#051-stop-crash-fix-2026-10-17). If an editor disconnected during the raw composing-region replacement, older builds could crash; all editor calls in `ComposingSession` now fail safely without exposing editor exceptions, losing the corrected text on a rejected replacement, or allowing late callbacks to insert into another field (lifecycle coverage: final, repeated utterances, hide/unbind/destroy, stale capture/transport callbacks, cancel and raw expiry). The first regression test for that crash failed before the fix; the original installed emulator crash buffer was empty, which does **not** establish that the operator's phone hit that same exception.

## Develop and test

### Toolchain (once)

```sh
android/scripts/setup-toolchain.sh   # user-scoped; no sudo, no emulator images
```

Installs Zulu JDK 21 and the Android SDK (platform-tools, android-37.2, build-tools 37.0.0) under `~/.local/share/chirp-android/` (override with `CHIRP_TOOLS`/`ANDROID_HOME`) and writes `~/.local/share/chirp-android/env.sh`, which exports `JAVA_HOME`, `ANDROID_HOME` and `PATH`.

### Build and unit tests

```sh
source ~/.local/share/chirp-android/env.sh
cd android
./gradlew lint testDebugUnitTest assembleDebug assembleRelease
```

Use the **existing** `keystore/local-debug.keystore` to sign updates; never generate a replacement key for an already-installed app. The keyboard module builds both ABIs, but the app splits packaging (`splits.abi`, no universal APK): every build yields an `app-arm64-v8a-<build>.apk` for phones and an `app-x86_64-<build>.apk` for x86_64 emulator validation, under `app/build/outputs/apk/{debug,release}/`. Release smoke installs whichever split matches the connected emulator's ABI (the local `chirp-fold` AVD reports `arm64-v8a` on Apple Silicon). Each assemble also runs `check<Build>Native16kAlignment` (`scripts/check-native-alignment.py`): every packaged `.so` must have only 16 KB-aligned ELF `PT_LOAD` segments and the APK zip layout must satisfy `zipalign -P 16`, because Android 15+ devices may use 16 KB memory pages. The host and library use NDK 28.0.13004108 (NDK r28 aligns by default); the app setting is needed to strip JNI symbols. App lint remains strict (warnings as errors); only the vendored keyboard's `lint*Analyze*` tasks are disabled (upstream lint crash — see [Upstream](#upstream)). See [keyboard/UPSTREAM.md](keyboard/UPSTREAM.md) for the pinned source, license, adapter, upstream patch and vendor-only lint workaround.

Robolectric runs on API 31 and 37 with fake input connections, transport and capture. The integrated keyboard renders actual HeliBoard keys and the production Chirp row in idle/listening/final states, light/dark, under `../docs/screenshots/android/`. Existing transport tests use isolated TLS loopback servers. LiveServerTest stays opt-in (`-Pchirp.live.url` …); no production Chirp server or port 7821 is used by the default check.

### Mandatory release smoke

Run `android/scripts/emulator-smoke.sh` with the toolchain sourced after every change. It builds and installs the minified release APK split matching the emulator's ABI, clears only the authorized disposable emulator's Chirp data, walks state-aware setup, opens/backs out of the real Google QR scanner, opens the native editor, checks keyboard/mic/recovery/options, and exercises actual HeliBoard keys: `teh` → `the` (sentence-cased at field start), `im` → `I'm`, next-word suggestions, clipboard history and emoji. It checks inner and cover layouts in both themes, unfolded landscape split, one-handed reachability, settings/diagnostics, packaged dictionary hashes, absence of debug assets/proprietary glide libraries and the Chirp crash buffer. Failure exits non-zero. Every ADB call pins `emulator-5580`; other serials are refused. It changes no phone, Mac configuration, production server or Tailscale state.

A tiny shell-only UiAutomator probe reads all accessibility windows because Android 17's stock `uiautomator dump` returns the editor window without the IME (`scripts/build-ui-probe.sh` builds it under a temporary directory from `UiHierarchy.java`, pushes it to the disposable emulator and removes it in cleanup; it ships in neither APK). Real release captures are `docs/screenshots/android/release-*.png`, each under 2 MB. Release has no synthetic capture source or emulator cleartext policy.

### Emulator speech checks (debug only)

The operator-authorized emulator is **emulator-5580 only** — `emulator-check.py` refuses other serials (an `ANDROID_SERIAL` that disagrees is rejected too). The helper starts the actual server with a throwaway HOME on port 7899, uses the existing cached speech model, pairs through the QR deep-link path, and feeds generated speech through the real `PcmCapture` framing, buffer, `StreamTransport` and composing/final path. All subprocess/intent output that could contain a credential is suppressed. The test server and test credentials are removed in cleanup; the emulator is left running.

```sh
source ~/.local/share/chirp-android/env.sh
python3 android/scripts/emulator-check.py \
  --python /path/to/chirp/server/.venv/bin/python \
  --model-dir /path/to/cached/parakeet-mlx \
  --apk android/app/build/outputs/apk/debug/app-x86_64-debug.apk
```

| Flag | Runs |
|---|---|
| *(none)* | Debug synthetic-speech E2E |
| `--tls` | HTTPS/WSS on 7899 with the disposable debug CA |
| `--stop-check` | The eight-scenario stop matrix (all stop/teardown paths, incl. crash checks) |
| `--history-check` | Dictation-history flow (opt-in, reinsert, Insert raw, ciphertext check) |
| `--cleanup-only` | Managed clean-up E2E only |
| `--frames-only` | Uninstrumented frame metrics (no recording/polling during speech) |
| `--expect-crash` | Pre-fix TLS baseline expecting `NetworkOnMainThreadException` |
| `--server-root PATH` | Use another server checkout (default: the repo's `server/`) |
| `--tls-dir PATH` | Root for the debug CA/key (default `android/app/build`) |

Reproduce the TLS stop matrix after building debug (requires `openssl` for the generated test cert):

```sh
source ~/.local/share/chirp-android/env.sh
python3 android/scripts/emulator-check.py --stop-check --tls \
  --python /path/to/server/.venv/bin/python --model-dir /path/to/cached/parakeet-mlx \
  --apk android/app/build/outputs/apk/debug/app-x86_64-debug.apk
# Omit --tls for HTTP. To check old behaviour, create a disposable detached worktree
# at a31415b^ and add --server-root /path/to/old-worktree/server.
```

The debug-only test cert/key is generated under `app/build/` (`generated/chirp-debug-res/raw/emulator_ca.pem` and `emulator-tls/key.pem`; 7-day CA, renewed near expiry, SAN restricted to `10.0.2.2`/`127.0.0.1`), with trust restricted to `10.0.2.2`; the private key stays on the host. The matching cert is bundled in debug only.

The debug test-step switch **Debug: synthetic speech (no microphone)** selects a say-generated 16 kHz mono WAV. The asset is generated into `app/build/`, never committed. On macOS the debug build invokes `say`/`afconvert`; other hosts may set `CHIRP_SYNTHETIC_WAV` to a generated synthetic-only WAV. This file source, switch and asset are excluded from release. The release capture uses AudioRecord only. The debug cleartext policy permits only `10.0.2.2`; URL validation further restricts HTTP to port 7899. Release permits HTTPS only and has no cleartext exception.

Emulator screenshots are independent of the deterministic Robolectric renders. Neither run establishes Galaxy hardware microphone quality, battery cost or Tailscale latency; those still need operator acceptance on the phone.

### TalkBack, icons, fold captures, battery

```sh
android/scripts/build-ui-probe.sh                    # rebuild the shell probe first
python3 android/scripts/emulator-talkback.py         # enables real TalkBack, validates mic/status/cancel
                                                     # labels and native click/long-click, restores settings
python3 android/scripts/emulator-icons.py            # captures release-launcher-icon.png,
                                                     # release-app-icon-settings.png, release-keyboard-picker-icon.png
python3 android/scripts/emulator-fold-layout.py --look samsung   # (or gboard) fold-layout-*.png captures
android/scripts/battery-session.sh                   # operator-driven battery session → docs/bench.md row
```

`make-icons.swift` regenerates the launcher/notification icon resources from the approved artwork — sources, deterministic packaging and asset paths are in [artwork/chirp-icons/README.md](artwork/chirp-icons/README.md).

## Upstream

- **Source**: HeliBoard v4.2 stable (checked 2026-10-17), pinned at commit `0c60dffb03a4e2e7a37cb82210f5299f93c03979`; `keyboard/upstream/` is the complete vendored release source archive, not a submodule.
- **License**: HeliBoard is GPL-3.0 (with AOSP Apache-2.0 code and separately licensed assets). The combined Android app includes GPL-3.0 HeliBoard code. Personal use; corresponding source is available in this repository. Keep the upstream licenses/notices intact. See [keyboard/UPSTREAM.md](keyboard/UPSTREAM.md).
- **Patches**: every upstream change is marked **CHIRP** and recorded in `keyboard/patches/chirp.patch` — host hooks, disabled crash reporter and keyboard logging, in-process voice availability, voice-key touch handling, number-row/fold defaults, accessibility refresh, split-layout cache fix.
- **Dictionaries**: `main_en-US.dict` and `emoji_en.dict` from the Codeberg-pinned [aosp-dictionaries](https://codeberg.org/Helium314/aosp-dictionaries); SHA-256s are tabulated and smoke-checked. See [dictionary provenance](keyboard/UPSTREAM.md#english-typing-and-emoji-dictionaries-2026-10-17).
- **Lint**: AGP 9.4.1/Kotlin 2.4.21 lint crashes on one upstream file; only the vendored library's `lint*Analyze*` tasks are disabled (reports kept). The Chirp app lint stays strict.
- **Icons**: app-level overlays replace HeliBoard's icon IDs; sources and packaging are in [artwork/chirp-icons/README.md](artwork/chirp-icons/README.md).

## Validation records

Dated records of what was actually run, per feature, with the APK sizes of the day. The earliest full record (0.3.0) is [docs/android-keyboard-validation.md](../docs/android-keyboard-validation.md).

### Round 4 typing release (2026-10-17)

The full `lint testDebugUnitTest assembleDebug assembleRelease` path passed: 175 tests, 0 failures/errors, 2 pre-existing opt-in skips. Release smoke passed scanner open/back, state-aware setup, actual autocorrect/next-word keys, clipboard, emoji, the integrated mic and recovery, inner/cover light/dark, unfolded landscape split, one-handed control reachability, settings/diagnostics and crash checks. `emulator-talkback.py` additionally enabled actual TalkBack and validated mic/status/cancel labels and native click/long-click actions before restoring the settings. Debug synthetic E2E passed against the isolated real Parakeet server with Keystore pairing, live composing text, repeated committed finals, cancellation, quick options, normal typing after dictation, light/dark and IME retention; the throwaway server was stopped. It does not claim live speech transport over HTTPS from the release build — the release APK uses AudioRecord, and smoke validates its UI without a live HTTPS speech session or the debug synthetic/cleartext facilities. Release APK: **26,684,648 bytes (25.45 MiB)**, containing arm64-v8a and x86_64. The English US dictionary added **0 bytes** because the pinned file was already bundled; the new emoji dictionary is 45,272 bytes before APK compression (21,095 packaged bytes). The typing/defaults phase added 25,068 bytes relative to the pre-typing UX release build (26,659,580 bytes). Screenshots in `../docs/screenshots/android/release-*.png` are from the real release emulator, each below 2 MB. No phone, production server, Mac app or Tailscale setting was used or modified.

### 0.5.0 clean-up, styles and streaming (2026-10-17)

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed with **198 tests, zero failures/errors, two opt-in skips**. Tests cover protocol metadata and editable prompts, TLS bearer requests, omission/reset/migration, Unicode limits, exact package mapping, prewarming/expiry, coalescing, suffix edits with a real `BaseInputConnection`, stable-prefix rollback, cancellation, polishing fallback, readable transitions and reduced motion.

Managed cleanup E2E passed against a real Parakeet/Qwen server on **7899** with a temporary HOME, `[correction] mode="managed"`, and the shared offline HF cache. The helper was warmed before UI captures to exclude first-use model/Metal setup; the app still has its normal 12-second polishing deadline. The capture helper requires `ffmpeg` to keep the exported recording below ten seconds. The debug asset used messy synthetic speech generated under `app/build/`; no audio is committed. Both themes captured underlined raw composition, Polishing + style, cleaned + Use raw, and native accessible raw replacement. The test removes its server, credentials and device probes and re-selects Chirp after force-stop. Reproduce with `--cleanup-only` (or `--frames-only` for the uninstrumented run) in the [emulator speech check](#emulator-speech-checks-debug-only) command.

Release `scripts/emulator-smoke.sh` and actual `emulator-talkback.py` also passed on **emulator-5580 only**. Release remains AudioRecord-only and HTTPS-only; live managed speech was exercised through the debug synthetic/cleartext path. APK: **26,716,080 bytes (25.48 MiB)**, version **0.5.0 (6)**, arm64-v8a and x86_64, signed with the existing local key.

Artifacts under `../docs/screenshots/android/`:

- `emulator-cleanup-{polishing,cleaned,styles}-{light,dark}.png` — actual emulator states.
- `emulator-cleanup-streaming.mp4` — a silent 9.54-second screen recording (10-second capture cap).
- `emulator-cleanup-gfxinfo.txt` — recorded run: 194/199 janky frames, p50 85 ms.
- `emulator-cleanup-uninstrumented-gfxinfo.txt` — no capture/polling during speech: 161/170 janky frames, p50 133 ms.
- `emulator-release-typing-gfxinfo.txt` — ordinary release typing baseline: 83/95 janky frames, p50 32 ms.

These measurements do **not** establish smooth 60 fps. The authorized AVD has `hw.gpu.enabled=no`; ordinary typing is also substantially janky, and its host concurrently runs ASR/cleanup. The source recording averages about 14.9 fps. GPU-backed device validation remains necessary to assess animation smoothness. The emulator's GPU configuration was not changed. No phone, production Chirp configuration/server, Mac app, LaunchAgent or Tailscale setting was modified.

### 0.5.0 launcher and themed icons

The release uses the operator's **full-bleed moonlit pond bird** artwork. The adaptive icon has that complete composition as its background, navy overscan to keep the moon and bird inside the safe viewport, and an empty foreground (the explicitly approved fallback). No rounded tile is added; the launcher supplies its own mask. Legacy density variants use the same opaque source, with resource aliases sharing normal/round names. App-level overlays replace HeliBoard's icon IDs, including the About/settings icon, and the IME service references the new launcher mipmap explicitly. Android 13+ monochrome uses the selected round fin-bird glyph **with** waves. The floating microphone notification uses the **same original alpha without the detached waves**, retaining its eye/pupil, fins and feet. The exact supplied sources, deterministic packaging script and asset paths are documented in [artwork/chirp-icons/README.md](artwork/chirp-icons/README.md). Built-in imagegen cutout attempts were discarded; generated replacements do not ship.

The full lint/unit/debug/release path passed with **202 tests, zero failures/errors, two opt-in skips**. Icon tests on API 31/37 verify application and IME service icon resolution, HeliBoard's resource overlay, visible orange bird/yellow moon under the adaptive mask, monochrome availability and notification alpha. Release smoke passed after the icon update. `scripts/emulator-icons.py` also passed on emulator-5580, leaving Chirp selected, capturing `release-launcher-icon.png` (actual app drawer), `release-app-icon-settings.png` (actual Android app-info icon) and `release-keyboard-picker-icon.png` (native picker; this Android build uses text-only rows, while the IME's icon metadata is verified by the API tests). Signed release APK: **26,949,136 bytes (25.70 MiB)**, still **0.5.0 (6)**. App lint retains warnings-as-errors; two narrow icon-style exceptions cover the v26 vendor-overlay qualifier and deliberately full-bleed legacy artwork.

### 0.5.1 stop-crash fix (2026-10-17)

The phone's crash was TLS teardown on the main thread. A minified baseline built from `2c9c2e8` (the Android implementation also present at `a31415b`), with only the emulator TLS trust setup and version metadata changed, reproduced it on **emulator-5580**. Both `adb logcat -b crash` and the app's Diagnostics recorded:

```text
android.os.NetworkOnMainThreadException
  ConscryptEngineSocket.drainOutgoingQueue → ConscryptEngineSocket.close
  okhttp3.internal.connection.RealConnectionPool.evictAll → ConnectionPool.evictAll
  KeyboardDictation.start$lambda$9 (KeyboardDictation.kt:267)
  DictationStream.event$lambda$0 (DictationStream.kt:91)
```

The R8 debug mapping (`app/build/intermediates/mapping/debug/minifyDebugWithR8/mapping.txt`, R8 9.4.24) confirms the synthetic callback and source line. TLS `close_notify` writes explain why earlier cleartext speech checks passed. The same synchronous pool eviction was called on keyboard hide and through setup/style-editor client disposal.

All HTTP call cancellation, pool eviction and dispatcher shutdown now use one process-wide background queue. Cancellation snapshots the outgoing session's calls before enqueueing, so late cleanup cannot cancel calls created after an immediate keyboard hide/show. WebSocket close/cancel stays asynchronous. Health, pairing and profile HTTP requests already run on `Dispatchers.IO`; their lifecycle cancellation/disposal now also leaves the main thread. Debug builds enable StrictMode network detection with `penaltyDeath`.

An empty/blank final cancels the utterance's composition, inserts nothing, and briefly shows **Didn't catch that**. Stopping capture before the first frame is a normal completion. `bad_audio`, `engine`, `busy`, `too_long`, `auth`, `bad_request` and unknown errors have bounded local messages (see [Troubleshoot](#troubleshoot)); auth keeps the Pair Mac recovery action. Regression tests cover these messages, empty results before and during polishing, repeated stop/cancel/focus-loss callbacks, and main-thread pool eviction.

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed: **217 tests, zero failures/errors, two opt-in skips**. The stop matrix passed with real cached Parakeet and managed Qwen cleanup, throwaway HOME and port **7899** only:

- Current server over HTTP: all eight cases plus in-app Diagnostics.
- Current server over TLS: all eight cases with clean logcat and crash preferences.
- Pre-`a31415b` server (`2c9c2e8`) over TLS: all eight cases plus in-app Diagnostics, including a zero-frame stop returning `bad_audio` rather than an empty final.
- Cases: stop before Ready with zero audio frames, listening, after a partial, during polishing, repeated stop taps, stop/hide, stop/focus loss, and stop/IME unbind.

The harness delays Ready and the first synthetic frame for the immediate case, holds final delivery briefly to observe real managed polishing, and waits for each server session to retire. These controls affect only debug capture and the disposable test server. No audio, transcripts, credentials or TLS private keys are committed. Content-free baseline/fixed crash evidence is stored outside git under `/tmp/chirp-stopcrash-{baseline,fixed}/`. Reproduce with `--stop-check --tls` as shown in [Develop and test](#emulator-speech-checks-debug-only).

Release artifact inspection confirms no synthetic source, cleartext exception, emulator trust certificate or private key. `scripts/emulator-smoke.sh` passed the signed minified release on **emulator-5580 only**, including setup/scanner, typing/autocorrect, clipboard, emoji, Fold layouts/themes, mic recovery, settings and Diagnostics with no Chirp crash. Chirp was reselected after force-stops. Release was **0.5.1 (7)**, **26,950,788 bytes (25.70 MiB)**, arm64-v8a and x86_64, signed with the existing local development key.

### 0.5.1 clean-up default follow-up (2026-10-18)

Clean-up now defaults **on** after pairing with an available **on-Mac** correction server. The `correction_explicit` flag records a user's toggle independently of the legacy `correction` boolean: an untouched 0.5.0 `false` no longer hides the feature after upgrade. Explicit OFF persists across refreshes and restarts. Setup, keyboard settings and the mic menu record choices; changing haptics or the debug overlay does not. External correction still requires explicit opt-in and a known host. Availability drops or correction-destination changes suspend correction until the user enables it again. A server reporting correction off always produces `correction=false` on start, even after an earlier explicit ON. Setup places Clean-up and styles directly below the paired Mac/engine, explains that local cleanup polishes punctuation/filler words without text leaving the Mac, and shows **Mac has clean-up off** when unavailable. External correction retains its destination disclosure.

The full `lint testDebugUnitTest assembleDebug assembleRelease` path passed: **235 tests, zero failures/errors, two opt-in skips**. New coverage includes local/external defaults, legacy preference migration, explicit OFF, privacy/availability transitions, server-off start frames, visible controls and independent toggle callbacks. The real managed TLS stop matrix passed all eight scenarios on **emulator-5580**, without enabling correction in the harness: every observed start frame carried `correction=true`, and managed polishing ran with clean logcat and in-app Diagnostics. The signed minified release UI smoke also passed. Live speech/start-frame checks use debug's isolated TLS trust; release retains system trust only. The AVD was run as a disposable read-only instance at port 5580 after stale AVD locks blocked normal startup. No physical device or production server was used. Signed release APK at that point: **26,950,808 bytes (25.70 MiB)**; no APK was published.

### Fold inner-screen layout (2026-10-18)

Fold-layout validation: `lint testDebugUnitTest assembleDebug assembleRelease` passed (256 cases, zero failures/errors, two opt-in skips). Forty release screenshots cover before/after, both looks, light/dark, native AVD, inner portrait/landscape and cover portrait/landscape. Key geometry checks passed; cover and native-AVD coordinates remain unchanged. Release `emulator-smoke.sh` and the TLS stop matrix (`emulator-check.py --tls --stop-check`) passed on emulator-5580 only. All eight stop scenarios delivered STOP and retired their stream, with clean Chirp crash/Diagnostics checks under StrictMode network death. The disposable server reported `engine` during polishing and `bad_audio` during focus teardown; the matrix checks stop/teardown safety rather than correction quality. No phone or emulator-5582 was used, and the version remained **0.5.2 (8)** at that point.

### Dictation history (2026-10-18; released as 0.6.0)

Unit coverage (Robolectric): encryption round-trip with software keys, tamper/corrupt file discard, retention pruning, the 200-entry cap, opt-in gating, password/incognito exclusion, clear-on-disable (including a record racing the disable), used-raw updates, insert boundary logic, panel states, settings-screen search, and the notice-expiry regression (fails without the fix). `./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed on the merged branch: **285 tests, zero failures/errors, two opt-in skips**.

Emulator validation ran on **emulator-5582 only** (a second disposable read-only `chirp-fold` instance, used while emulator-5580 belonged to a parallel worker — the checked-in helper itself pins emulator-5580), debug APK with the throwaway TLS server on port 7899: `--history-check` drives the demo end to end — keyboard opt-in, synthetic dictation with clean-up, ciphertext check (no plaintext words on disk), erase and reinsert from the panel, long-press Insert raw, Fold inner/cover in light and dark, back-closes-panel, history-screen search, and turn-off-deletes-file. Screenshots land in `docs/screenshots/android/` as `emulator-history-*.png`; the pre-feature baseline strip is `history-before-keyboard-inner-{light,dark}.png`. Before that, the full `--stop-check --tls` matrix and the release smoke (`scripts/emulator-smoke.sh`) were re-run on this branch. No physical device or production server was used.

Reproduce after building debug, with the [emulator speech check](#emulator-speech-checks-debug-only) command plus `--history-check --tls` (on the authorized emulator-5580). The branch carried no version bump — still **0.5.1 (7)**, signed release APK **27,025,176 bytes (25.76 MiB)** — and was released as **0.6.0 (10)** with the history feature. No APK was published beyond the repository.

### arm64-only phone APK and 16 KB page gate (2026-10-23)

Release packaging splits by ABI (`splits.abi` in the app module; no universal APK, same version code for both outputs): every build produces `app-arm64-v8a-<build>.apk` and `app-x86_64-<build>.apk` under `app/build/outputs/apk/<build>/`, signed with the existing local key. Signed release sizes: arm64 **26,588,220 bytes (25.36 MiB)**, x86_64 **26,603,730 bytes (25.37 MiB)**. Native libraries are the only ABI-specific payload — compressed `libjni_latinime.so` (≈420 KB arm64 / ≈435 KB x86_64) plus `libandroidx.graphics.path.so` (≈4–5 KB) — so the phone APK saves **about 440 KB** against the equivalent dual-ABI build; the 0.6.0-era dual-ABI release measured 27,025,176 bytes. The keyboard module still compiles both ABIs.

Every assemble finalizes with `check<Build>Native16kAlignment` (`scripts/check-native-alignment.py`): every packaged `.so` must have only `PT_LOAD` segments aligned ≥ 16384, stored zip entries must be 4-byte aligned, and an uncompressed `.so` entry must sit on a 16 KB boundary (`zipalign -P 16` semantics). Both current libraries are NDK r28 builds (aligned by default) and are deflated in the APK (legacy packaging), so ELF alignment is the load-time gate. The swipe-typing card and this README warn that a user-supplied gesture library may not be 16 KB-compatible and can fail to load on Android 15+ 16 KB-page devices. `docs/android-input-options.md` marks Path A (voice subtype, auto-start, `switchToPreviousInputMethod`) retired and fixes the Chirp Keyboard naming.

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed on the rebased head (including #47): **366 tests, zero failures/errors, two pre-existing opt-in skips**, both splits built and both alignment checks green. (Lint's informational downgrade of the time-dependent `GradleDependency`/`NewerVersionAvailable`/`AndroidGradlePluginVersion` checks comes from main and covers the Gradle 9.8.2/OkHttp 5.5.1 releases of mid-October 2026.) Release smoke on **emulator-5580 only**: the script resolves the split by the emulator's reported ABI, and the local `chirp-fold` AVD reports **arm64-v8a** on an **Android 17 16 KB-page image** (`sdk_gphone16k_arm64`, page size 16384) — so smoke runs the app on a 16 KB-page system. The run installed the signed arm64 split and passed artifact inspection, the setup wizard, QR scanner open/back, mic permission and pairing actions, long-press options and the real-key typing checks (`teh`→`the`, `I'm`, next-word, clipboard, emoji) before flaking on the first Fold-loop settings cold start (60 s timeout on a contended host). Three later emulator starts crash-looped at QEMU startup (hanging `QEMU2 main loop` after Vulkan init, with and without software GPU); the only native crash in logcat was the system `android.hardware.uwb-service` aborting for a missing `/dev/uwb0`, never `dev.chirp`. The Fold inner/cover theme sweep, landscape split, one-handed reachability and settings/diagnostics screens were therefore not re-verified in this round, and with no x86_64 emulator on this host the x86_64 split was validated by build, the 16 KB gate and artifact inspection only. No phone, production server or Tailscale state was touched.
