# Chirp for Mac

`Chirp.app` is a small menu-bar app. Press a hotkey in any app, talk, and the text appears in the focused field. Audio streams to your local `chirp-server` (`ws://127.0.0.1:7821/v1/stream`), and a floating HUD shows the live partial text while you speak. See [docs/architecture.md](../docs/architecture.md) for the protocol and privacy rules.

Native Swift 6, SwiftPM, AppKit. No Xcode needed: the Command Line Tools are enough.

## Build

```sh
cd mac
swift build            # debug build
./scripts/test.sh      # unit tests (see "Tests" below)
./scripts/bundle.sh    # release build → build/Chirp.app, signed
./scripts/install.sh   # copy to ~/Applications/Chirp.app
open ~/Applications/Chirp.app
```

### Signing (do this once)

macOS ties Microphone and Accessibility grants to the app's code signature. An ad-hoc signature changes on every build, so the grants would reset each time. Create a stable local identity once:

```sh
./scripts/make-cert.sh
```

It creates a self-signed "Chirp Local Dev" code-signing certificate in your login keychain. macOS may ask for your login password to trust it, and the first `codesign` may ask to allow keychain access (choose *Always Allow*). If the identity is missing, `bundle.sh` signs ad-hoc and warns.

## Permissions

On first launch the **Set Up Chirp** window opens (reopen it any time from Settings → General, or from the menu's "Set Up Chirp…", which appears while a permission is missing or the server is unreachable). Its steps are Welcome, Microphone, Accessibility, the speech server and Try it; each permission or server step shows live status (it turns green as soon as you grant access in System Settings) and a **Fix** button. Skipping a step is allowed: Chirp then works with what it has (without Accessibility it copies instead of typing). The Try it step has a text field and turns green when it hears your hotkey. The "set up" flag is stored only when you finish the last step; closing the window early shows it again next launch. Permissions are granted in **System Settings → Privacy & Security**:

| Permission | Why | Without it |
|---|---|---|
| Microphone | capture your voice | dictation refuses to start and opens the Microphone pane |
| Accessibility | set text in the focused field and send ⌘V | text is only copied to the clipboard ("Copied — press ⌘V") |

The hotkey is a Carbon hot key (`RegisterEventHotKey`, delivering press and release), so **Input Monitoring is not needed**. Settings → Permissions shows the status of both, with a Fix button only for one that is missing. After granting Accessibility you may need to relaunch the app.

The Mac mini has no built-in microphone. Chirp follows the system default input (shown in the menu's Microphone row), including when you plug in or unplug a USB mic, unless you pick a device in the Microphone submenu.

## Using it

- **Hotkey:** ⌃⌥Space by default; pick ⌃⇧Space or ⌃⌥⌘Space in Settings → General, or press **Record Shortcut…** there and type your own. The hotkey lives only in Settings; the menu just shows it. The recorder (AppKit, no macros, no Input Monitoring) refuses combinations that cannot fire and says why, and keeps listening: ⌥ or ⌥⇧ with no ⌃/⌘ (since macOS 15 they register but never fire), ⌃Space alone (Raycast's default and the input-source switcher), ⇧ alone or no modifier, Esc, and a few system shortcuts (⌘Space, ⌘Tab, ⌘Q). Esc, or a click elsewhere, gives up. While it listens the live hotkey is released so pressing it does not start a dictation. A stored custom shortcut is validated again on load. A press shorter than 300 ms toggles (tap to start, tap to stop). A longer press is push-to-talk: hold, speak, release.
- **Esc** cancels: the server discards the audio and nothing is inserted. Esc is only captured while a dictation is active.
- The **HUD** is a floating capsule at the bottom centre of the screen under the mouse, just above the Dock, and never takes focus (a non-activating panel). Its background is a real `NSVisualEffectView` (HUD material), so it follows light and dark. A live waveform from the input level sits at the left, then a short status: Connecting…, Listening, Finishing…, Inserting…, Inserted, Copied — ⌘V (a symbol replaces the waveform once there is an outcome). Stable text is shown normally and the still-changing tail dimmed; the capsule grows with the text up to a maximum width, then wraps (four lines at most) and animates its size. It fades and scales in and out; **Reduce Motion** drops the scale and the animation (steady bars instead of a moving waveform) and **Increase Contrast** switches to an opaque surface with a stronger border and a less dimmed tail.
- **Sounds** (menu submenu and Settings → Sounds, off by default): a quiet cue when dictation starts and another when capture ends. Packs: **Chirp** (default; a soft songbird), **Soft** (marimba, a fifth up/down), **Glass**, **Click**, **System** (stock Tink/Pop) and **Custom…** (your own aiff/wav/caf/m4a/mp3 for start and stop, copied into `~/Library/Application Support/Chirp/Sounds/`). The Sounds tab has the on/off switch, the pack picker with ▶ previews and a volume slider (default 60 %). The start cue finishes before the microphone opens (it waits min(cue + 20 ms, 300 ms); a longer start sound is trimmed to 0.3 s), so it is never recorded. The packs are synthesised by `scripts/make-sounds.swift`; see [docs/sounds.md](docs/sounds.md).
- **Silence guard:** if the input is digitally silent for 1.5 s you get "No microphone signal" and the session is cancelled.
- **Clean-up** (menu submenu or Settings → Clean-up, off by default) asks the server to clean up the final text; it is the protocol's `correction` flag. While the server cleans up, the HUD does not sit on "Finishing…": the server's `correcting` message makes it show the **raw transcript** at once as solid text with a **Polishing…** status, a sparkle and a soft shimmer sweeping across the text (Reduce Motion: a still sparkle and no sweep), and the style as a small chip ("Email"). When the final arrives the HUD crossfades to the cleaned text and, for about 0.8 s, highlights what changed (removed words struck through and fading, changed or added words tinted; a word-level diff, skipped for very long text), then inserts it once. If clean-up fails, times out (the client gives up after 12 s; the server's own limit is 8 s) or the socket drops while it runs, the raw text is inserted with a small **kept original** note. When the server rewrote the text, the HUD says Inserted with a **cleaned** badge and offers **Use raw** for 5 s. "Offer Use raw for 5 seconds after clean-up" (Settings → Clean-up, on by default) stops the Use raw offer when you turn it off; the badge stays. Esc during Polishing cancels as before: nothing is inserted. The help text under the checkbox comes from `/v1/health`: "Runs on this Mac", "Sends the text to <host> to tidy it" when health says it leaves the machine, or that the server has clean-up off (the checkbox is then disabled). Audio never leaves the Mac.
- **Insert raw immediately, then replace with cleaned** (Settings → Clean-up, off by default): when `correcting` arrives, the raw text is inserted at once and, once the cleaned text is in, swapped in place with the existing safe AX replace (same app still frontmost, the exact range still holds the inserted text). It only starts where the AX write is tried first and can be verified; in paste-first apps (terminals, Chromium, Electron) the cleaned text is inserted once as usual. If the replace is refused the raw text stays (the clipboard is never touched) with the "kept original" note. Esc pressed in the instant between `correcting` and the raw insertion finishing (about 150 ms) cannot take the raw text back.
- **Styles:** the menu's Clean-up submenu lists the server's `correction_profiles` (from authenticated `/v1/health`; none for a server that lists none) with a checkmark on the default, and **Edit Styles…**, which opens Settings → Clean-up (picking Custom does too). The **Clean-up** tab has: the on/off checkbox, the default style, the **Prompts** editor, the "insert raw immediately" option, **Show changes after clean-up** and **Per-app styles**, a list of frontmost app → style with add (running apps or Choose App…), remove, Restore Defaults and **Test** (switch to an app, and after 3 s it says which style applies to it and whether an edited prompt is used). Defaults: Slack, Messages, Discord, WhatsApp → chat; Mail, Outlook, Superhuman → email; Terminal, iTerm, Ghostty, VS Code, Cursor, Xcode, Zed → code; Notes, Obsidian, Notion → notes. The frontmost app's bundle id picks the style when dictation starts (an app rule beats the default style; a style the server does not list, or Custom with no prompt, becomes `default`). Everything is stored in UserDefaults. Prompts and text are never logged. The style is shown as a chip on the HUD.
- **Keep clean-up model loaded** (Settings → Clean-up, a switch under the clean-up checkbox): a server that runs its own MLX model (`correction = managed`) loads it on first use and unloads it after a pause, so the first clean-up after a break is slow. The switch keeps it in memory instead, with the cost spelled out: "Clean-up starts instantly instead of loading after a pause. Uses 2.6 GB of memory on this Mac." ("about 2.6 GB" while the figure is an estimate; the host's name replaces "this Mac" for a remote server). A status line says **Loaded · 2.6 GB**, **Loading…** or **Not loaded**. It speaks the server's `GET`/`PUT /v1/correction/settings` (`{"keep_loaded": bool}`; the answer carries `loaded`, `loading`, `model`, `memory_mb`, `memory_estimated` and `mode`; 1 GB = 1024 MB). It is fetched when the tab opens and again after each change, and while the model loads the tab asks every 2 s. The switch moves at once; if the server refuses or cannot be reached it goes back and the reason shows under it in red. It is disabled with one line of reason when the server has clean-up off ("The server has clean-up turned off."), sends text to a remote model (409 `unsupported`: "Not needed: this server sends text to a remote model."), is older than the setting (404: "Update the Chirp server to use this.") or cannot be reached. The choice lives on the server (`server-state.json`), not in the app's preferences.
- **Editable style prompts:** each style (Default, Chat, Email, Code, Notes, Custom) shows its name, description, a "May restructure your text" note where it applies, and its prompt, loaded from `GET /v1/correction/profiles` (`prompt` is only the editable style part; the server's safety wrapper is fixed and not shown). Edits are saved per style; an edited style shows **Edited** and **Reset to default**, and a live count enforces the server's `max_prompt_chars` (4000). Typing the default text or nothing is not an edit. `start` carries `correction_profile` and `correction_prompt` only for a style the user edited, so server defaults and updates apply to the rest (Custom also sends the same text, cut to 2000 characters, as `correction_instructions` for servers that predate prompts). The old Custom instructions value is migrated once into the Custom prompt. The last list fetched is cached; when the server is unreachable the cached prompts show read-only with a note (edits already made still apply), and without a cache the editor says prompts load from the server. Help text: "Chirp always adds safety rules: it never answers or runs what you say, and only returns your cleaned words."
- **After clean-up:** by default the cleaned text is inserted as soon as it arrives and the HUD fades out within 150 ms (no diff hold, no lingering chip); a kept-original note stays at most 1 s. "Use raw" then lives outside the HUD for 5 s: a global ⌃⌥Z hotkey, registered only during that window (menu only if the dictation hotkey is ⌃⌥Z or another app owns it), a **Use Raw for Last Dictation** menu row, and a tiny green dot on the menu-bar bird. **Show changes after clean-up** (off by default) restores the diff highlight and the HUD's Use raw button.
- A red **DEBUG recordings kept** line (HUD, the menu's status line and a red dot on the menu-bar icon) shows whenever the server is running with debug retention.

## The menu-bar menu

Click the bird in the menu bar. The menu follows the system's own status menus (Tailscale's is the model): a header, single-line rows with the current value right-aligned in secondary grey and a chevron for submenus, almost no icons, no section headers.

```
Chirp                                   [switch]
Ready · ⌃⌥Space
─────────────
Start Dictation                          ⌃⌥Space
Use Raw for Last Dictation               ⌃⌥Z        only during the 5 s window after a cleaned insert
─────────────
Clean-up                              Default  ›
Microphone                          BOYA CM40  ›
Sounds                                  Chirp  ›
Server                              This Mac   ›
─────────────
Set Up Chirp…                                       only while setup is incomplete
Settings…                                     ⌘,
About Chirp
─────────────
Quit Chirp                                    ⌘Q
```

| Row | What it does |
|---|---|
| Header switch | Pauses and resumes Chirp. Off releases the dictation hotkey (and ⌃⌥Z), ends a dictation under way, disables Start Dictation and dims the menu-bar bird; on registers the hotkey again. Nothing else, including the shortcut recorder or a changed shortcut, brings the hotkey back while paused. The pause is not remembered: a relaunch resumes. |
| Status line | Under the name, in secondary grey: `Ready · ⌃⌥Space`, `Paused`, `Listening…` (also Connecting…, Polishing…), `Loading model…`, `Server unreachable` (red), the current error (red), or `DEBUG recordings kept` (red) while the server keeps recordings. |
| Start / Stop Dictation | The same toggle as tapping the hotkey (the combo is shown at the right; not while paused or when another app owns the shortcut). |
| Use Raw for Last Dictation | Appears for 5 s after a cleaned insertion, with ⌃⌥Z when that hotkey is free. |
| Clean-up | Value: the default style, or Off. Submenu: Clean up Text (checkmark), the styles (checkmark on the default), Show Changes after Clean-up, Edit Styles… A server with clean-up off shows "Unavailable" and one explanatory line. |
| Microphone | Value: the device in use. Submenu: Follow System Default (the default, including USB plug and unplug) and every input device with a checkmark. A picked device that is unplugged falls back to the default. The choice applies from the next dictation. |
| Sounds | Value: Off or the pack. Submenu: Off, Chirp, Soft, Glass, Click, System, Custom… |
| Server | Value: "This Mac" for a server on loopback, else its host. Submenu: the URL, Engine and Status lines (disabled) and Copy Doctor Command (puts the `chirp-server doctor` commands on the clipboard; run them in your checkout's `server/` directory). |
| Set Up Chirp… | The first-run window. Only while the Microphone or Accessibility permission is missing or the server is unreachable. |
| Settings…, About Chirp, Quit Chirp | Settings (⌘,), a window with the icon and version, and Quit (⌘Q). |

Values longer than 22 characters end in "…" (a long microphone name never stretches the menu); VoiceOver still reads the whole value. Hotkey and Launch at Login live only in Settings. The top-level rows are custom views (`MenuRowView`) so the value, shortcut and chevron share one set of measurements (24 pt rows, text 16 pt from the edge); the submenus are plain native items.

## Settings

Settings is a native preferences window with toolbar tabs (`NSTabViewController`), each sized to its content:

| Tab | Contents |
|---|---|
| General | Hotkey (presets and Record Shortcut…), Launch at login, Set Up Chirp… |
| Sounds | Cues on/off, pack with ▶ previews, volume, the Custom pack's start and stop files |
| Clean-up | Clean up dictated text, Keep clean-up model loaded, the default style, the per-style prompt editor, per-app styles with Test, Insert raw immediately, Show changes after clean-up, Offer Use raw for 5 seconds |
| Server | URL, token location, status, Copy Doctor Command |
| Permissions | Microphone and Accessibility status; a Fix button only for one that is missing |

The icon is the bird glyph. While you dictate its sound waves pulse (they stay steady when Reduce Motion is on), it is dimmed while the server is unreachable or Chirp is paused, it turns into a warning triangle on errors, and a small red dot sits at its corner while debug retention is on.

## How text is inserted

1. **Accessibility:** set the focused element's selected text, then poll the readback for up to ~150 ms to confirm the value or caret really changed.
2. **Paste:** save every pasteboard item, write the text marked `org.nspasteboard.TransientType` and `ConcealedType` (clipboard managers skip it), post ⌘V, and restore the clipboard after ~600 ms, only if nothing else wrote to it meanwhile (the change count is compared right before restoring, so a copy you make in that window is never overwritten).
3. **Copy only:** put the text on the clipboard and say so in the HUD.

Step 2 is only reached when the AX write was never attempted (no focused element, attribute not settable, field unreadable, or the call failed). **Chirp never pastes after an AX write was accepted.** If the readback does not confirm it in time (some apps apply the write late), the HUD says "Inserted? ⌘V if empty" and leaves the text on a transient pasteboard, so the text can never be inserted twice.

If secure input is on (a password field, `IsSecureEventInputEnabled()`), Chirp refuses to insert and shows "Secure field". Nothing is copied.

**Per-app overrides** (`InsertionPolicy.pasteFirstBundleIDs`) skip step 1 and go straight to paste:
- terminals: Terminal, iTerm2, Warp, Ghostty, kitty, Alacritty, Hyper, WezTerm
- Chromium browsers: Chrome (and Canary), Chromium, Brave, Edge, Arc, Vivaldi, Opera
- Electron apps: VS Code, Cursor, Slack, Discord, Notion, Teams, Obsidian

**Use raw** (offered for 5 s after a corrected insertion): secure input is checked first and refuses with no side effect. For AX insertions the exact inserted range is reselected (`AXSelectedTextRange`) and overwritten with the raw transcript, but only if the same app is still frontmost and the field still holds the inserted text there; otherwise the raw text is copied ("Copied raw — press ⌘V"). A pasted insertion can't be verified, so Chirp never posts a blind ⌘Z: it copies the raw text for a manual ⌘V. The raw transcript is kept only in the inserter's undo state, which is cleared when the 5 s expire, on Esc/cancel, on errors and when a new dictation starts.

## Configuration

- Server URL: Settings (default `http://127.0.0.1:7821`; over the tailnet, `https://<host>.ts.net/chirp`).
- Token: read from `~/.config/chirp/token` (created by `chirp-server`). The client stores nothing else on disk besides `UserDefaults` preferences (server URL, hotkey, clean-up, show raw, picked input device UID, clean-up style, custom instructions, per-app styles, insert-raw-first), and never logs audio or transcripts.

## Launch at login

Settings → General toggles a per-user LaunchAgent, `~/Library/LaunchAgents/dev.chirp.mac.plist`, that runs `/usr/bin/open -a <path to Chirp.app>` at login. (`SMAppService.mainApp` refuses a self-signed app in `~/Applications`, so it is not used to register.) The file is written when you tick the box and deleted when you untick it, and never otherwise; its presence is the state the checkbox shows. If the app moves, tick the box off and on again to rewrite the path. A failed write shows the error under the checkbox. Run from a bare `swift run` (no `.app`) the checkbox is disabled, since there is no app to launch.

## Accessibility

The HUD never takes focus, so status changes (Listening, Inserted, Copied, errors) are announced to VoiceOver with `NSAccessibility` announcements, and the partial text is exposed as an updating element. The waveform does not move when Reduce Motion is on.

## Self-test (no microphone)

Streams a WAV through the real protocol against a running server:

```sh
say -o /tmp/chirp.aiff "hello world, this is a test" && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/chirp.aiff /tmp/chirp.wav
build/Chirp.app/Contents/MacOS/ChirpMac --selftest /tmp/chirp.wav --expect hello
#   options: --url URL  --token-file PATH  --correction  --profile ID  --fast (don't pace in real time)  --expect WORD (repeatable)
```

It prints partials, the final text and timings (client-measured stop→final plus the server's), and exits 0 on success, 1 on a protocol or connection failure, 3 if an `--expect` word is missing. The transcript is printed to stdout only. The token comes from the token file, or `CHIRP_TOKEN`.

## Tests

`./scripts/test.sh` runs the `ChirpCore` tests (Swift Testing). Under the Command Line Tools SwiftPM doesn't find the Swift Testing macro plugin on its own, so the script passes `-Xswiftc -plugin-path` for it; with Xcode installed it is plain `swift test`. The tests cover: the protocol codec, the dictation state machine, hotkey dispatch and tap/hold timing, insertion strategy including a fake AX that applies late, pasteboard restore and Use raw (fakes), PCM conversion and framing, the silence guard, `StreamSession` against an in-process mock WebSocket server on loopback and against an injected transport that stalls (queue overflow, 120 s cap, ready deadline, prompt cancel), `AudioCapture` against a fake engine (failed start unwinds, retry, idempotent stop, device change), hotkey validation (⌥-only, ⌥⇧, ⌃Space, shift-only, Esc and reserved combinations are rejected with a reason; custom ids round-trip and invalid stored ids fall back), the shortcut recorder's rules, the first-run flow (steps, live satisfaction, `markDone` only on the last step), the sound cues, packs, timing, volume, custom-file import and the generated WAVs (format, peak, fades, pitch direction), the waveform level mapping and HUD sizing, the About text, the preferences (the picked input device persists, clean-up maps to the wire flag, per-app style mapping), the editable style prompts (profiles decoding, caching and offline read-only, edit/reset, per-style limits, which prompt is sent, migration of the old Custom instructions, the editor and the per-app Test summary), the 5 s Use raw window on a fake clock (⌃⌥Z registration, conflict fallback), the `correcting` message, the polishing state (timeout, Esc during polishing), the word diff and the replace-after-insert path (fakes), input-device resolution, the menu model for every state (paused, ready, listening, unreachable, debug, the Use raw window, setup incomplete), its value strings and their truncation, the pause gate (pausing unregisters the hotkey, resuming registers it, nothing else brings it back while paused), the status-icon rules, the menu's custom views, the five Settings tabs and their sizing, the HUD content, and the offscreen snapshot renderer with its committed-set checks.

## Word waveform overlay (optional)

Settings → General → "Word waveform overlay" (off by default) asks the server for word timings (`start.word_timings`) and draws the
live transcript word by word with the bars of each word's own audio directly above it: the mapping from sound to text is
spatial. The HUD keeps every 50 ms input level of the utterance (`UtteranceLevels`; frame `i` is the server's `i * 50 ms`,
so a word's `start…end` is a slice of them) and lays the words out in a wrapping flow (`WordWaveformView`): a pause widens the
gap and draws a dotted rest, a word being recognised is tinted and pulses, it settles to the solid colour once later partials
leave it alone, a revised word crossfades in place, and a long dictation keeps the newest words behind an ellipsis. While
clean-up runs the raw words stay with their audio under the shimmer; the cleaned text cannot be mapped word for word, so the
ribbon fades out when it lands (and on "Use raw"). Reduce Motion drops the pulse, springs and sweep; VoiceOver reads the
transcript as one element as before. Without timings (an old server, the ONNX engine) the HUD shows plain text, and with the
option off nothing changes. Design notes and the rejected variants are in [docs/review/word-waveform.md](../docs/review/word-waveform.md).

## UI snapshots (no app launch)

`ChirpMac --render-snapshots <dir>` draws the HUD in every state (plus Reduce Motion and Increase Contrast variants, and the clean-up flow listening → polishing → changes → inserted), the menu in each state and its submenus, every Settings tab, the Set Up and About windows to PNGs in light and dark appearance (about 150 files, 8 MB), then exits. It is handled before any `NSApplication`, onboarding or permission code and touches no microphone, Accessibility, pasteboard or TCC API; all inputs are synthetic. The tests render the same set into a temporary directory, with a 250 KB cap per PNG.

Only a curated set is committed in [docs/screenshots/mac](../docs/screenshots/mac): the key HUD states, the menu and its Clean-up submenu, one image per Settings tab and the Set Up welcome, each in light and dark (30 PNGs, about 1.8 MB). The list is `Snapshots.committedNames`; `ChirpMac --render-snapshots <dir> --curated` writes just those. `scripts/snapshots.sh` refreshes the committed folder (and deletes any other PNG there); `scripts/snapshots.sh all` renders everything into a new temporary directory and prints its path. A test fails when the folder drifts from the list or grows past 3 MB.

The menu snapshots are built from the same `MenuHeaderView` and `MenuRowView` the live menu uses, in a rounded panel that approximates the menu chrome (an `NSMenu` cannot be drawn offscreen); submenus are drawn like native items (checkmark column). A bird symbol stands in for the app icon in Set Up and About unless run from a checkout (`Assets/AppIcon.png`). The HUD PNGs draw a flat stand-in for the blur, since there is no window to blur through offscreen. Each Settings tab is an `NSGridView` (right-aligned labels, left-aligned controls, help text under each control, 20 pt margins) shown without the window's toolbar. The menu-bar icon animation, the red badge dot, the switch moving and the highlight of a hovered row need a real session, so they are covered by the pure rules in the tests, not by snapshots (the hover snapshot forces a row selected to show the colours).

## Layout

```
Sources/ChirpCore/    protocol, Preferences, StreamSession (URLSessionWebSocketTask), DictationMachine, HotKey (Carbon) and its validation, onboarding flow, sound cues and packs, audio helpers, input selection, Insertion/
Sources/ChirpUI/      HUD view and waveform, menu content, menu views and status-icon rules, settings tabs and form, shortcut recorder, setup and About views, snapshot renderer (no system access)
Sources/ChirpMac/     app: menu bar, HUD panel, settings, setup and About windows, capture, controller, --selftest
Tests/ChirpCoreTests/
scripts/              bundle.sh, make-cert.sh, install.sh, test.sh, make-sounds.swift (the sound packs), check-sounds.sh, Chirp.entitlements
```

## Known limits

- No third-party dependencies. The Command Line Tools have no SwiftUI macro plugins (`@State`, previews), so settings are plain AppKit (the HUD is SwiftUI without property-wrapper state) and the shortcut recorder is a plain `NSButton` with a local event monitor.
- Insertion cannot work in secure fields, and some apps ignore both AX writes and synthetic ⌘V.
- The HUD follows the mouse's screen, not the text caret.
- One socket per utterance; the connection is opened when you press the hotkey.
- "Use raw" after a paste only copies the raw text; it never undoes the paste.

## Icon and menu-bar glyphs

`Assets/AppIcon.png` is the 1024 px app-icon master. It shows a Koi-style songbird in koi colours on a lily pad under the moon, with ripples and music notes ("08 Pond moonlight"). The operator picked it from 13 options. It was generated with GPT Image 2.5 through the `ez-image-gen` skill, using Koi's mascot as the style reference. It is a full-bleed opaque square: macOS 26+ applies the rounded-rectangle mask itself and puts icons with their own transparent tile inside a grey frame. `bundle.sh` turns it into `AppIcon.icns` with `sips` and `iconutil`.

`Assets/MenuBarListening*.png` and `Assets/MenuBarIdle*.png` are 18 pt template glyphs (1x and 2x): the round koi-fin bird with sound waves ("13 Round fin-bird"). Idle is the listening glyph with the waves erased, so the icon never shifts when its state changes. The menu bar dims the idle glyph while the server is unreachable and shows a warning triangle on errors. The pulse while listening fades the waves, which the app derives at run time as the listening glyph minus the idle bird.
