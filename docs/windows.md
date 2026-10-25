# Chirp on Windows

Run the Chirp speech server on your own Windows 10 or 11 PC. Phones pair to it over Tailscale
exactly as they pair to a Mac, and the Chirp desktop app dictates into any Windows app. Design
and phases: issue #214.

**Status.** Windows support is new. The server and the desktop app build and pass their
automated tests on GitHub's `windows-latest` runners, including a real server transcribing a
synthetic clip, but the [acceptance checklist](#acceptance-checklist) below has not yet been run
on a real PC. Everything installs from source; nothing is code-signed yet.

## What runs where

| | Windows |
|---|---|
| Speech recognition | Parakeet TDT v2 on ONNX Runtime (`--engine onnx`), int8 on the CPU. CUDA and DirectML are opt-in ([accelerators](../server/README.md#parakeet-onnx-accelerators)) |
| Clean-up and notes | Optional. The managed MLX helper is Mac-only; point `[correction]` at a local OpenAI-compatible server such as LM Studio or Ollama ([server/README.md](../server/README.md#pointing-correction-at-lm-studio-operator-steps)) |
| Background service | A per-user Task Scheduler task, **Chirp Server**, started at logon; no administrator rights |
| Config | `%APPDATA%\Chirp` (`server.toml`, `token`, `devices.json`), owner-only access |
| Models, state, debug | `%LOCALAPPDATA%\Chirp` (never roams or syncs) |
| Desktop app | Chirp desktop (Tauri): tray icon, hold-to-talk key, live HUD, typed or pasted text, and a Notes library |
| Desktop notes | `%LOCALAPPDATA%\chirp-desktop\notes`, written only after an owner-only access list is verified |

## Install the server

You need [uv](https://docs.astral.sh/uv/getting-started/installation/) and Git. In PowerShell:

```powershell
git clone https://github.com/araa47/chirp.git
cd chirp\server
uv sync --locked --extra onnx
uv run chirp-server model fetch --engine onnx      # about 650 MB, pinned revision
```

Choose the ONNX engine in `%APPDATA%\Chirp\server.toml` so the service uses it too:

```toml
engine = "onnx"
```

Try it in the foreground first (Ctrl+C stops it), then check everything:

```powershell
uv run chirp-server
uv run chirp-server doctor
```

`doctor` reports the ONNX Runtime providers, the model, the token's access list, the port and
the service. The server listens on `127.0.0.1:7821` only; Windows Firewall needs no rule.

### Keep it running

```powershell
uv run chirp-server service install      # flags before "service" (--port, --root-path) are kept
uv run chirp-server service uninstall
```

This registers the **Chirp Server** task in Task Scheduler › Task Scheduler Library. It starts
`pythonw.exe` (no console window) at logon, only while you are logged on, restarts after a
failure and never stops on battery. Its output is discarded, like the Mac LaunchAgent's; run
the server in the foreground to see logs.

## Pair a phone

Install [Tailscale](https://tailscale.com/download/windows) on the PC and the phone, then
publish the server to your tailnet only (never Funnel):

```powershell
tailscale serve --bg --set-path /chirp http://127.0.0.1:7821
uv run chirp-server pair --name "My phone" --url https://<your-pc>.<tailnet>.ts.net/chirp
```

Scan the QR code with Chirp for Android or iPhone. The pairing link is a secret: don't paste it
into chat or logs. Revoke a phone with `uv run chirp-server devices revoke "My phone"`.

## Install the desktop app

Download `chirp-windows-x64-setup` from the latest `desktop-windows` workflow run, or build it:

```powershell
cd chirp\desktop
npm ci
npm run build -- --bundles nsis          # needs Rust (rustup) and the MSVC build tools
```

The installer is per-user and unsigned, so SmartScreen shows **Windows protected your PC**:
choose **More info › Run anyway**. Open Chirp from the tray, pair it to
`http://127.0.0.1:7821` (or a pairing link), and dictate:

- **Hold to talk.** The default key is **Right Alt**. On keyboard layouts where Right Alt is
  **AltGr** (German, French, Polish and many others), the default is **Right Ctrl** instead, so
  AltGr keeps typing `@`, `€` and friends. Setup says which key it chose; change it in Settings.
  Pressing any other key while holding it cancels; key combinations never start dictation.
- **Text** is typed with `SendInput`. Long dictations are pasted instead, and your clipboard
  text is restored; Chirp's clipboard writes are excluded from clipboard history and cloud
  clipboard.
- **Apps running as administrator** can't receive typed input from a normal app (Windows UIPI).
  Chirp leaves the text on the clipboard and says so; press Ctrl+V.

## Acceptance checklist

Run these on a real Windows 11 PC (and Windows 10 if you have one) and record the results in
#214. Use a fresh Windows user account if you can.

1. **Server install.** Follow [Install the server](#install-the-server). `doctor` shows no FAIL;
   the token check says owner-only access. `icacls %APPDATA%\Chirp\token` lists only you and
   SYSTEM.
2. **Service.** `service install`, then sign out and back in. Task Scheduler shows **Chirp
   Server** running; `doctor` says the service is running; no console window appeared. End the
   `pythonw.exe` process in Task Manager and confirm it restarts within about a minute.
   `service uninstall` removes the task.
3. **Phone.** Publish with `tailscale serve`, pair Android (and iPhone if available) from the QR
   code, dictate a sentence on the phone, and check it arrives within about a second.
4. **Desktop, typing.** Install the NSIS build (note the SmartScreen steps), pair it, then hold
   the key and dictate into **Notepad**, **Word** and a **browser** text field (for example a
   GitHub comment box). Include an accented word and an emoji-producing phrase, and a dictation
   long enough (over 2000 characters) to be pasted; check your clipboard text afterwards is what
   it was before.
5. **Desktop, keys.** On a US layout the default key is Right Alt and releasing it never opens
   Notepad's or Word's menu bar. Switch to German (or French) layout, reset Settings, and check
   the default becomes Right Ctrl and AltGr+Q still types `@`. Holding Shift+key or Ctrl+C never
   starts dictation; pressing a letter while holding the key cancels.
6. **Elevated app.** Run Notepad as administrator, dictate into it, and check Chirp says the
   text is on the clipboard and Ctrl+V pastes it.
7. **Live Notes.** Open **Notes** from the tray, create a note and **Record** about two minutes
   of speech (segments save every 45 seconds). With **Structure new segments** on and clean-up
   configured, check headings and to-dos appear; without it, the plain transcript is appended.
   Quit and reopen the app and check the note is in the library and searchable. Check
   `icacls %LOCALAPPDATA%\chirp-desktop\notes` lists only you and SYSTEM.
8. **Privacy.** With dictation and notes done, check `%LOCALAPPDATA%\Chirp\debug` does not exist
   (debug retention is off by default) and that clipboard history (Win+V) holds no dictation.
9. **Uninstall.** Uninstall the desktop app from Settings › Apps, run `service uninstall`, and
   delete `%APPDATA%\Chirp`, `%LOCALAPPDATA%\Chirp` and `%LOCALAPPDATA%\chirp-desktop` if you
   want your data gone.

## Troubleshooting

| Symptom | Check |
|---|---|
| `doctor` FAILs **onnx** | `uv sync --locked --extra onnx`, then `uv run chirp-server model fetch --engine onnx` |
| Service installed but not running | `uv run chirp-server` in the foreground shows the startup error; then `uv run chirp-server setup restart` |
| Nothing is typed | The target app may run as administrator (see above); or another tool holds a keyboard hook. Try Notepad first |
| Right Alt opens a menu | Choose Right Ctrl in Settings and report your layout in #214 |
| Phone can't connect | `tailscale serve status` shows `/chirp` proxying to `http://127.0.0.1:7821` |
