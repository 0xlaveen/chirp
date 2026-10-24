# Testing Chirp

## 1. Automated checks (no mic, phone, permissions or network)

Run from the repo root:

```sh
(cd server && uv sync --locked && uv run ruff check . && uv run pytest -q && uv run pytest -q -m model)
(cd mac && ./scripts/test.sh)
(source ~/.local/share/chirp-android/env.sh && cd android && ./gradlew lint testDebugUnitTest assembleDebug)
./scripts/e2e-local.sh
python3 site/build.py   # website: links, anchors, no external requests, no host names/tokens/paths
```

`scripts/e2e-local.sh` starts a real `chirp-server` on 127.0.0.1:7899 with a throwaway HOME, so it uses its own token. It then streams a synthetic `say` sentence through three clients:

- the server's own simulator
- the Mac app's `--selftest`
- the Android IME transport, run on the JVM

It then checks that a wrong token is refused, that the server log contains no transcript, and that no unexpected files were written. It prints the work directory and leaves it for you to delete.

For iPhone/iPad, `ios/scripts/simulator-e2e.sh SIMULATOR-UUID` does the same with the iOS app on a simulator: throwaway server on 127.0.0.1:7899, a local clean-up stand-in, the full UI scheme including the live-server suite and the real Chirp Keyboard. It then checks that the server log contains no transcript. See [ios/README.md](../ios/README.md#develop-and-test).

Live Notes has two more checks of its own:

- **The harness tests** (`NotesSessionTests`, `NotesFaultTests` and `NotesSoakTests` in `mac/scripts/test.sh`) run whole sessions through the real `NotesSession`, `StreamSession` and editor against scripted sockets and a scripted notes endpoint, on a fake clock. They cover the fault matrix (socket drops, outages, structure errors, Organize races, sleep/wake, crash recovery) and a 2-hour soak with budgets (see [bench.md](bench.md#live-notes-session-soak-66)). Rows that describe behaviour not built yet are disabled tests that name their issue.
- **`mac/scripts/notes-selftest.sh`** starts a throwaway `chirp-server` (temporary HOME, port 7899, never 7821 or the running app) and plays a 25 s `say` recording through `ChirpMac --notes-selftest`: once clean (it must hear "budget" and "Thursday") and once with `--fault drop@14`. It prints the segments, status changes, notes and transcript, and checks that the server log has no spoken words.

Latency figures from these runs are observations on a shared, loaded host, not targets. Measured engine numbers are in [bench.md](bench.md).

### CI

GitHub Actions (`.github/workflows/`) runs the automated checks on every pull request and on pushes to `main`. Each workflow is path-filtered, so a PR only runs the components it touches, and a newer push cancels the superseded run. No secrets, tailnet access or model downloads are involved.

| Workflow | Runner | Runs | Notes |
|---|---|---|---|
| `server.yml` | ubuntu | `uv sync --locked`, `ruff check`, `ruff format --check`, `pytest -q` | MLX packages are darwin-only, so Linux installs the portable set. `-m model` tests (real cached models) are deselected by `addopts`; run them on the Mac. |
| `android.yml` | ubuntu, JDK 21, Android SDK 37.2 | `./gradlew lint testDebugUnitTest assembleDebug assembleRelease` | The release APK is unsigned (no keystore secret). Lint and test reports upload on failure. |
| `mac.yml` | macos | `mac/scripts/ci-test.sh` (wraps `test.sh`) | Only for `mac/**` changes (macOS minutes are expensive). Can also be started by hand (`workflow_dispatch`). |
| `ios.yml` | macos, newest installed Xcode | `ios/scripts/ci-test.sh`: `check-sources.sh`, `Shared/scripts/test.sh`, the keyboard policy package tests, then `ios/scripts/simulator.sh test` (build and unit tests of the app with its keyboard and widgets) on one iPhone simulator | Only for `ios/**`, the `mac` package sources the app links (`ChirpCore`, `ChirpSpeakers`, `Package.*`) and the workflow file. Ad-hoc simulator signing, no team or secrets. Can also be started by hand. |

The hosted runners only have Xcode 26 (Swift 6.2/6.3). On them, six stream and recorder suites abort the shared test process (`freed pointer was not the last allocation`) although every test passes alone and on Swift 6.4, so `ci-test.sh` runs those one test per process, together with the Live Notes soak (`NotesSoakTests`; `test.sh` with no arguments also runs it after the rest, so its 2-minute limit covers the soak alone). It skips `GeneratedSoundTests` (needs `swift make-sounds.swift`) and `SnapshotTests` (the runner's fonts render PNGs over the committed-size cap). Both run in `mac/scripts/test.sh` on the Mac.

iOS CI runs the portable checks and the app's unit tests only. The UI schemes and the live-server end to end (`ios/scripts/simulator-e2e.sh`) stay on the Mac: they need `say`, ffmpeg, the cached model and a real keyboard setup, which the runners do not have, and headless simulator UI runs are not reliable enough to gate a PR. Run `ios/scripts/simulator.sh ui` or `simulator-e2e.sh` before merging UI changes.

`scripts/e2e-local.sh` and the operator steps below need a real Mac, `say` and (for the app) permissions, so they stay local.

### Android emulator sweep

On macOS with the Android toolchain and cached speech/clean-up models installed:

```sh
source ~/.local/share/chirp-android/env.sh
android/scripts/e2e-all.sh
# A focused retry still owns a fresh read-only emulator:
android/scripts/e2e-all.sh --only notes
```

The sweep queues on one host-wide emulator lease, selects its own free even port,
builds/installs debug, and uses a real throwaway server on 7899 with temporary
HOME and debug-only TLS. It prints a pass/fail table and a private evidence
folder. Never run parallel Chirp emulators across worktrees or use the server
on 7821. See the [Android E2E skill](../.claude/skills/chirp-android-e2e/SKILL.md)
for the script coverage table, targeted checks and recovery notes.

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
   tailscale serve status        # shows https://<your-mac>.<tailnet>.ts.net/chirp (tailnet only)
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

### Out-of-date server

Use a throwaway server on another port, never the real one on 7821 (the app's port is Settings → Server → URL).

1. Start an older server by hand on 7899 from a checkout before this change, point Settings → Server at `http://127.0.0.1:7899`, and open Live Notes. Settings → Server, the menu's status line and the Notes banner say "out of date" with the sentence about where it started; the button is **Use Chirp's managed server instead** (the process is not a LaunchAgent).
2. Stop it, start the current server by hand on 7899: no "Out of date" anywhere.
3. `scripts/install-mac.sh --server-only` with `CHIRP_PORT=7899` while a hand-started server holds 7899 prints the pid and command and the two commands to switch, and restarts nothing.
4. On the reference Mac, with Chirp's own LaunchAgent running an old checkout, **Restart server** brings it to the current code; Settings → Server shows the restart result.

### Mac Live Notes

Run on the reference Mac after installing the build with `./scripts/install-mac.sh` and selecting the default correction model.

1. Press ⌃⌥N and talk for about 3 minutes through a mock meeting with a decision, two to-dos and a "we will **not** …" sentence. Check the headings, the `☐` tasks, the Decision line, and that the negation is kept.
2. Leave it running for at least 10 minutes with intermittent silence. Check that the menu-bar bird pulses throughout, that segments keep landing in the transcript (each ≤ 45 s, none lost at a cut), filler words (um, uh, like, yeah) are gone from the transcript when clean-up is on, and that frozen sections do not change.
3. Press the dictation hotkey while Notes records → the "Notes is recording — stop it to dictate" toast and no dictation. Stop Notes, then dictate normally.
4. Stop, Save… to the Desktop, and open the `.md` file (notes, `---`, then the `## Transcript` appendix). Record a little more, then quit Chirp with the unsaved notes → the Save… / Discard / Cancel alert appears.
5. Touch a marker file, run a session without saving, then `find ~/Library -newer <marker> -path '*Chirp*'` and look in `~/Library/Saved Application State`: the only file is `Application Support/Chirp/Recovery/<id>.json` (`ls -l` shows `-rw-------`, the folder `drwx------`; it holds text, never audio) and nothing is in Saved Application State. Save… or Discard deletes it. With Settings → Notes → "Keep a recovery copy until notes are saved" off, nothing about the notes is on disk. Check `log show --predicate 'subsystem == "dev.chirp.mac"' --last 15m` and the server log: no spoken words.
6. Set the server's correction mode to off and restart it → Notes shows the explanation banner above the editor, the editor stays editable, and Copy/Save export your typed notes plus the transcript.
7. ⌃⌥N, then talk for about 5 minutes through a mock meeting that revisits "budget" twice, with two to-dos, a decision and a "we will **not** …" sentence. While it records, type your own bullet above the AI tail and fix a word inside the tail. Check: the caret never jumps; the tail you edited loses its tint; new AI notes appear after it.
8. Wait for an auto-reorganize (about 3 minutes, after 15 s without typing). Check: the budget sections merge; the to-dos and the negation survive; the **Organized · Show changes · Undo** chip appears, and **Undo** restores the previous text in one step.
9. Press Organize, then type immediately → "Notes changed while organizing — try again", and your typing is intact. With a "Not structured — see transcript" section in the notes (left alone), press Organize again → the status counts `Organizing notes… 1/2`, the section is replaced by structured notes, and one ⌘Z brings it back.
10. Toggle Preview → the same content, read-only. Click a `[ ]` in the editor → it toggles, and ⌘Z untoggles it.
11. Turn Auto-reorganize off → for 5 minutes no automatic reorganize, while the button still works. Turn "Structure notes" off → the editor stays editable and the Hearing strip still shows speech.
12. Stop, then Save… → the `.md` has your edits, the reorganized notes and the transcript appendix.
13. Privacy recheck as in step 5: no notes on disk except the recovery copy until Save or Discard, no text in `log show` (the journal logs `notes journal bytes=… ms=…` only) or the server log.
14. Crash recovery: record a minute, type a line, wait 3 s, then `kill -9` the Chirp process and relaunch it. The Notes window opens with "Recovered unsaved notes from … — Keep · Save… · Discard". Keep → the notes, typed line and transcript are back, the document is Stopped and unsaved, and Record continues the timestamps. Quit, relaunch, Discard → the banner goes and `Recovery/` is empty. Save… with **Keep saving changes to this file** checked, type, wait 3 s and check the `.md` has the change; rename the file, type again → the footer says "Stopped saving — file moved". Right-click in the editor → Writing Tools is absent or disabled.
15. Dock: open Notes (menu → Open Notes, or ⌃⌥⇧N) → Chirp appears in the Dock and ⌘-Tab, with a Window menu listing Chirp Notes. Close the window (nothing recorded, nothing unsaved) → the Dock icon goes and the menu-bar bird stays. Start ⌃⌥N, close the window → the Dock icon stays and a click brings it back; stop, close → gone. Move and resize the window, quit and relaunch → it reopens there. Dock menu: Open Notes, New Notes, Start/Stop Recording, and Pause Recording while it records. ⌘W closes the Notes and Settings windows. Settings → General → Always show Chirp in the Dock keeps the icon with no window.
16. Shortcuts: Settings → Shortcuts → Open Notes → Record Shortcut…, try ⌃⌥N and your dictation hotkey (both refused, with the reason), then ⌃⌥O; the new one works and the menu shows it. Reset restores ⌃⌥⇧N. Pressing it never starts recording. Record ⌃⌥M for Live Notes → ⌃⌥M starts and stops Notes from another app, the menu and the empty Notes window show ⌃⌥M, and ⌃⌥N does nothing; Reset brings ⌃⌥N back. Record ⌃⌥U for Use raw → after a cleaned dictation the menu row shows ⌃⌥U and it puts the raw words back.
17. Dictation hotkey in Notes: click into the Notes window and press the dictation hotkey → Notes records (no HUD); press again → it pauses, and once more → it resumes (Stop is the button, ⌘⇧R or the Live Notes shortcut). Switch to another app → the hotkey dictates. The header reads "<key> to record · <key> again to pause", then "<key> to resume".
18. Two-hour soak in real time (optional, before a release): start a throwaway server as `mac/scripts/notes-selftest.sh` does, build a 2-hour `say` playlist (for example `say -f talk.txt -o talk.aiff` over a long text, then `ffmpeg -ar 16000 -ac 1`), and run `ChirpMac --notes-selftest talk.wav --url http://127.0.0.1:7899 --token-file <throwaway>/.config/chirp/token` without `--fast`. It should end with `notes-selftest: OK`, `gaps=0` on stderr, and the process's memory in Activity Monitor flat after the first minutes. Add `--fault down@600-660` to watch a one-minute outage (today Notes stops after three failed segments; #62 keeps it recording).
19. Speaker fix-ups (Label speakers on, two people talking): click a **Person 2** chip → Rename "Person 2"…, type Maya, Return → every Person 2 chip says Maya, the banner offers "Also replace “Person 2” with “Maya” in the notes?"; Replace → only whole `Person 2` words change (a `Person 20` stays), and one ⌘Z in the editor puts them back. Merge Maya into Person 1 → her paragraphs relabel and the next thing she says is Person 1 too; the banner's Undo separates her again. Right-click one paragraph → This turn is ▸ New person → it becomes Person 3 and stays so after Stop. Save… → the transcript uses the names. VoiceOver on a chip reads "Speaker: Maya".
20. Saved voices: Settings › Notes › Recognize saved voices → the download prompt (8 MB), Download. In a two-person session, name Person 2 "Maya"; once she has spoken 20 s, her chip menu offers Remember This Voice as “Maya”…, whose Remember button stays disabled until the consent box is ticked. Keychain Access shows one "Chirp Voice Profile" item (not iCloud). New, record her again: a dotted "Maya?" appears beside her chip after about 10 s, and nothing is renamed until you click it. Not Maya hides it. Settings lists Maya with Forget…; turning the switch off asks whether to forget 1 saved voice. `log show … | grep "notes voices"` shows counts only.
7. Hotkey registration without pressing keys: `log show --predicate 'subsystem == "dev.chirp.mac"' --info --last 5m | grep "hotkey register id=4"` shows `combo=control-option-n status=0` after launch; `hotkey register id=5` shows `combo=control-option-shift-n status=0`.

### iPhone/iPad Live Notes (device)

The simulator gates (`ios/scripts/simulator.sh test` and `ios/scripts/simulator-e2e.sh` on an iPhone and an iPad simulator) run Live Notes with synthetic sockets and with a spoken file against a throwaway server. On your own device:

1. Pair, open Live Notes (iPad: the Notes tab; iPhone: **Live Notes** in the Dictate tab), Record and talk for a few minutes. Segments land in the transcript about every 45 s or at pauses, and structured bullets appear in the notes.
2. Lock the phone and keep talking for 5+ minutes. The lock screen and Dynamic Island show "Live Notes · recording" with a running timer and Pause/Stop, and no text. Pause and Resume from the lock screen, then unlock: the notes caught up with what was said while locked.
3. Take a call (or invoke Siri) while recording → "Paused · another app or a call took the microphone"; after the call it resumes. Unplug or connect a headset mid-recording → recording continues.
4. Turn Wi-Fi off for a minute while recording → "Mac offline · keeping …"; back on → the offline segments arrive.
5. Organize, then Undo Organize; Export → Save to Files… and open the `.md` in Files.
6. Record, then force-quit Chirp from the app switcher. Reopen → "Unsaved notes from an earlier session" with Keep/Discard. Keep restores the notes.
7. Settings → Battery: compare an hour locked with Battery saver on and off.

### Fold 8

7. **Enable wireless debugging and pair adb:** `adb pair IP:PAIRPORT`, then `adb connect IP:PORT`. See `android/README.md`.
8. **Install the app:**
   - Build and install: `cd android && ./scripts/make-keystore.sh && ./gradlew assembleRelease && adb install -r app/build/outputs/apk/release/app-arm64-v8a-release.apk`.
   - Or install the debug APK.
9. **Set up on the phone:** open **Chirp**, grant the microphone, and enable the keyboard (Settings → General management → Keyboard list and default). Keep Samsung Keyboard on.
10. **Pair:**
    - On the Mac, open Chirp → Settings → Devices → **Pair a Phone…** (it checks Tailscale Serve and shows the QR code), or run `cd server && uv run chirp-server pair --url https://<your-mac>.<tailnet>.ts.net/chirp`, which prints a secret link and a terminal QR code.
    - Tap **Scan code** on the Pair your Mac page. Google Play services owns the scanner UI and camera access; Chirp needs no camera permission. The Fold 8 has Play services; the scanner module may download on first use. A valid scan is tested and saved automatically. Paste remains available if scanning is unavailable or cancelled. The real scanner still needs device acceptance.
    - Never put the link in chat, shell history or screenshots.
    - Wait for **Connected · host**, then tap **Finish**; Home opens with the **Try it** card. Relaunching the app now opens Home, not onboarding.
    - App shell: a bar on the cover screen and a rail on the inner screen; Back from a tab returns to Home, then leaves. Turn Tailscale off → Home's card says **Tailscale is off** with **Turn on**; quit Chirp on the Mac → **Mac offline** with **Check again**. With history on, swipe an entry in History away and tap **Undo**: it comes back.
11. **Dictate:**
    - In Samsung Notes or a browser field, switch to Chirp with the keyboard icon and tap the mic.
    - Live text appears underlined in the field, and the final text replaces it.
    - Check these cases from `android/README.md`: hold-to-talk, ✕ cancel, fold/unfold mid-utterance, hiding the keyboard, and Wi-Fi vs LTE.
    - With a Bluetooth keyboard: Ctrl+Alt+Space starts and stops, Esc cancels; with TalkBack on, one "Inserted, N words" per final and nothing while listening.
12. **Notes** (long-press the launcher icon → **Notes**, or the Notes tab; both are one session):
    - Record a 5-minute mock meeting with a decision, two to-dos and a "we will **not** …" sentence. Check that notes appear under the AI tail after each segment, that the transcript has one line per segment (none longer than 45 s, nothing lost at a cut) and that the negation is kept.
    - While recording, type a line above the notes and fix a word inside them: the caret never jumps and new notes appear after your edit.
    - Turn the screen off for 2 minutes, then on: the **Chirp Notes is recording** notification stayed (no notes text in it), and the transcript kept growing. From the lock screen, **Pause** (mic indicator off, notification says paused), then **Resume**; **Stop** in the notification finishes the notes.
    - Battery saver: record, turn the screen off for 2 minutes while speaking, turn it on → the notes and transcript are current at once and the notification said **Battery saver** while off. Chirp settings → About → Diagnostics → **Notes sessions** shows a numbers-only line with many skipped updates. The full measurement is [android-device-acceptance.md §6](android-device-acceptance.md#6-notes-battery).
    - Notes keep themselves (**Keep notes on this phone** is on by default; Chirp settings → Privacy & history → Notes): Stop, then New without a prompt → the clock button lists the notes; open them, delete them (they go to Recently Deleted for 30 days). Turning the switch off keeps the notes; **Delete all notes** removes them. With **Keep audio with notes** on, record a minute: the total under Notes settings grows and **Delete kept audio** returns it to zero.
    - Add the **Notes** Quick Settings tile: a tap opens Notes and starts recording, the tile shows **Recording**/**Paused**, and a second tap stops it.
    - Record a minute and type a line, wait 3 s, then `adb shell am kill dev.chirp.android` (or swipe Chirp away) and reopen Notes → **Recovered unsaved notes from …**, the notes, line and transcript are back and stopped, and **Record** continues the timestamps. **Save** to Downloads → the `.md` opens with the notes and transcript; `adb shell run-as dev.chirp.android ls no_backup` (debug build) no longer lists `notes_recovery.bin`.
    - Fold and unfold: notes and transcript sit side by side on the inner screen and as tabs on the cover screen, with nothing lost.
    - Edit by voice: with Notes recording, hold **Hold to edit by voice**, say "remove the first bullet", let go. The transcript has none of those words, notes keep arriving after, and **Edited · Undo** appears; **Undo** restores the text. Try "add a summary" (refused with a reason), a tap (latches; the next tap sends), **Cancel**, a selection (only those lines change) and typing while "Editing notes…" shows (a conflict, your typing intact). With the screen off, use the notification's **Command**, then **Send**: the notes are already edited when the screen is on. Outside a recording the button opens the microphone for the command only. Check `adb logcat` and the server log: lengths and outcome codes, never the words.
    - Press **Organize**, then type at once → "Notes changed while organizing — try again", typing intact. Organize again, then **Undo organize** restores the text.
    - Stop the Mac server for 30 s mid-recording: failed segments show `⚠︎ audio not transcribed`, and three in a row stop the recording with the notes kept.
    - **Copy** and paste into a note app: title, notes, `---`, `## Transcript`. Back asks before discarding; afterwards `adb shell run-as dev.chirp.android ls -R files shared_prefs` holds no notes text.
13. **Battery:** run `android/scripts/battery-session.sh`, which resets batterystats, runs a scripted session and dumps the results. Record the result in `docs/bench.md`.
14. **Full acceptance pass:** follow [android-device-acceptance.md](android-device-acceptance.md) (battery, Perfetto, stop matrix, session timings from Diagnostics).

## 3. Privacy checks

- **Default:** `curl -s -H "Authorization: Bearer $(cat ~/.config/chirp/token)" http://127.0.0.1:7821/v1/health` shows `"debug_retention":false`. Nothing is written under `~/Library/Application Support/Chirp/debug/`.
- **Debug mode:**
  1. Start with `uv run chirp-server --debug-retain`.
  2. Both clients must show the red **DEBUG** badge or banner, and the debug folder fills.
  3. Run `uv run chirp-server debug purge` to clear it, then restart without the flag.
- **Correction:** off by default. If enabled with a non-loopback endpoint, both clients label it "sends text to HOST". Only final text is sent, never audio.
