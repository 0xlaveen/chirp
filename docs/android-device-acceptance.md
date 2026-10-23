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
