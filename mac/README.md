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

On first launch the **Set Up Chirp** window opens (reopen it any time from the menu's "Set Up Chirp…"). Its steps are Welcome, Microphone, Accessibility, the speech server and Try it; each permission or server step shows live status (it turns green as soon as you grant access in System Settings) and a **Fix** button. Skipping a step is allowed: Chirp then works with what it has (without Accessibility it copies instead of typing). The Try it step has a text field and turns green when it hears your hotkey. The "set up" flag is stored only when you finish the last step; closing the window early shows it again next launch. Permissions are granted in **System Settings → Privacy & Security**:

| Permission | Why | Without it |
|---|---|---|
| Microphone | capture your voice | dictation refuses to start and opens the Microphone pane |
| Accessibility | set text in the focused field and send ⌘V | text is only copied to the clipboard ("Copied — press ⌘V") |

The hotkey is a Carbon hot key (`RegisterEventHotKey`, delivering press and release), so **Input Monitoring is not needed**. The menu shows the status of both permissions. After granting Accessibility you may need to relaunch the app.

The Mac mini has no built-in microphone. Chirp follows the system default input (shown in the menu), including when you plug in or unplug a USB mic, unless you pick a device in the menu's Input Device submenu.

## Using it

- **Hotkey:** ⌃⌥Space by default; pick ⌃⇧Space or ⌃⌥⌘Space in the menu or Settings, or press **Record Shortcut…** in Settings and type your own. The recorder (AppKit, no macros, no Input Monitoring) refuses combinations that cannot fire and says why, and keeps listening: ⌥ or ⌥⇧ with no ⌃/⌘ (since macOS 15 they register but never fire), ⌃Space alone (Raycast's default and the input-source switcher), ⇧ alone or no modifier, Esc, and a few system shortcuts (⌘Space, ⌘Tab, ⌘Q). Esc, or a click elsewhere, gives up. While it listens the live hotkey is released so pressing it does not start a dictation. A stored custom shortcut is validated again on load. A press shorter than 300 ms toggles (tap to start, tap to stop). A longer press is push-to-talk: hold, speak, release.
- **Esc** cancels: the server discards the audio and nothing is inserted. Esc is only captured while a dictation is active.
- The **HUD** is a floating capsule at the bottom centre of the screen under the mouse, just above the Dock, and never takes focus (a non-activating panel). Its background is a real `NSVisualEffectView` (HUD material), so it follows light and dark. A live waveform from the input level sits at the left, then a short status: Connecting…, Listening, Finishing…, Inserting…, Inserted, Copied — ⌘V (a symbol replaces the waveform once there is an outcome). Stable text is shown normally and the still-changing tail dimmed; the capsule grows with the text up to a maximum width, then wraps (four lines at most) and animates its size. It fades and scales in and out; **Reduce Motion** drops the scale and the animation (steady bars instead of a moving waveform) and **Increase Contrast** switches to an opaque surface with a stronger border and a less dimmed tail.
- **Sounds** (menu and Settings, off by default): the stock `Tink` when dictation starts and `Pop` when capture ends, at low volume. The start cue finishes before the microphone opens so it is never recorded.
- **Silence guard:** if the input is digitally silent for 1.5 s you get "No microphone signal" and the session is cancelled.
- **Clean-up** (menu toggle, off by default) asks the server to clean up the final text; it is the protocol's `correction` flag. When the server rewrote the text, the HUD says Inserted with a small **cleaned** badge and offers **Use raw** for 5 s. "Show raw after clean-up" (on by default) hides the Use raw button when you turn it off; the badge stays. The toggle's subtitle comes from `/v1/health`: "Runs on this Mac", "Sends text to <host>" when health says it leaves the machine, or "Not set up on the server" (the toggle is then disabled). Audio never leaves the Mac.
- A red **DEBUG: recordings kept** badge (HUD, menu and a red dot on the menu-bar icon) shows whenever the server is running with debug retention.

## The menu-bar menu

Click the bird in the menu bar:

| Section | What it does |
|---|---|
| Header | Chirp, the hotkey hint and a status line with a coloured dot: Ready, Loading model…, Listening, Server unreachable, or the current error. A red "DEBUG retention ON" line appears while the server keeps recordings. |
| Start / Stop dictation | The same toggle as tapping the hotkey (the combo is shown at the right). |
| Input Device | Every input device, check-marked. "System Default" (the default) follows the system input, including USB plug and unplug. Pick one to pin it; if it is unplugged Chirp falls back to the default and the menu says so. The choice applies from the next dictation. |
| Hotkey | The presets. |
| Clean-up | Clean up text, and Show raw after clean-up (see above). |
| Server | The server URL with a green, orange or red dot and the engine name (click to open Settings). "Open doctor output" copies the `chirp-server doctor` commands to the clipboard; run them in your checkout's `server/` directory. |
| Permissions needed | Only shown while Microphone or Accessibility is missing, with an "Allow…" action each. |
| Footer | Launch at Login (a checkbox), Set Up Chirp… (the first-run window), Settings… (⌘,), About Chirp (a window with the icon and version) and Quit (⌘Q). |

The icon is the bird glyph. While you dictate its sound waves pulse (they stay steady when Reduce Motion is on), it is dimmed while the server is unreachable, it turns into a warning triangle on errors, and a small red dot sits at its corner while debug retention is on.

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
- Token: read from `~/.config/chirp/token` (created by `chirp-server`). The client stores nothing else on disk besides `UserDefaults` preferences (server URL, hotkey, clean-up, show raw, picked input device UID), and never logs audio or transcripts.

## Launch at login

The menu and Settings toggle a per-user LaunchAgent, `~/Library/LaunchAgents/dev.chirp.mac.plist`, that runs `/usr/bin/open -a <path to Chirp.app>` at login. (`SMAppService.mainApp` refuses a self-signed app in `~/Applications`, so it is not used to register.) The file is written when you tick the box and deleted when you untick it, and never otherwise; its presence is the state the checkbox shows. If the app moves, tick the box off and on again to rewrite the path. A failed write shows the error under the item. Run from a bare `swift run` (no `.app`) the item is disabled, since there is no app to launch.

## Accessibility

The HUD never takes focus, so status changes (Listening, Inserted, Copied, errors) are announced to VoiceOver with `NSAccessibility` announcements, and the partial text is exposed as an updating element. The waveform does not move when Reduce Motion is on.

## Self-test (no microphone)

Streams a WAV through the real protocol against a running server:

```sh
say -o /tmp/chirp.aiff "hello world, this is a test" && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/chirp.aiff /tmp/chirp.wav
build/Chirp.app/Contents/MacOS/ChirpMac --selftest /tmp/chirp.wav --expect hello
#   options: --url URL  --token-file PATH  --correction  --fast (don't pace in real time)  --expect WORD (repeatable)
```

It prints partials, the final text and timings (client-measured stop→final plus the server's), and exits 0 on success, 1 on a protocol or connection failure, 3 if an `--expect` word is missing. The transcript is printed to stdout only. The token comes from the token file, or `CHIRP_TOKEN`.

## Tests

`./scripts/test.sh` runs the `ChirpCore` tests (Swift Testing). Under the Command Line Tools SwiftPM doesn't find the Swift Testing macro plugin on its own, so the script passes `-Xswiftc -plugin-path` for it; with Xcode installed it is plain `swift test`. The tests cover: the protocol codec, the dictation state machine, hotkey dispatch and tap/hold timing, insertion strategy including a fake AX that applies late, pasteboard restore and Use raw (fakes), PCM conversion and framing, the silence guard, `StreamSession` against an in-process mock WebSocket server on loopback and against an injected transport that stalls (queue overflow, 120 s cap, ready deadline, prompt cancel), `AudioCapture` against a fake engine (failed start unwinds, retry, idempotent stop, device change), hotkey validation (⌥-only, ⌥⇧, ⌃Space, shift-only, Esc and reserved combinations are rejected with a reason; custom ids round-trip and invalid stored ids fall back), the shortcut recorder's rules, the first-run flow (steps, live satisfaction, `markDone` only on the last step), the sound cues, the waveform level mapping and HUD sizing, the About text, the preferences (the picked input device persists, clean-up maps to the wire flag), input-device resolution, the menu model for every state (status line, dictation toggle, device picker, clean-up, server, permissions), the status-icon rules, the HUD/settings content, and the offscreen snapshot renderer.

## UI snapshots (no app launch)

`ChirpMac --render-snapshots <dir>` draws the HUD in every state (plus Reduce Motion and Increase Contrast variants), the Settings window, the Set Up and About windows and the menu-bar menu content to PNGs in light and dark appearance, then exits. It is handled before any `NSApplication`, onboarding or permission code and touches no microphone, Accessibility, pasteboard or TCC API; all inputs are synthetic. `swift build && .build/debug/ChirpMac --render-snapshots /tmp/chirp-ui`. The tests render the same set. A selection is committed in [docs/screenshots/mac](../docs/screenshots/mac). Settings is an `NSGridView`: right-aligned labels, left-aligned controls, General / Server / Permissions sections, help text under each control, 20 pt margins and a window fitted to its content. The menu PNGs show the menu's content laid out like a menu (SF Symbols, subtitles, section headers, key hints), not the native `NSMenu` chrome, and a bird symbol stands in for the app icon (the Set Up and About snapshots use `Assets/AppIcon.png` when run from a checkout). The HUD PNGs draw a flat stand-in for the blur, since there is no window to blur through offscreen. The header block (icon, name, hotkey hint, status) is the real `MenuHeaderView`, a custom menu-item view, because AppKit greys out every disabled item whatever its attributed colours. The menu-bar icon animation, the red badge dot and the input-device switch need a real session, so they are covered by the pure rules in the tests, not by snapshots.

## Layout

```
Sources/ChirpCore/    protocol, Preferences, StreamSession (URLSessionWebSocketTask), DictationMachine, HotKey (Carbon) and its validation, onboarding flow, sound cues, audio helpers, input selection, Insertion/
Sources/ChirpUI/      HUD view and waveform, menu content and status-icon rules, settings form, shortcut recorder, setup and About views, snapshot renderer (no system access)
Sources/ChirpMac/     app: menu bar, HUD panel, settings, setup and About windows, capture, controller, --selftest
Tests/ChirpCoreTests/
scripts/              bundle.sh, make-cert.sh, install.sh, test.sh, Chirp.entitlements
```

## Known limits

- No third-party dependencies. The Command Line Tools have no SwiftUI macro plugins (`@State`, previews), so settings are plain AppKit (the HUD is SwiftUI without property-wrapper state) and the shortcut recorder is a plain `NSButton` with a local event monitor.
- Insertion cannot work in secure fields, and some apps ignore both AX writes and synthetic ⌘V.
- The HUD follows the mouse's screen, not the text caret.
- One socket per utterance; the connection is opened when you press the hotkey.
- "Use raw" after a paste only copies the raw text; it never undoes the paste.

## Icon and menu-bar glyphs

`Assets/AppIcon.png` is the 1024 px app-icon master: a songbird mid-chirp with golden sound waves on an indigo-to-violet tile. It was generated with GPT Image 2.5 through the `ez-image-gen` skill, then scaled onto Apple's icon grid. `bundle.sh` turns it into `AppIcon.icns` with `sips` and `iconutil`.

`Assets/MenuBarListening*.png` and `Assets/MenuBarIdle*.png` are 18 pt template glyphs (1x and 2x) of the same bird. Idle is the listening glyph with the waves erased, so the icon never shifts when its state changes. The menu bar dims the idle glyph while the server is unreachable and shows a warning triangle on errors. The pulse while listening fades the waves, which the app derives at run time as the listening glyph minus the idle bird.
