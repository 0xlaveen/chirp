# Independent review, round 2

Reviewed base: `87782330588319ddce4fed9291b0d111584cf591` on `chirp/review-r2`.
Scope: server Python, Mac Swift, Android Kotlin, and the frozen protocol in
`docs/architecture.md` §3. No production code changed. Findings below distinguish
fake-based reproductions from code-path inspection; no real microphone, AX/TCC,
phone, pairing credential, external service, or model inference was used.

## Confirmed findings, ranked by severity

### R2-01 — P1: Cancel during finalization still sends text to correction and retains it

**Locations:** `server/src/chirp_server/app.py:387`, `:168`, `:171`, `:179`;
client cancellation is allowed in `mac/Sources/ChirpCore/DictationMachine.swift:74`
and `android/app/src/main/java/dev/chirp/android/ChirpImeService.kt:259`.

After Stop, the WebSocket handler awaits the entire `utterance.finish()` before
reading another frame. If the user presses Escape/Cancel while decoding is in
flight, the queued cancel cannot set `aborted`: the server proceeds to correction,
debug retention when enabled, and a final response. Closing the client socket also
does not let this receive loop observe the disconnect before those side effects.
This violates the §3 cancel/discard contract and can send a cancelled transcript
to a configured remote corrector. The clients discard the result locally, which
hides the server-side work from the user.

**Evidence:** `server/tests/test_review_round2.py` blocks a fake engine's finish,
queues cancel, releases finish, and records correction/retention calls without
writing any transcript. Strict xfail `R2-01` asserts that none of those effects
occur. No external correction request is made.

**Suggested fix:** Keep receiving control/disconnect frames while finalization is
running. Mark the utterance cancelled and suppress correction, retention, and
final delivery after each await; cancel an already pending correction request.
Let native inference drain safely on its owning thread before cleanup. A request
already sent remotely cannot be recalled, but cancellation received before decode
finishes must prevent the request from starting.

### R2-02 — P1: “Use raw” can Undo unrelated edits or act on a secure field

**Locations:** `mac/Sources/ChirpCore/Insertion/TextInserter.swift:51`, `:96`,
`:106`; `mac/Sources/ChirpMac/DictationController.swift:268`.

For a pasted final, `last` stores only `.paste`. During the five-second raw-undo
window, switch apps/fields or type another edit, then click “Use raw”. The code
posts Command-Z to the *current* target without checking the original app,
element, cursor, or intervening edits, then inserts raw text there. It can undo
unrelated work and put dictated text in the wrong field. With Secure Event Input
now enabled, Command-Z is still posted before `insert(raw)` refuses insertion.

**Evidence:** two injected-fake tests in `ReviewRound2Tests.swift`, marked known
issue `R2-02`, change the frontmost bundle or enable secure input after a paste.
Both demonstrate that Undo is still called. No real keystrokes are posted.

**Suggested fix:** Guard secure input before *any* replacement side effect. Bind
replacement to a verifiable original target and unchanged inserted range. Where
a pasted insertion cannot be verified, offer an explicit copy-raw fallback rather
than a blind Undo. Invalidate replacement when focus/selection/edits change.

### R2-03 — P2: Overlapping pastes lose the user's original clipboard

**Location:** `mac/Sources/ChirpCore/Insertion/TextInserter.swift:115`.

Paste A schedules a 600 ms restore of the user's clipboard. Paste B arrives before
that delay expires (for example, quickly choosing “Use raw”). B cancels A's restore
and snapshots the clipboard while it contains A's transient transcript. A's
change-count check then rejects its restore; B later restores transcript A,
permanently losing the original clipboard and leaving dictated text there.

**Evidence:** `overlappingPastesPreserveOriginalClipboard` in
`ReviewRound2Tests.swift` uses two injected sleep barriers and a fake pasteboard;
the known-issue `R2-03` assertion expects the original clipboard after both tasks.

