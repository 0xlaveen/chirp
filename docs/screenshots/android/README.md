# Android UI review renders

22 PNGs rendered from the app's actual shared Material 3 `VoicePanel` and Compose `SetupWizard` using Robolectric's native graphics at API 37. All text is a synthetic review fixture; no microphone, phone, real pairing, or transcript is used. The set is below 2 MB.

- `panel-{idle,connecting,listening,finalizing,error,raw,debug}-{light,dark}.png`: the shared panel; listening uses a 700 px inner-screen width, other states a 360 px cover-screen width. These render the shared view with review controls. IME-specific editing keys/settings and the floating bubble are additionally covered by service tests.
- `setup-{1,2,3,4}-{light,dark}.png`: wizard screen viewports at 411 × 891 px. Longer content scrolls; these show the initial viewport, not a fabricated full-page layout.

Regenerate from `android/` with `./gradlew testDebugUnitTest --tests '*VoiceUiTest*' --rerun-tasks`. The test task passes an absolute repository output path, so it does not depend on the working directory. Full verification remains `./gradlew lint testDebugUnitTest assembleDebug assembleRelease`.

These are rendered review artifacts, not pixel-golden assertions or evidence of One UI behavior on hardware. Font scaling, rotation, folding, Samsung app-ops/FGS enforcement, and editor-specific accessibility behavior still need the operator's phone acceptance run in `docs/android-input-options.md`.
