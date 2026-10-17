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
