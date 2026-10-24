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
