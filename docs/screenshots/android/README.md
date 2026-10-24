# Android UI review renders

All displayed speech is a generated synthetic fixture. No user speech, real pairing
credential or personal text is included.

- `keyboard-{idle,connecting,listening,countdown,polishing,final,tailscale,offline,phone,retention}-{light,dark}.png`:
  Robolectric native graphics on API 37, actual HeliBoard QWERTY keys with Chirp's production strip at 411 px
  width (Gboard-like look, cover screen), settled with animator scale 0. `final` shows the Undo / Use raw chips,
  `tailscale` the *Tailscale is off · Turn on* prompt, `offline` *Mac offline*, `phone` the phone-recogniser chip,
  `retention` the debug banner. The same states are rendered for the other looks and the 673 px inner screen as
  `keyboard-{gboard,samsung}-{cover,inner}-<state>-{light,dark}.png` (the default combination keeps the short names).
  `KeyboardRenderTest` also asserts the strip and key-area height is identical in every state.
- `emulator-keyboard-{idle,listening,final}-{light,dark}.png`: the authorized Android
  17 fold emulator (`emulator-5580`), actual IME window over the setup test field.
  A throwaway real Parakeet server receives say-generated speech through PcmCapture
  and StreamTransport. Listening shows live composing text; final shows committed
  text and the keyboard still selected. These captures do not simulate a phone mic.
- `setup-{1,2,3,4}-{light,dark}.png`: Compose wizard initial viewports at 411 × 891 px.
  The sequence is enable/select keyboard, mic permission, pairing, test. Longer
  content scrolls; Diagnostics is reachable throughout.
- `panel-{idle,connecting,listening,finalizing,error,raw,debug}-{light,dark}.png`:
  shared Material panel for the optional accessibility mic (700 px listening,
  360 px other states). This optional surface is separate from the full keyboard.

Regenerate the Robolectric artifacts from `android/`:

```sh
./gradlew testDebugUnitTest --tests '*VoiceUiTest*' --tests '*KeyboardRenderTest*'
```

For actual emulator captures, use `android/scripts/emulator-check.py` as documented
in `android/README.md`; it targets only the explicitly authorized emulator serial,
uses port 7899 and a throwaway HOME, then stops its server and removes its credentials.
No production server, Mac app or phone is accessed. The emulator has an unrelated
UWB HAL crash loop; the helper checks specifically for Chirp Java/native crashes.

These are review artifacts, not pixel-golden assertions or Galaxy hardware battery,
latency or microphone measurements. Samsung editor quirks and folding still need
operator acceptance on the phone.

## Design components

