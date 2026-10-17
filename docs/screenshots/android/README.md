# Android UI review renders

All displayed speech is a generated synthetic fixture. No user speech, real pairing
credential or personal text is included.

- `keyboard-{idle,listening,final}-{light,dark}.png`: Robolectric native graphics on
  API 37, actual HeliBoard QWERTY keys with Chirp's production strip at 411 px width.
  Final fixtures show the five-second raw chip. These render deterministic UI states.
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
