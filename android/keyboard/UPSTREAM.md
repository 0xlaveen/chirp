# HeliBoard in Chirp Keyboard

Upstream: https://github.com/Helium314/HeliBoard (redirects to https://github.com/HeliBorg/HeliBoard).
Latest stable checked 2026-10-17: [v4.2](https://github.com/HeliBorg/HeliBoard/releases/tag/v4.2),
commit **0c60dffb03a4e2e7a37cb82210f5299f93c03979**.

`upstream/` is the complete release source archive at that commit, including upstream
build scripts, tests, dictionaries, notices and licenses. It is a vendored copy,
not a submodule; no remote is needed to build this local repository.

## Licenses

HeliBoard is GPL-3.0-only, with AOSP Apache-2.0 code and separately licensed assets.
Keep `upstream/LICENSE`, `upstream/LICENSE-Apache-2.0`, `upstream/LICENSE-CC-BY-SA-4.0`,
source SPDX/copyright headers, dictionary notices and upstream README intact.
The combined Android app is GPL-3.0; its corresponding source is in this repository.
This is a personal-use build. Any redistribution must include the applicable notices
and provide the corresponding source under the applicable license terms.

## Adapter and updates

`build.gradle.kts` builds the source as the `:keyboard` Android library with Chirp's
toolchain. `src/main/{java,res,assets}` are relative, in-repository symlinks into
`upstream/app/src/main`. Its manifest deliberately registers only internal HeliBoard
settings, emoji search and the clipboard provider. Chirp owns the single IME,
launcher, Application, signing and pairing. There is no second installed keyboard app.
Native code is built from source with NDK 28.0.13004108 for arm64-v8a and x86_64.
All upstream layouts, emoji and dictionaries remain bundled. Native symbols are stripped
and libraries compressed; R8 retains names and line numbers for useful diagnostics.
The host keep resource file preserves dynamically looked-up keyboard assets.

All source changes under `upstream/` are marked **CHIRP**:

- `latin/App.kt`: allow the host Application subclass to install diagnostics and seed defaults.
- `latin/define/DebugFlags.kt`: disable upstream crash reporter/debug flags. Its reporter includes messages and keyboard logs, which Chirp must not retain.
- `latin/utils/Log.kt`: disable keyboard logging to memory and logcat; host diagnostics are class/frame only.
- `latin/RichInputMethodManager.kt`: voice availability is in-process, independent of installed voice IMEs.
- `latin/InputView.java`: preserve strip touches instead of forwarding them to suggestion padding.
- `latin/LatinIME.java`: host mic touch/click hooks; include the strip in window touch/resize insets; prepare/resync typing state around dictation; consume voice events before external IME switching.
- `keyboard/KeyboardActionListenerImpl.kt`: forward voice press/release/cancel to the host; consume the matching code event to avoid double toggling.
- `settings/screens/MainSettingsScreen.kt`: link to Chirp setup/pairing.

Chirp's strip, dictation controller, capture, transport, protocol, pairing, crash log,
permissions and wizard live outside upstream. `patches/chirp.patch` records the upstream
delta against v4.2. To update, unpack the next stable archive into `upstream/`, reapply
that patch, review the CHIRP hooks, then run the full Android check and emulator script.
Do not run the upstream standalone application's build when producing Chirp APKs.

## Lint scope

AGP 9.4.1/Kotlin 2.4.21 lint crashes internally on upstream
`AccessibilityLongPressTimer.kt` (`findFirCompiledSymbol only works on compiled declarations`).
Only this vendored library's `lint*Analyze*` tasks are disabled. Library lint reports
remain available with `abortOnError=false`; Chirp app lint still runs with
`warningsAsErrors=true`. No app lint checks were relaxed. Upstream's standalone test
suite is retained unchanged; Chirp's Robolectric tests exercise the integrated keyboard
and its voice/editor lifecycle using the host toolchain.

Git attributes preserve upstream line endings and whitespace; the archive's existing
formatting is intentionally not normalized during vendoring.

## English typing and emoji dictionaries (2026-10-17)

Source: [Helium314/aosp-dictionaries](https://codeberg.org/Helium314/aosp-dictionaries),
pinned commit **ff0cd52be8d9530200fefe8b296c53d4f662091e**.
The repository declares GPL-3.0; its license is retained in
`dictionaries/LICENSE-Codeberg`. Source attribution is retained below and in
`dictionaries/SOURCES.md`.

| Packaged asset | Pinned upstream file | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| `keyboard/upstream/app/src/main/assets/dicts/main_en-US.dict` | `dictionaries/main_en_us.dict` | 2,956,881 | `bd950ef4b57655120eee65cee62a5d216a63f721d9a8bb759ce2022437840443` |
| `app/src/main/assets/dicts/emoji_en.dict` | `dictionaries/emoji_en.dict` | 45,272 | `23f95de30c79f828169233367343edd91e3fb486bef596127cb200959c2dc212` |

The main English US dictionary was already present in the HeliBoard archive and is
byte-for-byte identical to this pinned Codeberg binary. It includes 160,715 words and
bigrams, unlike several of the other legacy locale dictionaries. Its source record
points to [OpenBoard v1.4.5's English wordlist](https://github.com/openboard-team/openboard/blob/v1.4.5/dictionaries/en_wordlist.combined.gz).
No second copy or dictionary download is needed at runtime. The release smoke test
checks both packaged hashes and verifies actual HeliBoard autocorrection/prediction.

The added legacy English emoji dictionary has 2,304 entries. Codeberg records it as
adapted from [GitHub gemoji](https://github.com/github/gemoji/blob/master/db/emoji.json),
MIT, copyright 2019 GitHub, Inc. `dictionaries/LICENSE-gemoji` retains its complete
notice (license-file revision `16c382b7447bb080c5950f9c1fee0785de1e655e`).
We use this small dictionary rather than the newer CLDR/Signal combined dataset.

### Typing defaults and dictation isolation

The host's `TypingDefaults.kt` performs a one-time migration from voice-first defaults:
autocorrect (confidence 0.24), suggestions, next-word prediction, auto-capitalisation,
double-space period, press popups, symbol/accent hints, emoji suggestions and local
personalisation are enabled. Personalisation is disclosed in setup and can be disabled
in HeliBoard settings. Subsequent choices remain untouched. Typed-word learning stays
on-device. The dictation controller writes partials/finals directly through
`ComposingSession`, outside HeliBoard's correction/history pipeline, then resets the
keyboard word composer and caches. It does not feed dictated finals into local learning.

Additional CHIRP upstream changes in round 4:

- `latin/settings/SettingsValues.java`: default number row on screens at least 600 dp
  wide; explicit settings take precedence. Landscape split is seeded for unfolded
  layouts; the folded landscape preference remains off. One-handed, split, clipboard
  and emoji controls are enabled in the toolbar.
- `latin/AudioAndHapticFeedbackManager.java`: both custom-duration and default typing
  haptics obey Android's global haptic-feedback setting.
- `accessibility/KeyboardAccessibilityNodeProvider.kt`: refresh the keyboard's screen
  location for each virtual key, including after editor resize or folding.
- `latin/suggestions/SuggestionStripView.kt`: preserve native Chirp control gestures
  inside the suggestion row. `LatinIME` no longer adds an extra strip to its insets.
- `settings/screens/MainSettingsScreen.kt`: host Compose hook renders the Chirp section
  before HeliBoard preferences.

### Swipe typing

**Swipe typing: not available.** No proprietary `libjni_latinimegoogle.so` is bundled.
[HeliBoard's current README](https://github.com/HeliBorg/HeliBoard) says there is no
compatible open-source library; its [FAQ](https://github.com/HeliBorg/HeliBoard/wiki/FAQ)
describes loading an external compatible library. The open-source
[FlorisBoard](https://github.com/florisboard/florisboard) and
[Unexpected Keyboard](https://github.com/Julow/Unexpected-Keyboard) are separate IMEs,
not drop-in HeliBoard native decoders. Porting a different gesture engine and language
model is a separate integration project, not a viable release-ready replacement for
this pinned HeliBoard ABI. The funded [gesture-typing project](https://nlnet.nl/project/GestureTyping)
is future work, not a bundled compatible implementation in v4.2. Setup and the README
state the limitation explicitly. The release smoke also rejects a proprietary glide library.

- `keyboard/KeyboardLayoutSet.kt`: copy `mIsSplitKeyboardEnabled` into the layout/cache
  identity. Upstream 4.2 otherwise leaves `isSplitLayoutEnabled` false even when the
  preference is enabled. A native-render regression and release landscape key geometry
  check cover the fix.
