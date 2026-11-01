# Notch spike harness (Chirp v2, PR 0)

**Throwaway.** Lives on branch `v2/pr0-notch-spike`, never merged to `main`, no PR. Delete `spikes/notch/` when done.
It answers the open questions in `~/koi-tasks/chirp-v2/ship-plan.md` section 2 (PR 0) and section 6 (risks 1 and 5):
which window level sits over the menu bar on macOS 14/15/26, behaviour with full-screen apps, Spaces, Stage Manager,
external displays and clamshell, whether the panel ever steals focus, and whether `@Namespace` / `matchedGeometryEffect`
builds under CLT. **PR 3 must not start until the matrix below is filled in on real notched hardware.**

## Build and run (Command Line Tools only, no Xcode)

```sh
cd spikes/notch
swift run NotchSpike                      # interactive: a "Notch" item appears in the menu bar, no Dock icon
swift run NotchSpike --selftest           # scripted checks on this display, exit 0/1 (add --verbose for full logs)
swift run NotchSpike --snapshots out/     # render island PNGs (notch + floating, 3 states) to out/
```

Interactive controls (status item menu; the global hotkeys need Accessibility permission, the menu always works):
state (ctrl+opt+1/2/3), window level (ctrl+opt+L cycles), collection behaviour toggles, simulated notch (ctrl+opt+S),
display (ctrl+opt+D), diagnostics overlay (ctrl+opt+H), panel visible (ctrl+opt+V), click-through toggle,
"let AppKit constrain the frame" toggle, auto-cycle, and **"Hide, then re-show in 8s"** (use it to switch app / Space /
full-screen window while the panel is hidden, then watch where it reappears). Display changes, Space changes and
clamshell re-run layout automatically and are logged.