**Suggested fix:** Keep the original clipboard snapshot and ownership count in a
single restoration transaction spanning successive Chirp writes. Preserve the
existing guard against overwriting a genuine intervening user copy. Ensure
cancellation cannot restore a superseded snapshot.

### R2-04 — P2: A failed Mac audio-engine start leaves its input tap installed

**Locations:** `mac/Sources/ChirpMac/AudioCapture.swift:19`, `:38`, `:45`;
`mac/Sources/ChirpMac/DictationController.swift:200`.

`install()` installs the input tap and then calls the throwing `engine.start()`.
If start fails after the tap is installed (for example, an input-device startup
failure), the catch only clears `onFrame`. `isRunning` therefore becomes false,
so controller teardown skips `capture.stop()`, leaving the tap and converter
installed. The next dictation calls `installTap` again on that bus; it has no
cleanup path for the previous tap. This breaks retry after an ordinary capture
failure and can produce an AVAudioEngine duplicate-tap failure.

**Evidence:** confirmed control flow by inspection, not a hardware reproduction;
the concrete capture class has no injected engine seam. No TCC APIs were called.

**Suggested fix:** Track tap installation independently of `onFrame` and unwind
the tap, engine, converter, and observer on every partial-start failure. Make stop
idempotent and usable after a failed start. Inject an engine adapter to test
failure after tap installation and a successful subsequent start.

### R2-05 — P2: Mac retains raw and final transcripts after the undo window expires

**Locations:** `mac/Sources/ChirpMac/DictationController.swift:20`, `:21`, `:166`,
`:235`, `:269`; `mac/Sources/ChirpCore/Insertion/TextInserter.swift:51`, `:72`;
`mac/Sources/ChirpMac/HUD.swift:119`.

Finish a dictation and leave the app idle. Hiding the HUD clears its visible model,
but does not clear `pendingFinal` or `lastInsertion`, which both retain the final
including raw transcript. The inserter separately retains AX text in `last`.
These references outlive the five-second raw-undo affordance and can remain until
the next successful insertion or application exit, even with debug retention off.
Cancelling a later dictation does not clear the earlier `lastInsertion` either.
This contradicts the memory-lifetime promise in architecture §4. This finding is
about strong in-memory references, not a claimed disk/log leak.

**Evidence:** inspected assignments and all teardown/HUD-hide paths; there is no
expiry clearing these controller/inserter fields.

**Suggested fix:** Consume and clear `pendingFinal` at insertion. Keep only the
minimum replacement data while the undo affordance is available, then clear both
controller and inserter state on expiry, cancellation, focus invalidation, or
new dictation. Add a fake-clock expiry test.

### R2-06 — P2: Mac recording has unbounded outbound buffering during a stalled socket

**Locations:** `mac/Sources/ChirpCore/StreamSession.swift:28`, `:40`, `:66`, `:76`;
`mac/Sources/ChirpMac/DictationController.swift:140`, `:187`, `:297`.

The audio `AsyncStream` uses its default unbounded buffer, and `sendAudio` always
yields without checking capacity. Capture starts before ready and has no local
120-second sample limit or connecting/listening deadline. If an established
socket stops draining writes, capture continues appending PCM while the pump
awaits `socket.send`. The server's byte limit cannot protect audio not yet sent.
Memory grows at approximately 32 KB/s plus frame overhead and the mic stays open
until user action or eventual transport failure. Stop has a 25-second controller
timeout, but the recording phases do not. Cancel also awaits a socket send before
closing, so teardown depends on a stalled transport progressing.

**Evidence:** code-path inspection; no network blackhole or live microphone was
used. Android's explicit pre-ready/send-queue bounds are absent from this path.

**Suggested fix:** Use a bounded audio queue with an explicit overflow error that
stops capture; enforce a local recording-duration limit and a ready deadline.
Make cancellation close the socket promptly without waiting indefinitely for a
cancel frame. Add an injected transport whose send never completes.

