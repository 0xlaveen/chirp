# Android real-device acceptance (Fold)

Every Android validation record so far comes from an emulator. This checklist is the one pass on the operator's Fold that closes the gap: microphone quality, battery, Tailscale latency and smoothness. It takes about 45 minutes and uses synthetic speech only (read a neutral paragraph aloud; never dictate private text). Nothing below needs a code change or leaves content on the phone or in the repo.

Before you start: update the app **in place** (never uninstall, so the pairing survives), unplug the phone at a steady charge and brightness, turn Tailscale on for phone and Mac, and make sure the Mac server is running. Note the app version (Android Settings → Apps → Chirp) for the record.

## 1. Clean slate

1. Setup → **Diagnostics → Clear timings**, so the summary covers this run only.
2. Open a plain text field (a notes app or the setup *Try it* field) and switch to Chirp.

## 2. Battery session

With the phone on wireless debugging (`adb connect IP:PORT`; see [android/README.md](../android/README.md#develop-and-test)):

```sh
cd android
NETWORK=wifi UTTERANCE_SECONDS=10 scripts/battery-session.sh 10      # again with NETWORK=lte on mobile data
```

It resets batterystats, asks you to dictate N utterances, then leaves Chirp visible and idle for 5 minutes and writes the counters under `~/Library/Caches/Chirp/battery/`. It captures system counters only, never audio or text. Read the UID `dev.chirp.android` estimated mAh and keep the printed `docs/bench.md` row.

## 3. Perfetto trace

Re-run the session with a 120 s trace for scheduling and power rails (dictate repeatedly while it records):

```sh
PERFETTO=1 NETWORK=wifi scripts/battery-session.sh 5
```

Open the pulled `chirp-battery.perfetto-trace` at <https://ui.perfetto.dev> locally in the browser, and look for main-thread stalls in `dev.chirp.android` during partials, dropped frames while the waveform runs, and CPU frequency while idle. Traces stay in the cache directory; do not commit them.

## 4. Stop matrix by hand

Dictate about 5 s of synthetic speech each time and confirm no crash, the field is never left underlined, and the keyboard stays usable afterwards.

| # | Case | How | Expect |
|---|---|---|---|
| 1 | Immediate | Tap mic, tap stop at once | "Didn't catch that" or an empty result, no hang |
| 2 | Listening | Tap mic, stay silent 2 s, stop | Same as above |
| 3 | Partial | Speak, stop mid-sentence | Final replaces the underlined text |
| 4 | Polishing | Speak, stop, watch **Polishing…** | Cleaned text lands; **Use raw** offered |
| 5 | Double stop | Tap stop twice quickly | One final, no error |
| 6 | Hide | Speak, hide the keyboard | Dictation discarded, nothing typed |
| 7 | Focus | Speak, tap another field | Dictation discarded in the old field |
| 8 | Unbind | Speak, switch to another keyboard | Mic released, no crash |

Also try: hold-to-talk, ✕ cancel, fold/unfold mid-utterance, Wi-Fi vs LTE, Tailscale off then **Turn on**, and the countdown in the last 15 s before the 10-minute limit. Check **Settings → About → Diagnostics → Crashes** is empty at the end.

## 5. Collect the timings

Setup → **Diagnostics** now shows content-free session timings (the last 50 sessions): p50/p90 of connect, ready, first partial, stop → final, polishing and audio length, counts per outcome and error code, network type (Wi-Fi, cellular, Ethernet), whether a VPN was up and how many sessions used the prewarmed socket, and ready p50/p90 for warm vs cold sessions (adaptive prewarm: the first dictation after a quiet spell is cold, the ones after it warm). Tap **Copy diagnostics** and paste it into [bench.md](bench.md) under a new dated heading, together with:

- the device, Android build, Chirp version and Mac engine;
- the `battery-session.sh` rows for Wi-Fi and LTE;
- the stop-matrix result (pass/fail per row) and anything that looked wrong;
- subjective notes on microphone quality and smoothness.

Run the session once on Wi-Fi and once on LTE and record each separately: clear the timings between them. Report only what was measured; mark anything skipped as not verified.

## 6. Notes battery

Live Notes records with the screen off for a whole meeting, so measure it separately. Use synthetic speech (a podcast or a read-aloud paragraph playing near the phone), never a real meeting.

```sh
cd android
MODE=notes NOTES_MINUTES=20 NETWORK=wifi scripts/battery-session.sh
```

It resets batterystats, asks you to start **Record** in Notes and turn the screen off for the given minutes, then to turn it on, check the notes caught up at once, and **Stop**. Then:

1. Run it twice, with **Save battery while the screen is off** on and then off (Chirp settings → Privacy & history → Notes, or the gear on the Notes screen), at the same charge, brightness and network.
2. Read the UID `dev.chirp.android` estimated mAh from each `notes.txt` and note it per minute.
3. Copy the newest **Chirp settings → About → Diagnostics → Notes sessions** line for each run (minutes recorded and off, segments, gaps, notes calls, screen updates run and skipped). With the saver on, "skipped" should be far larger than "updates" and the mAh per minute lower; segments and notes calls should match the saver-off run.
4. Check that the notes were current the moment the screen came on, with no catch-up delay, and that `dumpsys power | grep -i wake` showed no Chirp wake lock during the run.

Record both rows in [bench.md](bench.md). Emulator numbers are not battery truth; leave the rows out until the phone run is done.

## Keep your keyboard: onboarding and Settings

Use a test phone with Gboard or Samsung Keyboard selected. Finish Welcome, confirm neither choice card is selected and Continue is disabled, choose Keep, and confirm no Chirp Keyboard requirement appears. Read the disclosure before opening Accessibility. Check the deep link opens Chirp’s service details (or the Accessibility list where unsupported).

- **Sideload restriction (hardware):** after a blocked enable attempt, return and check the Restricted setting help. Open app info, verify the overflow option appears only after the blocked attempt, unlock to allow restricted settings, retry Accessibility and enable. Returning should advance to Microphone. Repeat a second unsuccessful return and confirm help opens automatically. Menus vary by One UI version; capture the actual path without personal information.
- **Advanced Protection (hardware):** on an enrolled supported device, verify the warning and two alternatives appear, and no Accessibility enable action is offered. Choose Continue without it and finish pairing without changing keyboards. If Protection disables a previously enabled service, Settings must say Turned off by Advanced Protection. A managed phone may block the feature independently. Emulator tests fake Protection and exercise the UI; they do not prove enrollment or OEM policy.
- **Switch later:** Settings → How you dictate reflects current service and IME state after leaving and returning. Switch both ways; open Choose keyboard and dismiss it. With Chirp still selected, Keep offers Switch back to your keyboard. Keyboard category explains it is not in use and the hardware shortcut requires Chirp Keyboard.
- **Other surfaces:** Notes, Scratchpad, History and existing tiles work in either mode. A skipped floating mic leaves a dismissible Turn on the floating mic reminder in Notes. With Chirp Keyboard selected, there must be no second floating mic; with another keyboard and an eligible field, it returns. Check passwords and apps with custom editors separately; no universal insertion claim is made.
- **Accessibility and layout:** with TalkBack, each choice is one radio node with its full explanation and selected state. Check cover and inner screens in light/dark and at 200% font. The bottom primary action stays visible and all guide content scrolls into view.

Automated reproduction: launch your own `chirp-fold -read-only -no-snapshot-save -port <free-even-port>`, set `ANDROID_SERIAL`, run `emulator-smoke.sh`, then debug `emulator-check.py --keepkb-check --server-port <free-port>` with a cached model and debug APK. Rebuild the all-window probe and run `emulator-talkback.py --keepkb-check`. The editor probe exists only in debug and reports lengths/states without printing text.

Implementation verification: the bounded keep-keyboard emulator attempt reached the choice page, then the read-only emulator hung and disconnected while waiting for the floating-mic page (`ADB operation failed: shell`). The throwaway server stopped and the emulator process exited; secure-setting restoration could not finish after the disconnect, and no snapshot was saved. Full runtime acceptance, release smoke and the new TalkBack path remain pending. Advanced Protection and real sideload restrictions are covered by fakeable/UI tests and the hardware steps above, not claimed as emulator coverage.

## Keep your keyboard: the floating mic

The emulator can't reproduce One UI's foreground-service and app-op rules for a microphone started from an Accessibility service, or Samsung's own editors. Check them here with Samsung Keyboard (or Gboard) still selected, using synthetic speech only.

1. Turn on Android Settings → Accessibility → Installed apps → **Chirp floating microphone**. If Android says "Restricted setting", allow it under Apps → Chirp → ⋮ first.
2. **Samsung Notes.** Focus a note body. The bubble appears at the right edge, clear of the text. Tap it, read a sentence, tap **Stop**. Record whether the text was **Inserted** or ended in **Ready to copy** (rich editors may refuse `ACTION_SET_TEXT`). If it was Ready to copy, **Copy**, long-press the note and paste.
3. **Samsung Internet or Chrome.** Repeat in a web page's text area, and record Inserted or Ready to copy.
4. **Microphone start.** During each dictation, check that the green privacy dot and the "Chirp is listening" notification appear, and that both go away after Stop, Cancel, ✕ and an error. If the panel says "Android blocked the microphone here", record the One UI version: that is the FGS restriction this check exists for.
5. **Low field.** In a chat app with the message field at the bottom and the keyboard up, check that the bubble sits above the field, not over the keyboard. The emulator could not show this.
6. **Hold and drag.** Hold the bubble (push-to-talk) and release. Drag it to the other edge and confirm no privacy dot flashes. Fold and unfold: each screen keeps its own position.
7. **Clipboard history.** After a Copy, open Samsung Keyboard's clipboard panel and note whether the dictated text appears. The clip is marked sensitive, but One UI may keep it anyway.

Record the One UI version and each result. Mark anything skipped as not verified.

## Quick dictate, Speak buttons, widget and Share into Notes (#168)

With your normal keyboard still selected, and floating-mic Accessibility turned off:

1. Settings → How you dictate → Other ways to dictate: Add Dictate tile and Add Notes tile. Accept each Android prompt. On Android 12, follow the displayed shade/Edit instructions. Open Dictate while locked and confirm unlock is required before recording.
2. Dictate from the tile. Confirm live partials, Stop, sensitive clipboard final and “Copied — paste anywhere.” Paste in another app. Repeat with clean-up: Use raw must replace the clipboard. Touch the final to keep it open; leave another final untouched and confirm it closes after four seconds. Edit in Scratchpad must retain the words without a text-bearing Intent. Confirm the microphone indicator disappears on final, Cancel, Back, Home, error and leaving while polishing.
3. Launch an app’s Speak button. If Android offers a chooser, choose Chirp Just once or Always. Confirm only one final reaches that app, including polished text; Cancel inserts nothing. Try the caller’s language, partial-results and offline options without expecting them to alter the Mac engine or provide on-device recognition. Disconnect the server, abandon the displayed error with Done, and confirm the caller receives an error rather than success. Neither Samsung’s nor Gboard’s own mic is promised to route here.
4. Add Widget in Chirp, then place its 2×1 widget on the launcher. Dictate must open clipboard capture; Record must start Notes. Resize to 1×1: only Dictate remains. Check light/dark and Match wallpaper, including Samsung’s launcher. Widget placement is an operator check; automation asserts its RemoteViews launch intents.
5. Share plain text from another app. Save as new note must add exactly one local note with the subject/first-line title. While a note records, then while paused, share again and Add to that note; confirm the text appends, the title stays, and recording continues. Stop that note while the dialog is open: a late Add must never target a replacement recording. Cancel, non-text and >100,000-character shares must create nothing.
6. Keep dictation history off, then enable it and repeat the tile/Speak cases. Only the enabled cases should appear, labelled Quick dictate or the caller’s app. Check Samsung clipboard history separately; the sensitive flag is not a guarantee that the OEM deletes it.
7. With TalkBack, navigate the Quick dictate status, Stop, Cancel, one error fix, Use raw, Edit in Scratchpad and Done; activate the Share dialog’s save/append/cancel actions and both widget buttons. Repeat on cover/inner screens with large fonts and reduced motion. Confirm all actions remain reachable.

Emulator automation covers synthetic capture, chooser resolution, result/cancellation/error, sensitive clipboard lengths, Notes tile, text share, provider discovery, resource teardown and TalkBack labels. OEM launchers, Samsung clipboard retention and real microphone indicators require these hardware steps.

Automated evidence for #168 (2026-10-25): the real-server Quick dictate matrix and release smoke/TalkBack phases passed in one host-locked, read-only Fold AVD (2 cores, 3072 MB). Gboard stayed selected; Accessibility was disabled for the entry matrix. Both Chirp and Google resolved the Speak intent (this Play image provides Google’s handler through `com.google.android.tts`). Every tested end state had no Chirp recording client or foreground service. Launcher placement and OEM clipboard retention remain the operator steps above.