The console log and the bottom-left overlay print, for every screen: `frame`, `visibleFrame`, `safeAreaInsets`,
`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, derived notch width/height and menu bar height; and for the panel:
level, collection behaviour, actual vs expected frame (`frameDrift`), `isKey`, `isMain`, `appActive`, frontmost app
before and after, `STOLE_FOCUS`, and any `didBecomeKey` / `didBecomeActive` events. Lines starting with `>>` are events.
**To test focus properly, put TextEdit in front, type, and trigger states from the menu or hotkeys; the typing must never
stop and the log must never show `>> !! PANEL BECAME KEY`.** (Opening the status menu itself may activate the app; use the
hotkeys or the 8-second delayed show for the strict check.)

Files: `Geometry.swift` (pure layout from screen numbers, plus fake notch), `NotchShape.swift`, `IslandView.swift`
(3 states, `@Namespace` + `matchedGeometryEffect`), `Panels.swift` (non-activating panel), `Controller.swift`
(menu, diagnostics, focus tracking), `SelfTest.swift`, `Snapshots.swift`.

## What the numbers should look like on a notched MacBook

Approximate expectations, to be corrected from your log (the simulated notch uses 200 x 32):

| Item | Expected |
|---|---|
| 14" MBP `frame` | about 1512 x 982 (default scaled resolution) |
| 16" MBP `frame` | about 1728 x 1117 |
| `safeAreaInsets.top` | about 32 on notched displays, 0 on external displays (the menu bar is then about 24-30 tall) |
| `auxiliaryTopLeftArea` / `Right` | non-nil only on notched screens, height equals `safeAreaInsets.top`, one on each side of the notch, widths about (frame.width - notch) / 2 |
| notch width = `auxRight.minX - auxLeft.maxX` | about 200 pt for a 14" MBP (the plan's figure; 16" similar) |
| `visibleFrame.maxY` vs `frame.maxY` | differ by the menu bar height; equal (or nearly) in a full-screen Space where the menu bar is hidden |
| panel `frame` | `x = notchMidX - 260`, `y = frame.maxY - 150`, size 520 x 150, `frameDrift=no` |
| panel `isKey` / `isMain` / `STOLE_FOCUS` | false / false / false at all times |

## Manual test matrix (fill in Observed)

Run on each row, with all 3 states, and note the level and collection behaviour used. Default start: level `statusBar`,
all four collection flags on. For each row also try `mainMenu`, `mainMenu+1`, `popUpMenu`, `screenSaver`.

| # | Scenario | Expected | Observed |
|---|---|---|---|
| 1 | 14" notched MBP, built-in only, real notch (sim off) | Island merges with the notch, wings left/right of it, `REAL NOTCH width` about 200, no drift, no focus theft | |
| 2 | 16" notched MBP, built-in only | Same as 1, panel centred on the notch | |
| 3 | External display (non-notched), lid open, notched screen as primary | Pill/island on the chosen display only. On the external display the layout falls back to floating (or simulated) and nothing overlaps the menu bar unexpectedly | |
| 4 | External display, panel moved with Display menu / ctrl+opt+D | Panel follows the chosen screen, frame correct for a screen with a non-zero origin | |
| 5 | Clamshell (lid closed, external only) | `didChangeScreenParameters` fires, layout re-runs, no notch assumed, panel on the external display, no crash | |
| 6 | Another app in full screen (same display) | Level and `fullScreenAuxiliary` decide whether the island appears over it. Record which level shows it | |
| 7 | Chirp or harness app in a different Space; switch Spaces (ctrl+arrow) | With `canJoinAllSpaces` the panel is on every Space; without it, only the Space it was shown on. `>> active Space changed` is logged | |
| 8 | Stage Manager on | Panel is not tiled or grouped, does not appear as a Stage Manager thumbnail, stays at the top. Toggle `ignoresCycle` / `stationary` and note any difference | |
| 9 | Typing in TextEdit while the state cycles (auto-cycle) | No focus change, no keystroke lost, `STOLE_FOCUS=false`, no `PANEL BECAME KEY` | |
| 10 | Click the panel area while `ignoresMouseEvents` is on and off | On: click reaches whatever is under it (menu bar items, the clock). Off: record what is blocked | |
| 11 | Status items near the notch | Record whether the 520 pt panel (click-through) covers or blocks menu bar status items, including this harness's own | |
| 12 | macOS 14 | Rows 1-11, note any level that behaves differently | |
| 13 | macOS 15 | Rows 1-11 | |
| 14 | macOS 26 | Rows 1-11 | |
| 15 | "Let AppKit constrain the frame" on | Record whether AppKit pushes the panel below the menu bar, per level (this is why `Panels.swift` overrides `constrainFrameRect`) | |

Answers needed from the spike: (a) the lowest level that shows above the menu bar, (b) whether full screen apps need
`fullScreenAuxiliary` plus a given level, (c) any Spaces / Stage Manager surprise, (d) confirmation of `constrainFrameRect`
override and `sizingOptions = []`, (e) the real notch numbers above.

## What was verified without a notch (Mac with Command Line Tools only, macOS 26.6.2, Swift 6.3.3)

- Builds and runs with `swift build` / `swift run` under CLT only, Swift 6 language mode, macOS 14 deployment target.
- **`@Namespace` and `matchedGeometryEffect` compile and run** under CLT (used in `IslandView.swift`, the status dot
  is shared between the 3 states). Compile only: that it animates well, and behaviour on macOS 14, are not verified.
- `--selftest`: 9 geometry checks with fake insets (no notch, fake 14" and 16", a non-zero-origin screen, asymmetric
  aux areas) pass; the panel is positioned at the screen top, centred on the notch, 520 x 150, and keeps that exact
  frame at all 9 levels with the `constrainFrameRect` override; frame stays fixed across state changes
  (`NSHostingView.sizingOptions = []`); all 16 collection-behaviour combinations apply without raising; no
  `didBecomeKey` / `didBecomeActive` events and the frontmost app is unchanged.
- Rendered PNGs (`--snapshots`) reviewed: simulated notch merges with the cutout, wings sit left/right of the
  200 pt gap, polishing grows downward, floating pill is a rounded capsule.

## Still unverified (needs hardware or a person)

- Everything in the matrix above on a real notched MacBook, external display, clamshell, full screen, Spaces,
  Stage Manager, macOS 14 and 15 (only 26.6.2 available here).
- The live checks ran in a session that looked locked (frontmost app was `loginwindow`, panel `occluded=true`), so
  the level / focus / default-constrain results are weak evidence. Rerun `--selftest` in a normal logged-in desktop session.
- Real `safeAreaInsets` / aux area values (the simulated notch is 200 x 32, an assumption).
- Whether the click-through panel covers status items; global hotkeys (need Accessibility permission).
- Idle CPU / GPU of the island and VoiceOver behaviour.
