# Android UX plan (October 2026)

A research and design record for making Chirp for Android feel like a current Material 3 Expressive app. It covers the setup app, the Chirp section in HeliBoard's settings, History, the in-keyboard strip, the Scratchpad (#42, merged in #63) and the coming Live Notes (#57). The work is split into five issues, #68–#72. This page is the summary; the mockups and acceptance criteria are in the issues.

## How the audit was done

- **Source:** the debug unit-test build at `5bc7952` (after #51, #53 and #55), re-checked against `5a2ab7a` (Scratchpad, #63).
- **Committed renders:** `docs/screenshots/android/` (setup, keyboard, panel, history, Fold).
- **Throwaway Robolectric renders:** the same composables in a 411 × 3200 dp viewport, so whole scroll pages are visible, in light, dark and fontScale 2.0. These were not committed.
- **No emulator session:** the shared fold emulator was in use by other workers.

## What's wrong today

1. **Settings are split across two places, and neither is complete.** Setup step 4 and HeliBoard → Chirp both hold clean-up, stop mode, keyboard look, swipe typing and history.
   - Only the HeliBoard section has spoken commands, sound cues, the hardware-keyboard shortcut and the larger mic.
   - Only setup has updates, the floating mic, the debug overlay, Forget pairing and (since #63) the Open Scratchpad link.
   - The two Diagnostics dialogs differ: only one of them has Copy.
2. **Setup step 4 is one ~3,000 dp page** (about 3.4 phone screens; more than 3,200 dp at 200% font). It is titled "Settings" but still shows "Step 4 of 4" and the setup progress bar. Forget pairing is an unconfirmed text link.
3. **Long explanations crowd out the controls.** Swipe-typing licence text, floating-mic Accessibility steps and the history privacy note each run 4–6 lines of `bodySmall`. At 200% font, setup step 1's primary button is about 1.8 screens down.
4. **No design system.**
   - The app's theme is hard-coded green. The default Gboard-like keyboard uses wallpaper dynamic colour, so the app and the keyboard never match.
   - There are four different hand-built switch rows and loose text-button links.
   - Done states are shown with "✓" characters, and there's no shape or motion language.
5. **No home.** The launcher always opens the wizard. Connection status is a sentence in a card, History is a separate activity reached from a settings link, and Scratchpad and Notes have nowhere to live.
6. **History screen:**
   - Settings sit above the list.
   - Entries are undated cards with three text buttons, and delete has no undo.
   - It's a single 600 dp column on the Fold's inner screen.
7. **Keyboard strip:**
   - The listening state is easy to miss.
   - "Inserted · tap mic to dicta…" truncates at 411 dp.
   - Errors look like successes, and debug retention uses a fixed red.
   - The long-press options are a plain `PopupMenu` that marks state with text ("Style · Default ✓").
   - The active history toggle renders as a solid blob with no visible icon.
8. **Inner screen:** every app screen is one centred column with no list-detail layout. The keyboard side already adapts well (number row, split landscape).
9. **Render hygiene:** `setup-1-light.png` (a setup render, since retired with the old setup page) was committed as an empty frame until #63 regenerated it. #71 adds a non-blank guard so this can't recur.

What already works and should be kept:
- strict privacy copy;
- live regions and one announcement per final;
- the reduced-motion checks in the strip;
- `safeDrawingPadding`, so edge-to-edge is already respected;
- adaptive keyboard geometry on the Fold;
- the Tailscale-off and Mac-offline recovery actions.

## Reference points

- **Material 3 Expressive** (I/O 2025, rolling out with Android 16 through 2026):
  - new components: button groups, split button, floating toolbar, loading indicator;
  - a shape-morph and motion-physics scheme;
  - grouped, rounded containers in settings.
- **Gboard:**
  - Settings moved to M3 Expressive grouped containers in 16.5 (stable).
  - The 2025 voice-typing toolbar swaps the keys for a pill with a coloured mic, "Speak now / Paused" status and a commands hint.
- **Samsung Keyboard (One UI 8):** Writing Assist pinned to the toolbar; voice input chosen from keyboard settings.
- **Wispr Flow (Android, Feb 2026):** a floating bubble (tap or hold to talk) over any keyboard, a dashboard with word-count stats, and language selection.
- **Typeless:** a minimal voice keyboard (big mic, space, delete, return), a Home screen with usage insights, and an on-device History tab with configurable retention.
- **Android 16/17 platform behaviour for `targetSdk ≥ 36`** (Chirp targets 37):
  - edge-to-edge can't be opted out of;
  - predictive back is on by default and `KEYCODE_BACK`/`onBackPressed` are no longer delivered;
  - orientation and resizability locks are ignored on large screens;
  - for UI, dynamic colour and adaptive (bar ↔ rail, list-detail) layouts are the expected baseline.

Sources: [M3 Expressive blog](https://m3.material.io/blog/building-with-m3-expressive) · [Gboard M3E rollout](https://www.androidauthority.com/gboard-material-3-expressive-rollout-3622810/) · [Gboard M3E settings](https://9to5google.com/2026/02/14/gboard-apostrophes/) · [Gboard voice-typing toolbar](https://www.androidauthority.com/gboard-assistant-voice-typing-new-layout-3524588/) · [Wispr Flow for Android](https://techcrunch.com/2026/02/23/wispr-flow-launches-an-android-app-for-ai-powered-dictation/) · [Wispr Flow hands-on](https://www.androidpolice.com/wispr-flow-app-android-voice-typing-experience/) · [Typeless](https://www.makeuseof.com/typeless-ai-voice-typing-android/) · [Typeless FAQ](https://www.typeless.com/help/faqs) · [Samsung Keyboard in One UI 8](https://www.androidpolice.com/samsung-keyboard-optimize/) · [Android 16 edge-to-edge and back](https://duonary.com/blog/android-16-edge-to-edge-enforcement-migration/)

## Target structure

```
Launcher ─► onboarding (first run: Welcome · Keyboard · Mic · Pair, auto-save on scan)
         └► app shell   ┌ Home      Mac status card + one fix action · Dictate (Scratchpad #42)
                        │           · Notes (#57) · recent history · first-run "Try it"
                        ├ Notes     Live Notes (#57), hosted as a tab
                        ├ History   search · day groups · detail sheet · swipe-delete + Undo
                        └ Settings  one tree: Mac connection · Dictation · Keyboard · Feedback
                                    · Privacy & history · Other ways to dictate · About
HeliBoard → Chirp  ─► compact summary + "Open Chirp settings ›"   (no duplicate controls)
Keyboard long-press ─► sectioned menu (Clean-up switch · Style radios · Chirp settings)
```

For Notes, follow section 5 of [live-notes-ux.md](live-notes-ux.md#5-what-android-live-notes-57-should-carry-over); #70 only hosts that screen as a tab.

Navigation is a bar on the cover screen and a rail on the inner screen (`NavigationSuiteScaffold`), with list-detail panes on the inner screen for History and Settings. Predictive back throughout.

```
┌────────────────────────────────┐
│ Chirp                     ⚙    │
│ ╭────────────────────────────╮ │
│ │ ● Mac connected            │ │
│ │ mac.tailnet.ts.net         │ │
│ ╰────────────────────────────╯ │
│ ╭─────────────╮╭─────────────╮ │
│ │     🎙       ││     ✎       │ │
│ │  Dictate    ││  Notes      │ │
│ ╰─────────────╯╰─────────────╯ │
│ Recent                  All ›  │
│ Pick up oat milk, lemons…   ⧉  │
│ Can we move the design rev… ⧉  │
├────────────────────────────────┤
│  ⌂ Home   ✎ Notes  ⏱ History  ⚙ │
└────────────────────────────────┘
```

## Issues and order

| # | Issue | Main files | Sequence |
|---|---|---|---|
| [#68](https://github.com/araa47/chirp/issues/68) | Design foundation: dynamic colour, shape/type tokens, shared `SettingsGroup`/`SwitchRow`/`StatusBanner`/`InfoSheet` | new `ui/`, visual-only edits to setup and settings composables | First. Prefer after #34 (Diagnostics code) |
| [#69](https://github.com/araa47/chirp/issues/69) | One Chirp Settings tree; HeliBoard section becomes a summary; confirm Forget pairing | `ChirpSettingsSection.kt`, `SetupWizard.kt` step 4, `SetupActivity.kt`, new `settings/` | After #68 and #34 |
| [#70](https://github.com/araa47/chirp/issues/70) | App shell: Home + bar/rail + History tab redesign | new `shell/`, `SetupActivity.kt`, `HistorySettings.kt`, manifest | After #68 and #69 (#42 has landed); hosts #57 as a tab |
| [#71](https://github.com/araa47/chirp/issues/71) | Short full-screen onboarding, auto-save after scan | `SetupWizard.kt` steps 0–2, `SetupActivity.kt` | After #68; one after the other with #69 |
| [#72](https://github.com/araa47/chirp/issues/72) | Keyboard strip states: listening tint, mic↔stop morph, chips, sectioned long-press menu | `KeyboardStrip.kt`, `VoicePanel.kt`, `KeyboardHistory.kt`, menu code in `KeyboardDictation.kt` | After #40; parallel with #68–#71 |

Suggested order: **#34 → #68 → (#69, then #71) → #70 (with #57)**, and **#40 → #72** in parallel.
