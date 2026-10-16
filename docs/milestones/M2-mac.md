# M2: macOS dictation client (`chirp/mac`)

Goal: `mac/` is a small native Swift menu-bar app, **Chirp.app**. From any app, a hotkey streams mic audio to the local `chirp-server` (`ws://127.0.0.1:7821/v1/stream`), shows live partial text in a floating HUD, and inserts the final text into the focused field. It falls back to paste, then to copy. The interaction mirrors Koi's dictation ([architecture §6](../architecture.md)).

## Constraints

- **No full Xcode** on this Mac: only Command Line Tools with Swift 6.4. Use SwiftPM (`swift build -c release`). An `.app` bundle is assembled by script.
- Do not install Xcode. If something truly needs it, say so in your report.
- **The Mac mini has no built-in mic.** Use the system default input (currently a USB BOYA CM40). Show the device name and follow device changes.
- Target: macOS 15+; this Mac runs macOS 27. Swift 6 strict concurrency.

## Scope

1. **Package:** `mac/Package.swift`, with executable target `ChirpMac` and library `ChirpCore` (testable logic: protocol client, state machine, insertion strategy selection).
   - Dependencies: only maintained, permissively licensed ones. Candidates: `sindresorhus/KeyboardShortcuts` (global hotkey with key-down/up via Carbon, so no Input Monitoring) and `sindresorhus/LaunchAtLogin-Modern`.
   - Use `URLSessionWebSocketTask` for the WebSocket; no extra dependency.
2. **Audio:** `AVAudioEngine` input tap, converted to 16 kHz mono PCM16 with `AVAudioConverter`, sent as 40–60 ms binary frames.
   - Start latency matters: prepare the engine lazily but keep it ready after first use. Stop the input when idle, so the mic indicator is off when not dictating.
   - Silence guard: if peak/RMS stays at zero for 1.5 s, show "No microphone signal".
3. **Hotkey and state machine:**
   - Default hotkey ⌥Space; it can be changed in the menu or settings.
   - A press under 300 ms toggles; a longer press is push-to-talk until release. Esc during dictation cancels, so the WS gets `cancel` and nothing is inserted.
   - States: idle → connecting → listening → finalizing → inserting → idle, plus an error state. Unit-test the state machine.
4. **HUD:**
   - A non-activating `NSPanel` (never steals focus) near the top centre of the active screen.
   - It shows a level meter, the live partial text (stable part normal, unstable part dimmed), and a status line ("Listening", "Finalizing", "Inserted", "Copied — press ⌘V").
   - When the server reports debug retention, a persistent red **DEBUG: recordings kept** badge. When a correction was applied, a 5 s "Use raw" action.
   - Use SwiftUI hosted in AppKit if that is simpler.
5. **Insertion** (`ChirpCore/Insertion`):
   1. AX: get the focused element through `AXUIElementCreateSystemWide`, set `kAXSelectedTextAttribute`, and verify the value/selection changed.
   2. Paste: snapshot all pasteboard items, write the text with the `org.nspasteboard.TransientType` and `org.nspasteboard.ConcealedType` markers, post ⌘V via `CGEvent`, restore the pasteboard after about 250 ms, and only if the change count is still ours.
   3. Copy-only, with a HUD hint.
   - If `IsSecureEventInputEnabled()` is true, refuse to insert and show "Secure field".
   - Keep a small per-app override list (e.g. terminals → paste) and document it.
6. **Permissions:**
   - First run walks through the Microphone permission (`AVCaptureDevice.requestAccess`) and Accessibility (`AXIsProcessTrustedWithOptions` prompt, plus a deep link to System Settings).
   - The menu shows the status of each permission.
7. **Menu bar:** status, server health (engine, debug-retention flag), input device, correction toggle (off by default; shows "sends text to <host>" when the server says it leaves the machine), hotkey, launch at login, quit.
8. **Config and token:** the server URL defaults to `http://127.0.0.1:7821`. The token is read from `~/.config/chirp/token`. There is no other persistent state beyond `UserDefaults` preferences. Never log transcripts.
9. **Bundle and sign** (`mac/scripts/`):
   - `make-cert.sh` creates a local self-signed code-signing identity, "Chirp Local Dev", in the login keychain, with operator-runnable steps.
   - `bundle.sh` runs `swift build -c release`, assembles `build/Chirp.app` (Info.plist with `LSUIElement`, `NSMicrophoneUsageDescription`, bundle id `dev.chirp.mac`) and runs `codesign --force --options runtime --sign "Chirp Local Dev"`. If the identity is missing it falls back to ad-hoc signing with a warning that TCC grants will reset on each rebuild.
   - `install.sh` copies the app to `~/Applications/Chirp.app`.
10. **Self-test:** `Chirp.app/Contents/MacOS/ChirpMac --selftest <wav>` streams a WAV file through the real protocol, without the mic, and prints partials, the final and timings. Use it to verify against a running server; M1 is being built in parallel, so it may need to talk to a stub. The `ChirpCore` tests run against a tiny in-process mock WS server, or test protocol coding separately.

## Acceptance

- `cd mac && swift build && swift test` passes. `./scripts/bundle.sh` produces a signed `build/Chirp.app`.
- `--selftest` against a running `chirp-server` prints a correct final.
- `mac/README.md` covers build, install, the permission grant steps, the hotkey, insertion behaviour and known limits.
- Report which steps need the operator's hands: granting Accessibility and Microphone, and creating the certificate if keychain access prompts.