- `components-{light,dark}.png`: the shared settings components (`ui/ChirpComponents.kt`) in Pond:
  `SettingsGroup` with `SwitchRow`, `NavRow` and a destructive `ActionRow`, `ChoiceChips`, the four
  `StatusBanner` kinds and the `InfoSheet` body. `components-dynamic-{light,dark}.png` show the
  default wallpaper colours (Robolectric's stock dynamic palette), and `components-font-200.png`
  is the same gallery at 200% font. The test also checks that no label is clipped and every row
  is at least 48 dp tall. Regenerate with `./gradlew testDebugUnitTest --tests '*ChirpComponentsTest*'`.

## Keyboard looks

- `keyboard-look-{gboard,samsung}-{idle,listening}-{light,dark}.png`: Robolectric
  renders of the Gboard-like default (HeliBoard Rounded + borders, dynamic colours) and
  the Samsung-like look (Rounded + borders, Chirp's One UI-style user colours). The
  Chirp strip takes its ink, accent and highlight from the active keyboard colours.
  Regenerate with `./gradlew testDebugUnitTest --tests '*KeyboardRenderTest*'`.
- `before-keyboard-{inner,cover}-{light,dark}.png`, `before-keyboard-inner-landscape-light.png`:
  the round-4 release captures kept for comparison (Material keys, no borders, fixed
  green strip). The current `release-keyboard-*.png` files show the new default look.
## Release captures (round 4)

`release-*.png` are direct, unmodified PNG captures from the minified release APK on
`emulator-5580`, Android 17. Each file is below 2 MB. They are the primary review set:

- `release-keyboard-{inner,cover}-{light,dark}.png`: single suggestion row with mic;
  inner width has a number row, cover width stays compact.
- `release-pair-action-{inner,cover}-{light,dark}.png`: accessible pairing recovery in
  that same row, with no duplicated partial text.
- `release-pairing-light.png`, `release-scanner-light.png`: QR-first pairing and actual
  Google Play scanner surface, opened from the release APK.
- `release-typing-{autocorrect,contraction,next-word,clipboard,emoji}.png`: real
  HeliBoard key taps; `teh` corrects to sentence-cased `The`, `im` to `I'm`, next-word
  predictions, local clipboard history, and the emoji keyboard.
- `release-keyboard-inner-landscape-light.png`: landscape split with real key geometry checks; one-handed control reachability.
- `release-talkback.png`: release with TalkBack enabled; native accessibility click,
  long-click and mic/status/cancel labels are checked before the capture.

Regenerate with the toolchain sourced:

```sh
android/scripts/emulator-smoke.sh
android/scripts/build-ui-probe.sh
python3 android/scripts/emulator-talkback.py
```

The scripts restore display size/density/night mode and TalkBack service settings.
The smoke intentionally resets only Chirp's data on the authorized disposable emulator.
The shell-only probe supplements stock `uiautomator dump`, which omits the IME window
on this image. It is not packaged with the app. Neither release nor debug captures
establish Samsung hardware microphone quality or Tailscale performance.

## Fold function-key placement

`fold-layout-{before,after}-{gboard,samsung}-{form}-{light,dark}.png` are direct
release-APK captures on emulator-5580. `before` is unmodified 0.5.2; `after` includes
the functional-layout fix without a version bump. Both looks use the same geometry.

| Form | Display override | Density | Result before the fix |
| --- | --- | --- | --- |
| `avd-native` | reset (2076 × 2152) | reset (390 dpi) | Phone arrangement; about 851 dp smallest width |
| `inner-portrait` | 1968 × 2184 | 420 dpi | Tablet arrangement; about 749 dp smallest width |
| `inner-landscape` | 2184 × 1968 | 420 dpi | Tablet arrangement, split |
| `cover-portrait` | 1080 × 2520 | 420 dpi | Phone arrangement |
| `cover-landscape` | 2520 × 1080 | 420 dpi | Phone arrangement |

The native AVD misses the bug: upstream's sw768dp metric is 2, below the tablet
test of 3; sw600dp is 3. The representative inner overrides expose it. After the fix,
Backspace aligns with Z–M and Enter aligns with space/period at bottom-right. Shift
starts row three; the tablet-only punctuation and second Shift disappear. Portrait
uses the full width with comfortable letter proportions; inner landscape keeps the
existing split mode. Cover key coordinates are unchanged in both looks and themes.

With the desired APK installed and toolchain sourced, regenerate either look:

```sh
android/scripts/build-ui-probe.sh
python3 android/scripts/emulator-fold-layout.py --look gboard
python3 android/scripts/emulator-fold-layout.py --look samsung
# Add --before only when running the unmodified 0.5.2 baseline APK.
```

The helper asserts real accessibility key bounds, letter widths, bottom-row order
and landscape split; it restores size, density, night mode and rotation settings.
It selects the requested look through the production chooser and leaves it selected.
The dimensions approximate the reported Fold inner screen; these are emulator
layout checks, with hardware acceptance left to the operator.

## Notes library (Pond)

`notes-library-{cover,inner}-{state}-{light,dark}.png` are API 37 Robolectric native
renders of the production Notes-first shell at 411 × 891 dp (cover, navigation bar)
and 840 × 900 dp (inner, navigation rail and list/detail). States:

- `empty`: glyph and static rings, first-record guidance and local-storage line.
- `populated`: serif titles, relative times, two-line previews, duration and open tasks.
- `recording`: pinned Ripple card with frozen preview and tabular timer.
- `search` / `no-results`: local body/transcript search and highlighted matches.
- `recently-deleted`: restore controls and the 30-day explanation.
- `multi-select`: selected rows and bulk delete, while another note keeps recording.
- `detail`: the rendered document, Continue, and a jump back to the active recording.
- `transcript-sheet`: the actual modal sheet with per-segment playback controls.

`notes-library-wide-landscape-{light,dark}.png` additionally show the transcript as
a third pane at 1280 × 800 dp. Normal inner windows use a sheet to preserve reading
space. Motion is disabled for these review captures, so Ripple uses its static
accessibility treatment. `NotesScreenshots.kt` draws Material's separate sheet
window over the activity because it does not expose `DialogWindowProvider` to the
Robolectric PixelCopy helper.

Regenerate this set and the existing detail states deliberately:

```sh
./gradlew testDebugUnitTest -Pchirp.updateScreenshots \
  --tests '*NotesLibraryScreenTest*' --tests '*NotesRenderTest*'
```

The older `home-*` captures document the retired dashboard. The starting screen is
now Notes; `notes-{cover,inner}-*` remain detail/editor review states. All fixture
words and audio references are synthetic. Pixel renders do not establish codec
support; the emulator check separately exercises the real platform codecs.

The strengthened `emulator-check.py --notes-check` opts into kept audio on the
disposable emulator and requires a real MediaCodec AAC segment to prepare, start,
play for at least two seconds, and complete naturally through MediaPlayer. It
rejects decoder errors and keeps its output content-free. This change's real codec
run is **pending**: the shared emulator has not yet been released for validation.
The committed Robolectric renders and playback lifecycle tests are not codec
round-trip evidence.
