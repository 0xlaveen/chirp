# Live Notes: UX research and fail-proofing plan

October 2026. This note compares Chirp's Mac **Live Notes** (⌃⌥N, see [mac/README.md](../../mac/README.md#live-notes)) with comparable tools, lists its friction and failure modes from a code audit, and records the plan that the follow-up issues implement. The last section says what an Android client should take over from the Mac design.

Chirp already does two things better than every tool below, and the plan keeps both:

- **Everything is local.** Speech, clean-up, structuring and diarization run on the user's own machines.
- **The output is real Markdown.** It is one editable document with headings, bullets, `- [ ]` tasks and Decision/Question lines, and the AI only ever rewrites its own tinted tail.

## 1. What comparable tools do

Sources are vendor help centres and changelogs, checked in October 2026. Otter's help pages refused automated fetches, so its rows rest on search summaries.

| Tool | What it does that we don't (yet) |
|---|---|
| [Granola](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes) | The user's typed notes are the main surface, and the transcript is a hidden panel. Typed lines and AI lines look different. Each enhanced line has a jump back to its source in the transcript. Stop/Resume works on the same note, even after the meeting has ended. Capture stops automatically after 15 minutes with no audio. When transcription fails there is an explicit orange banner, ["We're having trouble transcribing"](https://docs.granola.ai/help-center/troubleshooting/transcription-issues). A floating indicator shows that capture is live while you are in other apps. |
| [Superwhisper](https://superwhisper.com/docs/modes/meeting) (Meetings, v3.0) | Local diarization and summaries. Past meetings are grouped by day in their own tab. [History](https://superwhisper.com/docs/get-started/interface-history) is searchable, with retention you can set from 1 day to Forever. Mode switching with ⌘-number, and a mini window that remembers its position. |
| [Wispr Flow](https://wisprflow.ai/whats-new) | A "no sound from your mic" warning as soon as the mic is silent. A heads-up one minute before the 20-minute session limit. **Audio is saved automatically, so a failed transcript shows "Retry" and an app quit offers "Recover".** "Undo AI edit" on history items. Push-to-talk, a second press to stop, Esc to cancel. |
| Typeless | Hold-to-talk or hands-free, spoken self-corrections and per-app tone. Reports say a dropped connection ends dictation, which is a weakness we should not copy. |
| [Otter](https://help.otter.ai/hc/en-us/articles/21665587209367-Speaker-Identification-Overview) | "Speaker 1, 2…" that you name per bubble or for all of that speaker's bubbles, with the names remembered. Highlights and comments added while recording. Exports to TXT, DOCX, PDF and SRT. |
| [Apple Notes / Voice Memos](https://support.apple.com/guide/voice-memos/view-a-transcription-of-a-recording-vm4a03609f0d/mac) | On-device transcription. Pause/Resume and "add to recording". Clicking a transcript line plays from that moment, the current word is highlighted, and search covers titles plus transcripts. |
| [Notion AI Meeting Notes](https://www.notion.com/help/ai-meeting-notes) | Summary bullets carry citations to transcript moments. Stop and Resume on the same block. Summary templates. A 10-hour daily cap, and the recorder keeps the last 10 recordings locally. |

Patterns worth adopting, in priority order:

1. **Never lose a session.** Wispr saves audio and offers Recover/Retry, and Granola caches audio until it is transcribed. Chirp keeps everything in memory, so a crash, force-quit, kernel panic or forced restart loses the whole session.
2. **Degrade, don't stop.** Granola shows a banner and keeps going. Chirp stops Notes after three failed segments in a row, and the audio of each failed segment is lost ("⚠︎ audio not transcribed").
3. **Loud, specific status.** This means a no-signal warning rather than a stop, a "server offline, catching up" state, and a reminder before a long session's budget runs out.
4. **Provenance and review of AI edits.** Granola's jump to source and Notion's citations link a note back to the transcript. Wispr's "Undo AI edit" stays available. Chirp's Organize undo chip lasts 20 s.
5. **Pause and resume on the same note.** Chirp has Record after Stop, but no Pause.
6. **History and search across sessions.** Superwhisper and Voice Memos have it. It should be opt-in and local for us.
7. **Keyboard-first window.** Chirp has ⌃⌥N, ⌘B/⌘I and ⌥⌘R. It has no shortcuts for Record/Stop inside the window, for switching tabs, or for Copy Markdown.

## 2. Audit of Chirp's Live Notes

The logic is in good shape. `NotesRecorder` injects every system edge (sockets, structuring, time), and about 150 unit tests cover the scheduler, the tail rules, IME, conflicts, split-on-reject and Organize. The gaps are almost all at the **edges of a session**, where the app meets the outside world.

| # | Failure mode | Where | What happens today |
|---|---|---|---|
| F1 | App crash, force-quit, panic, power loss, or a forced macOS update restart | Notes are memory-only by design (README "Privacy") | **The whole session is lost**: notes, typing and transcript. Quit asks Save/Discard, but only a graceful quit gets that far. |
| F2 | Server down or restarting, Wi-Fi/Tailscale blip, a socket dropped mid-segment | `NotesRecorder.segmentFailed` | That segment's audio is gone and the transcript shows a gap. After `maxSegmentFailures = 3` in a row, Notes stops. A 30 s server restart in a meeting ends the session. |
| F3 | Mic unplugged, AirPods leave, or the input device changes and the rebuild fails | `AudioCapture.rebuild` → `NotesController.openMicrophone` `onFailure` | Notes stops ("The microphone stopped — check the input device"). It does not fall back to the built-in mic. |
| F4 | Hardware mute button, or an input that delivers digital zeros | `NotesCaptureSink` uses `SilenceGuard()` (1.5 s at peak 0) | Notes **stops** with "No microphone signal" after 1.5 s. That rule suits dictation, but in a meeting it is a trap. |
| F5 | Lid closed or system sleep while recording | No sleep/wake observer anywhere in `Sources/` | Untested. The sockets die, and on wake the segments probably fail into gaps and may hit the three-failure stop. |
| F6 | Long continuous speech (a lecture, a monologue) | `NotesSegmenter.maxSegment = 45` forces a cut mid-speech | A word can be split across two sockets. Each segment is cleaned up with no context from the previous one. The transcript shows 45-second rows that break mid-sentence. |
| F7 | Multi-hour sessions | `NotesDocument.maxReorganizeChars = 3500`, `recordingReorganizeChars = 1200`; the diarizer timeline grows forever | Only the trailing ~3500 characters can ever be organized, so the start of a 2-hour document is never merged with the end. Memory and per-update cost over hours are **not measured**: the editor restyle test stops at 10 000 characters, and `SpeakerTimeline.spans` and `transcriptRows` are recomputed over the whole session. |
| F8 | Organize undo | The `Organized · Undo` chip lasts 20 s | After the chip is gone, the only way back is the Undo stack, which is lost on New and per document. There is no "show what Organize changed". |
| F9 | Speaker names | `NotesDocument.renameSpeaker` exists but has no caller in the UI | People stay "Person 1, 2…". This is already tracked in #18 (rename, merge). |
| F10 | Docs drift | mac/README.md said "at most 90 s" | The segmenter cuts at 45 s (bench-tuned). This PR fixes the README. |

Already handled well, so no work is planned:

- Typing never races AI updates. Appends are held while the caret is in the tail, while IME is composing, and for up to 10 s after the last keystroke.
- Reorganize is version-checked and discarded on conflict.
- A rejected window is retried in halves.
- A busy server (503) retries instead of failing hard.
- The first socket failing is reported as "Server unreachable at host".

## 3. Fail-proof testing plan

What exists: `ChirpCore` unit tests with a fake `StreamSession` transport, an in-process mock WebSocket server for `StreamSession`, a fake capture engine for `AudioCapture`, and `ChirpMac --render-snapshots` for UI states. The server has `test_notes.py` and `test_notes_reorganize.py`.

What is missing:

- **`NotesController` is untested.** It lives in `ChirpMac` and creates `AudioCapture`, `SystemCaptureEngine` and `SilenceGuard` directly. To test it, move the session glue into `ChirpCore` (or inject `AudioCapture`, the health source and the clock) so a fake engine can drive it.
- **A deterministic end-to-end harness.** It would combine the recorder, the real `StreamSession` against a scripted in-process WebSocket server, a scripted structure/reorganize HTTP fake and a synthetic audio source on a fake clock. Each test replays a script along these lines: at 0 s send ready, at 12.4 s send the final, at 30 s drop the socket, at 31 s answer structure with `rejected`. It then asserts on the document, the transcript, the status strings and the undo stack. Synthetic audio can be generated tones and silence (the segmenter only reads RMS) or `say`-generated WAVs for the self-test.
- **A fault matrix** covering:
  - a socket drop mid-segment, before ready, and during finalize
  - a structure timeout, `rejected` and `busy`
  - reorganize while typing, while composing, and after New
  - server down for 10 s, 60 s and 10 min
  - the mic device lost, then a different device appearing
  - hardware mute
  - sleep and wake
  - quit during Finishing
- **A soak and budget test.** Run a 2-hour session on a fake clock: about 160 segments at 45 s, roughly 100 000 transcript characters, speakers on. Assert a ceiling on resident memory growth and per-update time for `restyle`, `transcriptRows`, `apply` and `SpeakerTimeline` lookups. Run a real-time version manually with the bench scripts.
- **Crash and recovery tests.** Write a journal, `kill -9` the app (or simulate: drop the controller without `stopForQuit`), relaunch, and assert that the recovered document equals the last journaled state. Recovery is impossible today, so this lands with #61.
- **A `--notes-selftest <wav>`** mode beside `--selftest`. It runs a WAV through the real pipeline against a throwaway server (temporary `HOME`, port 7899), so CI and agents can check Notes without a microphone or the user's running Chirp.
- **Snapshots** for every new state (offline/catching up, recovered session, mic muted, long-session reminder), committed only where the curated set calls for it.

## 4. Issues

| Issue | Scope | Main files |
|---|---|---|
| #61 Crash-safe sessions | Local recovery journal, Recover on launch, keep a saved file up to date | new `ChirpCore/NotesJournal.swift`, `NotesDocument` (Codable), `NotesController`, `AppDelegate`, `NotesWindowController` |
| #62 Keep recording through faults | Buffer audio and retry segments while the server is offline, mic fallback, mute as a warning, sleep/wake | `NotesRecorder`, `NotesController`, `AudioCapture`, `NotesModel` status |
| #64 Long dictation | Seamless cut boundaries, cross-segment context, paragraph transcript, whole-document Organize in steps, budgets, long-run UX | `NotesSegmenter`, `NotesRecorder`, `NotesDocument`, `NotesView`, `server/notes.py` (optional context) |
| #65 Review and control | Pause/Resume, review what Organize changed with a lasting restore, jump from a note to the transcript, in-window shortcuts | `NotesView`, `NotesModel`, `NotesEditor`, `NotesRecorder` (pause) |
| #66 Test hardening | The harness, fault matrix, soak, `--notes-selftest` and snapshots above | `Tests/ChirpCoreTests/*`, new `NotesHarness`, `SelfTest.swift`, `NotesController` extraction |

Overlap: #61, #62 and #64 all touch `NotesRecorder` and `NotesController`. #66's controller extraction makes the other three easier to test. The suggested order is #66 (harness and extraction) first, then #61, then #62 and #64 in either order, rebasing on each other, and #65 last. #65 mostly touches `ChirpUI`. Speaker rename and merge stay in #18. The menu bar and Settings reorganization (#58) is separate. If #61 adds a Settings switch for the recovery journal, it goes wherever #58 puts the Notes settings.

## 5. What Android Live Notes (#57) should carry over

Server, unchanged and stateless:

- Segments use the ordinary `/v1/stream` with `correction_profile: "live_notes"` (health `notes_correction`). That style's guard only deletes fillers and repeats.
- Structuring is `POST /v1/notes/structure` with `{transcript, outline, final}`, 1–6000 characters, body at most 64 KiB. Reorganize is `POST /v1/notes/reorganize`. Both are specified in [docs/architecture.md](../architecture.md#live-notes-structuring-v1-compatible-addition).
- Feature detection uses health fields: `notes_structure`, `notes_reorganize`, `notes_correction`, `correction`, `correction_leaves_machine`.
- The server runs **one notes generation at a time server-wide** and answers 503 `busy` rather than queueing. A phone and a Mac sharing a server will see `busy`, which should mean "retry after the next segment", never an error.

Segmenting (`NotesSegmenter`, `NotesFrameRouter`):

- Cut no earlier than 12 s, then at 0.6 s of quiet (RMS < 0.015), relaxing to 0.3 s after 30 s, and always at **45 s**. #57 says ≤90 s, but 45 s was chosen because clean-up of a ~700-character segment takes about 2 s and passes the guard far more often ([docs/bench.md](../bench.md)).
- **Rolling sockets.** Open the next socket, swap capture to it atomically under a lock, then finalize the old one with a 25 s deadline. Number the segments at the swap and commit finals in order, even when a later final arrives first.
- If #64 changes the cut (lookback or overlap), Android should take the new rule. Android #40 ("rolling utterances past 120 s") is the same mechanism, so share the logic.

Structuring and reorganize client rules (`NotesDocument`, `NotesRecorder`):

- There is one pass slot, shared by append and reorganize. Passes are at most every 15 s, and **never while a segment is still finalizing or being cleaned up**, because clean-up needs the model first.
- The window is the unstructured transcript: freeze at 1600 characters, hard cap 3600, plus the outline of settled headings (≤24 items, ≤1500 characters).
- On `rejected`, split at a sentence end into halves, then quarters (never under 400 characters). Only a part that still fails becomes an editable "Not structured — see transcript" block. A timeout or `busy` keeps the normal retry.
- Reorganize scope is the trailing whole sections within 3500 characters (1200 while recording). Auto-reorganize runs after 1200 new characters, 3 minutes and 15 s without typing, and only right after a commit. **Apply only if the document version is unchanged**, otherwise drop the result (a manual run says so; an automatic one retries after 60 s).

Editing model (the part most worth copying exactly):

- The notes are one plain Markdown string. The AI owns only a **tail** after the user's text. Editing anything in the tail claims it for the user, and later AI text starts a new tail.
- AI updates are held while the caret is in the tail and the user typed in the last 10 s, and while IME is composing. On Android, `InputConnection` composing regions count as composing.
- Each AI update is one undo step, and undoing it hands that text to the user.
- Turn off anything that could rewrite or send the text: autocorrect suggestions and cloud spell-check are the Android equivalents of Writing Tools and smart quotes.
- Privacy: memory-only by default, logs carry counts and timings and never text, and export goes through Copy/Share. If Mac recovery (#61) ships, mirror it with an app-private journal (`noBackupFilesDir`), deleted on Save/Discard.

Fail-proof lessons that apply on Android from day one: buffer audio for failed segments instead of leaving gaps (#62), don't stop on a hardware mute or a short outage, and keep a recovery journal. Android also loses the process routinely when the foreground service is killed, so recovery matters even more there than on the Mac.
