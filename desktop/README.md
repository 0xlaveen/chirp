# Chirp desktop

The shared Tauri 2 client for Linux and Windows. The native Mac app remains in
[`mac/`](../mac/). This first phase supplies dictation, native microphone capture,
streaming partials/finals, the Pond HUD, settings, pairing and a tray. Live Notes
and its library follow in a separate phase. Track the Linux work in
[#213](https://github.com/araa47/chirp/issues/213) and Windows in
[#214](https://github.com/araa47/chirp/issues/214).

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

Text insertion uses `xdotool` on X11. Multiline results use `xclip` and the
focused application’s paste shortcut, because XTest typing can lose newlines.
Known terminals use Ctrl+Shift+V; other applications use Ctrl+V. If automatic
insertion fails, the result stays on the clipboard and the HUD asks you to paste it. Text is pipe input, never a
shell command. Clipboard fallback replaces the clipboard and leaves the result
there for you to paste.

**Wayland shortcuts use your desktop’s Global Shortcuts portal.** In settings,
check **Enable a global shortcut through my desktop**, then Save. Choose the
binding in the system dialog. Chirp suggests Ctrl+Alt+Space and shows the binding
your desktop approves. Single-key holds are available only when the portal allows
them; X11 supplies the full Right Alt/Right Ctrl experience. Hold and tap-to-toggle
modes both use the portal’s press/release events. Disabling the option closes the
session. Declining permission or an unavailable portal leaves Record usable.

Portal support depends on the installed desktop and portal backend. Chirp does
not read `/dev/input` or require membership in the input group. Install `wtype`
for compositors supporting the virtual-keyboard protocol; otherwise install
`wl-clipboard` and paste the result yourself. Xwayland alone does not grant global
access to native Wayland applications.

The server must accept `start.client = "desktop"` (this PR adds it). Dictations
are limited to 120 seconds. Disconnects, mic failures and an overloaded audio
queue fail visibly rather than inserting incomplete audio. A failed insertion
keeps the transcript in the HUD. Escape in a focused Chirp window cancels.

## Windows

`src-tauri/src/platform/windows.rs` implements the platform contract with Win32
(`windows-sys`); its rules live in `platform/windows_logic.rs`, which is plain
Rust and tested on every OS.

- **Hotkey.** A `WH_KEYBOARD_LL` hook on its own thread reports Right Alt or Right
  Ctrl and "another key is down" changes. It ignores injected input (including
  Chirp's own typing) and the synthetic Left Ctrl that Windows sends before AltGr,
  and re-checks missed releases with `GetAsyncKeyState`. A lone Right Alt gets a
  menu-mask key so releasing it doesn't open the focused app's menu bar. The hook
  never blocks or logs keys.
- **Default key.** The foreground keyboard layout is probed with `ToUnicodeEx`
  under Ctrl+Alt. If anything types (AltGr), the default is Right Ctrl, otherwise
  Right Alt.
- **Insertion.** `SendInput` with `KEYEVENTF_UNICODE` in batches that never split a
  surrogate pair; line breaks and tabs are Enter and Tab. Text over 2000 UTF-16
  units, or what remains when typing is refused, is pasted with Ctrl+V and the
  previous clipboard text restored. Chirp's clipboard writes are excluded from
  clipboard history, cloud clipboard and clipboard monitors. Windows blocks
  synthetic input to apps running as administrator (UIPI), so those get the text
  on the clipboard (`InsertionOutcome::Clipboard`).
- **Bundle.** `tauri.windows.conf.json` builds a per-user NSIS installer (no
  administrator rights). It is unsigned, so SmartScreen warns on first run.

Build on Windows with Rust (rustup, MSVC toolchain), Node 22+ and WebView2 (built
into Windows 11):

```powershell
npm ci
npm run build -- --bundles nsis
```

The native check types into a real Tk text field with SendInput, pastes a long text
and checks the clipboard is restored, checks the US and German default keys and
that the keyboard hook installs:

```powershell
cargo build --locked --manifest-path src-tauri/Cargo.toml --example platform-smoke
python scripts/windows-smoke.py
```

The hook ignores synthetic key presses by design, so holding the key itself,
typing into Notepad, Word and a browser, and elevated apps are on the manual
acceptance checklist in [#214](https://github.com/araa47/chirp/issues/214).

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
desktop/scripts/linux-container.sh sh -c 'npm ci && npm run check && npm test && cargo test --manifest-path src-tauri/Cargo.toml && npm run build -- --no-bundle'
```

The harness snapshots source under `/tmp` and copies it into Docker. On macOS,
a direct bind mount from Documents can hang in the Created state because of
privacy permissions. Keep container fixtures and build snapshots outside protected
folders; a Docker process that never starts is not a compiler failure. The harness uses `docker cp` to avoid host bind mounts entirely. It retains the
snapshot and stopped container for evidence and copies the generated Cargo lockfile back.

No display is needed for core tests or builds. Run the native X11 checks with:

```sh
cargo build --locked --manifest-path src-tauri/Cargo.toml --example platform-smoke
xvfb-run -a env CHIRP_PLATFORM_SMOKE=src-tauri/target/debug/examples/platform-smoke python3 scripts/x11-smoke.py
```

The X11 smoke uses a real GTK text field and physical XTest events, and checks Unicode,
multiline paste, US/German layout defaults and hold/chord cancellation. Linux
arm64 Docker validation has passed these checks, nine Rust tests, Clippy, the
frontend tests and a release application build.

Wayland checks use a real GTK field under headless Sway, with Unicode/multiline
wtype insertion and the wl-copy fallback. Portal tests use a private D-Bus session
to check approved/declined bindings, session/action scoping, release and cleanup,
and a missing-service case. They do not change your desktop’s shortcuts. Actual
portal dialog appearance and availability depend on the compositor.

```sh
cargo build --locked --manifest-path src-tauri/Cargo.toml --example portal-smoke
dbus-run-session -- env CHIRP_PORTAL_SMOKE=src-tauri/target/debug/examples/portal-smoke python3 scripts/portal-smoke.py
dbus-run-session -- src-tauri/target/debug/examples/portal-smoke --unavailable
CHIRP_PLATFORM_SMOKE=src-tauri/target/debug/examples/platform-smoke scripts/wayland-insertion-smoke.sh
```

Install `python3-dbus`, `sway`, `wtype` and `wl-clipboard` for these checks. The
container includes these along with Xvfb and Weston. No test uses
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
