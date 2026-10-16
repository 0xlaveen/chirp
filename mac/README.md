# Chirp for Mac

`Chirp.app` is a small menu-bar app. Press a hotkey in any app, talk, and the text appears in the focused field. Audio streams to your local `chirp-server` (`ws://127.0.0.1:7821/v1/stream`), and a floating HUD shows the live partial text while you speak. See [docs/architecture.md](../docs/architecture.md) for the protocol and privacy rules.

Native Swift 6, SwiftPM, AppKit. No Xcode needed: the Command Line Tools are enough.

## Build

```sh
cd mac
swift build            # debug build
swift test             # unit tests (see "Tests" below)
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

On first launch Settings opens and asks for both permissions. Grant them in **System Settings → Privacy & Security**:

| Permission | Why | Without it |
|---|---|---|
| Microphone | capture your voice | dictation refuses to start and opens the Microphone pane |
| Accessibility | set text in the focused field and send ⌘V | text is only copied to the clipboard ("Copied — press ⌘V") |

The hotkey is a Carbon hot key, so **Input Monitoring is not needed**. The menu shows the status of both permissions. After granting Accessibility you may need to relaunch the app.

The Mac mini has no built-in microphone. Chirp follows the system default input (shown in the menu), including when you plug in or unplug a USB mic.

## Using it

- **Hotkey:** ⌥Space by default; change it in Settings. A press shorter than 300 ms toggles (tap to start, tap to stop). A longer press is push-to-talk: hold, speak, release.
- **Esc** cancels: the server discards the audio and nothing is inserted. Esc is only captured while a dictation is active.
- The **HUD** appears at the top centre of the screen under the mouse and never takes focus. Stable text is shown normally and the still-changing tail dimmed. Status: Connecting, Listening, Finalizing, Inserted, Copied — press ⌘V.
- **Silence guard:** if the input is digitally silent for 1.5 s you get "No microphone signal" and the session is cancelled.
- **Correction** (menu toggle, off by default) asks the server to clean up the final text. When it changed the text, the HUD offers **Use raw** for 5 s. If the server reports that correction sends text off the machine, the toggle says so ("sends text to <host>"). Audio never leaves the Mac.
- A red **DEBUG: recordings kept** badge (HUD, menu and a red dot in the menu bar) shows whenever the server is running with debug retention.

## How text is inserted

1. **Accessibility:** set the focused element's selected text, then check that its value or caret really changed.
2. **Paste:** save every pasteboard item, write the text marked `org.nspasteboard.TransientType` and `ConcealedType` (clipboard managers skip it), post ⌘V, and restore the clipboard after about 250 ms, only if nothing else wrote to it meanwhile.
3. **Copy only:** put the text on the clipboard and say so in the HUD.

If secure input is on (a password field, `IsSecureEventInputEnabled()`), Chirp refuses to insert and shows "Secure field". Nothing is copied.

**Per-app overrides** (`InsertionPolicy.pasteFirstBundleIDs`): terminals (Terminal, iTerm2, Warp, Ghostty, kitty, Alacritty, Hyper, WezTerm) and Electron apps whose AX writes succeed silently (VS Code, Cursor, Slack, Discord, Notion) skip step 1 and go straight to paste.

**Use raw** is best effort: it posts ⌘Z to undo the insertion, then inserts the raw transcript. Apps that don't undo the insertion as one step will end up with both texts.

## Configuration

- Server URL: Settings (default `http://127.0.0.1:7821`; over the tailnet, `https://<host>.ts.net/chirp`).
- Token: read from `~/.config/chirp/token` (created by `chirp-server`). The client stores nothing else on disk besides `UserDefaults` preferences, and never logs audio or transcripts.

## Self-test (no microphone)

Streams a WAV through the real protocol against a running server:

```sh
say -o /tmp/chirp.aiff "hello world, this is a test" && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/chirp.aiff /tmp/chirp.wav
build/Chirp.app/Contents/MacOS/ChirpMac --selftest /tmp/chirp.wav --expect hello
#   options: --url URL  --token-file PATH  --correction  --fast (don't pace in real time)  --expect WORD (repeatable)
```

It prints partials, the final text and timings (client-measured stop→final plus the server's), and exits 0 on success, 1 on a protocol or connection failure, 3 if an `--expect` word is missing. The transcript is printed to stdout only. The token comes from the token file, or `CHIRP_TOKEN`.

## Tests

`swift test` runs the `ChirpCore` tests: the protocol codec, the dictation state machine, insertion strategy and pasteboard restore (fakes), PCM conversion and framing, the silence guard, and `StreamSession` against an in-process mock WebSocket server on loopback.

## Layout

```
Sources/ChirpCore/    protocol, StreamSession (URLSessionWebSocketTask), DictationMachine, audio helpers, Insertion/
Sources/ChirpMac/     app: menu bar, HUD (SwiftUI in an NSPanel), settings (AppKit), capture, controller, --selftest
Tests/ChirpCoreTests/
Vendor/KeyboardShortcuts/   MIT, patched to build without SwiftUI macro plugins (see README-CHIRP.md there)
scripts/              bundle.sh, make-cert.sh, install.sh, Chirp.entitlements
```

## Known limits

- The Command Line Tools have no SwiftUI macro plugins (`@State`, previews), so settings are plain AppKit and KeyboardShortcuts is vendored with its SwiftUI wrapper removed.
- Insertion cannot work in secure fields, and some apps ignore both AX writes and synthetic ⌘V.
- The HUD follows the mouse's screen, not the text caret.
- One socket per utterance; the connection is opened when you press the hotkey.
- "Use raw" depends on the target app's undo.