### R2-07 — P2: Android raw replacement deletes the final before knowing replacement succeeds

**Location:** `android/app/src/main/java/dev/chirp/android/ComposingSession.kt:52`.

`useRaw()` first deletes the corrected final with `deleteSurroundingText`, then
calls `commitText(raw)`. If the editor accepts the deletion but rejects the commit
(for example, the editor connection becomes unavailable between the two calls),
the corrected text is gone. `beginBatchEdit` does not provide rollback, and the
finally block discards the saved raw/final data. The service also forgets the undo
affordance, giving the user no recovery from this failure.

**Evidence:** `ReviewRound2Test.kt` uses an interface fake accepting deletion and
rejecting the subsequent commit. The desired preservation assertion is gated
with a JUnit assumption identifying `R2-07`; `CHIRP_REVIEW_REPRO=1` enables it.

**Suggested fix:** Replace the verified range through a single editor replacement
operation (for example, a selected/composing range followed by commit), without
first deleting text. Keep recovery data when the editor reports failure, and test
both rejected selection/replacement and connection loss between operations.

## Checked and fine within the inspected/tested scope

- Server authenticates HTTP transcription and WebSockets using constant-time
  credential comparison; explicit bad headers cannot fall back to frame auth.
  Unauthenticated health reveals liveness only. Pending frame-auth handshakes
  have both a deadline and a count limit.
- Server PCM size/frame limits, engine lease, and single-thread executor cover
  normal feed/final/cancel calls. MLX context closure is explicitly dispatched
  through that worker. No claim of native-model or fault-injection coverage.
- Default server retention save is a no-op. App-level errors are fixed safe
  strings, CLI disables access logs and HTTP library info logs, and correction
  disables environment proxies. Existing privacy tests check synthetic content
  against writes/logs. No confirmed token/log leak was found in these paths.
- Android uses Keystore AES-GCM with fresh IVs, disables backup/device-transfer
  of preferences, masks pairing entry, disables entry state saving/autofill,
  redacts Pairing.toString, and clears consumed intent data. HTTPS pairing rejects
  credentials, query strings, and fragments; redirects are disabled.
- Android caps pre-ready audio and WebSocket queued bytes, limits capture to
  120 seconds, clears owned PCM buffers, and invalidates stale callbacks on
  cancellation. Hide/unbind/destroy paths stop capture and retire transports.
  Reconnect is bounded to one retry before readiness; no automatic retry storm
  was found. Fold handling was inspected but not device-tested.
- Mac accepted-but-unverified AX writes do not automatically fall through to
  paste, avoiding that double-insertion path. Ordinary paste restoration checks
  changeCount so an intervening user copy is preserved. Initial insertion refuses
  Secure Event Input; the raw-replacement exception is R2-02.
- Both clients' start/audio/final payloads match §3 in normal flow; Android reuses
  sockets and rejects stale sequence numbers. Mac opens a fresh socket per
  utterance (an efficiency difference, not reported as a correctness bug).

## Validation

Run on 2026-10-17 through `koi run --max 15m --tail 50 -- sh
.koi/review-validation/run.sh`. The wrapper completed in 50 seconds. Its exit zero
is **not** the Android reproduction result: the wrapper captured and printed each
individual command's exit status, including the intentional failure below.

The run used a fresh worktree-local HOME and TMPDIR under
`.koi/review-validation/`, `UV_CACHE_DIR=~/.cache/uv`, and
`GRADLE_USER_HOME=~/.gradle`. Dependency resolution was offline. Python's
temporary test files were also confined to the worktree. Android's existing
`~/.local/share/chirp-android/env.sh` selected the JDK/SDK. No server CLI,
real token, model, device, TCC prompt, or external network was accessed; Android
network unit tests use local ephemeral mock servers and synthetic credentials.

