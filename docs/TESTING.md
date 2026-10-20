# Testing Chirp

## 1. Automated checks (no mic, phone, permissions or network)

Run from the repo root:

```sh
(cd server && uv sync --locked && uv run ruff check . && uv run pytest -q && uv run pytest -q -m model)
(cd mac && ./scripts/test.sh)
(source ~/.local/share/chirp-android/env.sh && cd android && ./gradlew lint testDebugUnitTest assembleDebug)
./scripts/e2e-local.sh
```

`scripts/e2e-local.sh` starts a real `chirp-server` on 127.0.0.1:7899 with a throwaway HOME, so it uses its own token. It then streams a synthetic `say` sentence through three clients:

- the server's own simulator
- the Mac app's `--selftest`
- the Android IME transport, run on the JVM

It then checks that a wrong token is refused, that the server log contains no transcript, and that no unexpected files were written. It prints the work directory and leaves it for you to delete.

Latency figures from these runs are observations on a shared, loaded host, not targets. Measured engine numbers are in [bench.md](bench.md).

## 2. Operator steps

Each step needs the operator's hands or approval. Do them in order.

### Mac server

1. **Start the server** (foreground): `cd server && uv sync --locked && uv run chirp-server --root-path /chirp`.
   - It binds to 127.0.0.1:7821 only.
   - It reuses the cached model at `~/.koi/voice-models/parakeet-mlx`.
   - On first run it creates `~/.config/chirp/token` (mode 0600).
   - Optional, keeps the model warm across reboots: `uv run chirp-server service install`. Remove it with `uv run chirp-server service uninstall`.
2. **Publish on the tailnet only.** This adds one path to the existing Serve config alongside `/koi`, and it is never Funnel.
   ```sh
   tailscale serve --bg --set-path /chirp http://127.0.0.1:7821
   tailscale serve status        # shows https://mainframe.tail676ff2.ts.net/chirp (tailnet only)
   ```
   Roll back with `tailscale serve --set-path /chirp off`.
   - Every route except the minimal health check, and the WebSocket, require the bearer token.

### Mac app

3. **Create the signing certificate** once: `cd mac && ./scripts/make-cert.sh`. It may ask for your login password or for keychain *Always Allow*.
4. **Build and install:** `./scripts/bundle.sh && ./scripts/install.sh && open ~/Applications/Chirp.app`.
5. **Grant permissions.** On first launch the app asks for **Microphone** and **Accessibility**; grant both in System Settings → Privacy & Security. Input Monitoring is not needed.
6. **Dictate:**
   - Focus any text field, press ⌃⌥Space, speak, then press ⌃⌥Space again. Holding ⌃⌥Space is push-to-talk; Esc cancels.
   - Check that live text appears in the HUD and the final text lands in the field.
   - Try TextEdit, Safari, Slack or VS Code (these paste), and Terminal.

### Mac Live Notes

Run on the reference Mac after installing the build with `./scripts/install-mac.sh` and selecting the default correction model.

1. Press ⌃⌥N and talk for about 3 minutes through a mock meeting with a decision, two to-dos and a "we will **not** …" sentence. Check the headings, the `☐` tasks, the Decision line, and that the negation is kept.
2. Leave it running for at least 10 minutes with intermittent silence. Check that the menu-bar bird pulses throughout, that segments keep landing in the transcript (each ≤ 45 s, none lost at a cut), filler words (um, uh, like, yeah) are gone from the transcript when clean-up is on, and that frozen sections do not change.
3. Press the dictation hotkey while Notes records → the "Notes is recording — stop it to dictate" toast and no dictation. Stop Notes, then dictate normally.
4. Stop, Save… to the Desktop, and open the `.md` file (notes, `---`, then the `## Transcript` appendix). Record a little more, then quit Chirp with the unsaved notes → the Save… / Discard / Cancel alert appears.
5. Touch a marker file, run a session without saving, then `find ~/Library -newer <marker> -path '*Chirp*'` and look in `~/Library/Saved Application State`: no notes content on disk. Check `log show --predicate 'subsystem == "dev.chirp.mac"' --last 15m` and the server log: no spoken words.
6. Set the server's correction mode to off and restart it → Notes shows the transcript-only explanation and Copy/Save export the transcript.
7. Hotkey registration without pressing keys: `log show --predicate 'subsystem == "dev.chirp.mac"' --info --last 5m | grep "hotkey register id=4"` shows `combo=control-option-n status=0` after launch.

### Fold 8

7. **Enable wireless debugging and pair adb:** `adb pair IP:PAIRPORT`, then `adb connect IP:PORT`. See `android/README.md`.
8. **Install the app:**
   - Build and install: `cd android && ./scripts/make-keystore.sh && ./gradlew assembleRelease && adb install -r app/build/outputs/apk/release/app-release.apk`.
   - Or install the debug APK.
9. **Set up on the phone:** open **Chirp Voice**, grant the microphone, and enable the keyboard (Settings → General management → Keyboard list and default). Keep Samsung Keyboard on.
10. **Pair:**
    - On the Mac, run `cd server && uv run chirp-server pair --url https://mainframe.tail676ff2.ts.net/chirp`. It prints a secret link and a terminal QR code.
    - Tap **Scan pairing QR** in Chirp Setup. Google Play services owns the scanner UI and camera access; Chirp needs no camera permission. The Fold 8 has Play services; the scanner module may download on first use. Scanning fills the masked pairing field after validating the link. Paste remains available if scanning is unavailable or cancelled. The real scanner still needs device acceptance.
    - Never put the link in chat, shell history or screenshots.
    - Tap **Test connection & save pairing**.
11. **Dictate:**
    - In Samsung Notes or a browser field, switch to Chirp with the keyboard icon and tap the mic.
    - Live text appears underlined in the field, and the final text replaces it.
    - Check these cases from `android/README.md`: hold-to-talk, ✕ cancel, fold/unfold mid-utterance, hiding the keyboard, Wi-Fi vs LTE, and auto-return on/off.
12. **Battery:** run `android/scripts/battery-session.sh`, which resets batterystats, runs a scripted session and dumps the results. Record the result in `docs/bench.md`.

## 3. Privacy checks

- **Default:** `curl -s -H "Authorization: Bearer $(cat ~/.config/chirp/token)" http://127.0.0.1:7821/v1/health` shows `"debug_retention":false`. Nothing is written under `~/Library/Application Support/Chirp/debug/`.
- **Debug mode:**
  1. Start with `uv run chirp-server --debug-retain`.
  2. Both clients must show the red **DEBUG** badge or banner, and the debug folder fills.
  3. Run `uv run chirp-server debug purge` to clear it, then restart without the flag.
- **Correction:** off by default. If enabled with a non-loopback endpoint, both clients label it "sends text to HOST". Only final text is sent, never audio.
