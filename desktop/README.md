# Chirp desktop

The shared Tauri 2 client for Linux and Windows. The native Mac app remains in
[`mac/`](../mac/). This first phase supplies dictation, native microphone capture,
streaming partials/finals, the Pond HUD, settings, pairing and a tray. Live Notes
and its library follow in a separate phase; Windows integration is coordinated
in its own platform PR. Track the Linux work in [#213](https://github.com/araa47/chirp/issues/213).

## Linux

Install Rust stable, Node 22+, and the [Tauri Linux prerequisites](https://v2.tauri.app/start/prerequisites/).
On Debian/Ubuntu:

```sh
sudo apt install build-essential curl pkg-config libwebkit2gtk-4.1-dev libxdo-dev \
  libssl-dev libayatana-appindicator3-dev librsvg2-dev libasound2-dev xdotool xclip
cd desktop
npm ci
npm run dev
```

A Secret Service implementation (GNOME Keyring or KWallet) stores the server token.
Unlock it before pairing. Chirp never falls back to saving credentials in the
preferences file. Paste the `chirp://pair` link printed by your server's
`chirp-server pair` command into Connection & shortcuts, then Save settings.

On X11, hold the suggested **Right Alt** key alone to talk and release to insert.
An AltGr layout uses **Right Ctrl** instead. Change the key or select tap to toggle
in settings. Chords cancel dictation. The selected key stays available to other
applications; Chirp observes its state without grabbing the keyboard. Focus a
text field before dictating. The Record button hides the main window to return
focus to your previous app; the HUD does not request focus.

Text insertion uses `xdotool` on X11. If insertion fails, `xclip` puts the result
on the clipboard and the HUD asks you to paste it. Text is pipe input, never a
shell command. Clipboard fallback replaces the clipboard and leaves the result
there for you to paste.

**Wayland currently supports the Record button, not global shortcuts.** Portal
shortcut integration is a subsequent Linux phase. The planned portal shortcut
uses a compositor-approved chord unless single-key holds are supported. Chirp
does not read `/dev/input` or require membership in the input group. Install
`wtype` for compositors supporting the virtual-keyboard protocol; otherwise
install `wl-clipboard` and paste the result yourself. Xwayland alone does not
grant global access to native Wayland applications.

The server must accept `start.client = "desktop"` (this PR adds it). Dictations
are limited to 120 seconds. Disconnects, mic failures and an overloaded audio
queue fail visibly rather than inserting incomplete audio. A failed insertion
keeps the transcript in the HUD. Escape in a focused Chirp window cancels.

## Build and test

```sh
npm run check
npm test
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo clippy --locked --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path src-tauri/Cargo.toml
npm run build -- --bundles deb
```

On a macOS host with Docker, use an actual Linux arm64 environment:

```sh
docker build -t chirp-linux-desktop:dev -f desktop/scripts/Dockerfile.linux desktop
docker run --rm -v "$PWD:/workspace" -v chirp-linux-target:/cargo-target \
  chirp-linux-desktop:dev sh -c 'npm ci && npm run check && npm test && cargo test --manifest-path src-tauri/Cargo.toml && npm run build -- --no-bundle'
```

No display is needed for core tests or builds. X11 insertion checks use Xvfb;
Wayland checks need a headless compositor with virtual-keyboard support. The
container has Xvfb, Weston, wtype and clipboard helpers installed. No test uses
the live server, port 7821, a real microphone, phone, or emulator.

## Shared platform contract

`src-tauri/src/platform/mod.rs` owns `Platform`, `Capabilities`,
`InsertionOutcome`, and the RAII `HotkeyHandle`. Native observers send
`hotkey::KeyEvent` to a shared hold/toggle/chord state machine. Emit a chord event
when any other key goes down during a hold, so the current dictation is cancelled.
The observer must never log keys or typed text. The default key is detected at
first launch and persisted only when settings are saved. The shared Tauri HUD
owns overlay behavior; native modules own insertion and keyboard observation.

`protocol.rs` speaks the existing authenticated v1 WebSocket protocol. Native
CPAL capture mixes input channels to mono, resamples continuously to 16 kHz,
and sends PCM16LE in 50 ms frames through a bounded queue. Cancellation closes
the session and suppresses insertion, including while waiting for a final.
Preferences contain no token; keyring uses native Windows Credential Manager,
Apple Keychain (development only), and Linux Secret Service. Spoken text is
memory-only and is never logged. The only committed image assets are copies of
the approved Pond artwork and glyph, plus the existing generated app icon.