| Directory | Exact command | Result |
|---|---|---|
| `server/` | `uv run --offline --locked ruff check .` | Exit 0; all checks passed. |
| `server/` | `uv run --offline --locked pytest -q --basetemp=<checkout>/.koi/worktrees/chirp-review-40730d/.koi/review-validation/pytest` | Exit 0; **63 passed, 2 deselected, 1 xfailed** in 0.82 s. R2-01 is the strict xfail; model tests were deselected. |
| `mac/` | `./scripts/test.sh --filter ReviewRound2Tests` | Exit 0; **3 tests, 3 known issues**, covering R2-02 twice and R2-03 once. Only injected fakes ran. |
| `android/` | `./gradlew --offline testDebugUnitTest` | Exit 0; BUILD SUCCESSFUL. R2-07 is skipped by its assumption; the live-server test remains opt-in. |
| `android/` | `CHIRP_REVIEW_REPRO=1 ./gradlew --offline testDebugUnitTest --tests dev.chirp.android.ReviewRound2Test --rerun-tasks` | **Exit 1, intentional:** 1 test, 1 failure, `ComparisonFailure` at `ReviewRound2Test.kt:32`; the deleted corrected text is not preserved. |
| repository root | `git diff --check` | Exit 0. |

The Swift known-issue blocks are the Swift Testing equivalent of expected
failures; Android's normal run skips the explicitly enabled failing reproduction.
R2-04, R2-05, and R2-06 remain inspection-confirmed findings, not runtime-tested
hardware/network failure scenarios. The full Mac suite, real-model tests, device
tests, and e2e script were not run. Existing Android nullable-type warnings in
`LiveServerTest.kt` were emitted during compilation; no production changes were
made to address them.

## Fix status (orchestrator, chirp/integration)

| ID | Owner | Status | Evidence |
|---|---|---|---|
| R2-01 | server | **fixed** in `chirp/server-r2` 198c097 + 83cf419, merged f918a9d | finalization keeps reading frames; cancel/disconnect suppresses correction (in-flight request cancelled), retention and final; nothing is sent after cancel and the socket stays usable. Strict xfail is now a passing test, plus a mid-correction cancel test; server suite 96 passed + 2 model tests |
| R2-02 | mac | **fixed** in `chirp/mac-r2` 8fc5507, merged 52813fa | Use raw checks secure input first, replaces only a verified AX range in the same frontmost app, otherwise copies raw (no ⌘Z); ReviewRound2Tests now ordinary passing tests; Mac suite 100 tests, no known issues |
| R2-03 | mac | **fixed** in `chirp/mac-r2` 8fc5507, merged 52813fa | one clipboard-restore transaction across overlapping pastes; ReviewRound2Tests now ordinary passing tests; Mac suite 100 tests, no known issues |
| R2-04 | mac | **fixed** in `chirp/mac-r2` 8fc5507, merged 52813fa | CaptureEngine adapter; failed start/device-change rebuild unwinds; idempotent stop; ReviewRound2Tests now ordinary passing tests; Mac suite 100 tests, no known issues |
| R2-05 | mac | **fixed** in `chirp/mac-r2` 8fc5507, merged 52813fa | raw kept only in inserter undo state; expires after 5 s (injected clock), cleared on cancel/abort/new dictation; ReviewRound2Tests now ordinary passing tests; Mac suite 100 tests, no known issues |
| R2-06 | mac | **fixed** in `chirp/mac-r2` 8fc5507, merged 52813fa | StreamLimits: 512 KB unsent-audio bound with overflow error, 120 s cap, 10 s ready deadline, cancel closes after 300 ms grace; ReviewRound2Tests now ordinary passing tests; Mac suite 100 tests, no known issues |
| R2-07 | android | **fixed** in `chirp/android-r2` 5fbf1e3, merged 0851833 | single composing-region replacement. Three ungated `ReviewRound2Test` cases and a service retry test. lint clean; 83 tests (81 pass, 2 opt-in live-server skips); debug + release build |
