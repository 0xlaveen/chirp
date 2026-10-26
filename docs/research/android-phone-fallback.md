# Android: recognising on the phone when the computer is unavailable

Issue #41. Away from the computer (asleep, travelling, no tailnet), Chirp Keyboard could not dictate at all. This note records what the prototype ships and evaluates a bundled model as a later option.

## What ships (prototype, off by default)

Chirp settings → **When your computer is unavailable → Use this phone's recogniser**. It is off by default and disabled when `SpeechRecognizer.isOnDeviceRecognitionAvailable` is false.

- **When it runs.** The computer must be *known* unreachable: the offline mark from a failed health check or prewarm (#52, 30 s window), Tailscale off for a tailnet pairing, or a dictation attempt that failed **before anything was heard** for a reachability reason (DNS, connect timeout/refused, no Ready within 7 s, generic transport failure). A TLS failure means the computer answered, so it never hands over. If the computer heard something, keep-heard-text (#47) still commits it and the phone does not take over.
- **What it does.** One utterance through `SpeechRecognizer.createOnDeviceSpeechRecognizer` (API 31+, `EXTRA_PREFER_OFFLINE`, partial results). Partials compose underlined like the computer's; the final is inserted raw. There is no clean-up and no Use raw; Undo, spoken commands, mid-sentence casing and history (when on) behave as for a computer final. A recogniser error after partials keeps what was heard. Stop waits at most 5 s for the result, then keeps what was heard.
- **Disclosure.** The status reads **Listening on phone…** (or **Computer unavailable · listening on phone** after a hand-over), and an **on phone** chip stays visible until the notice clears. TalkBack reads the chip as "Recognised on this phone by *provider*, not your computer". The provider is the app label of the system's default on-device recognition service when Android lets Chirp see it (for example Android System Intelligence on Pixel, or Samsung's speech service on Galaxy). Otherwise the chip says "the phone's own speech service". Chirp never calls it Chirp's own engine.
- **Privacy.** Android documents the on-device recogniser as recognising locally. It is still a third-party system service under its own terms, and Chirp cannot audit what it retains. Chirp keeps nothing extra: no audio, no text in logs or diagnostics, no session timing for phone utterances.
- **Pause handling.** Platform recognisers end an utterance on silence on their own. In *When I pause* mode Chirp passes the chosen pause as `EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS`, which services may ignore.
- **Code.** `PhoneRecognizer.kt` holds the recogniser wrapper (`AndroidPhoneRecognizer`), the utterance lifecycle (`PhoneDictation`), the decision (`PhoneFallback`) and the setting. `KeyboardDictation` treats it as another `Utterance`, so ✕, hide, field changes, caret moves and typing release the microphone exactly as for the computer. Tests: `PhoneFallbackTest` (fake recogniser).

Not verified on a real device in this change: availability on the operator's Galaxy Z Fold, the Samsung/Google provider label, language-pack prompts, and microphone hand-off timing between Chirp's `AudioRecord` and the speech service after a failed attempt.

## Later option: a bundled ONNX model (sherpa-onnx)

[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) runs ONNX speech models on Android through JNI with onnxruntime. It would make Chirp's offline path independent of the phone maker's speech service and identical on every device.

| | Platform on-device recogniser (shipped) | sherpa-onnx bundled model |
|---|---|---|
| APK / download size | 0 MB | onnxruntime + JNI ≈ 15–20 MB per ABI, plus the model. Streaming English zipformer transducers are roughly 20–70 MB int8. Non-streaming Whisper tiny/base or Moonshine models are a similar order. Figures are approximate and need measuring on our arm64 split. |
| Quality | Vendor-tuned and usually good for short dictation, but it varies by phone and language pack | Small streaming models trail Parakeet TDT 0.6B on the computer, especially on names and long-form speech. Expect noticeably more errors than the computer. Run the bench WAV set from `docs/bench.md` before choosing a model. |
| Latency / streaming | Native partials | Streaming zipformer gives true partials. Whisper/Moonshine are non-streaming, so we would need to re-decode a growing buffer, as the server's rolling windows do. |
| Battery / thermals | Vendor-optimised (often NPU/DSP) | CPU inference on big cores while listening. A modern arm64 phone should run it faster than real time, but this is unmeasured. It needs a `scripts/battery-session.sh` run on the Fold. |
| Privacy | Third-party system service; Chirp cannot audit it | Fully under Chirp's control; audio never leaves the process |
| Engineering | Small wrapper | Native libraries must pass the 16 KB page-alignment gate (`check<Build>Native16kAlignment`). We would also need model download/integrity checks and a JNI lifecycle tied to the IME. |

**Recommendation.** Keep the platform recogniser as the opt-in prototype. If operators use it, evaluate a sherpa-onnx streaming zipformer (int8, English) as an **optional download** rather than a bundled default, to keep the base APK small. The paired computer could serve the model over the existing authenticated connection while it is reachable. Measure WER on the bench set, RTF and first-partial latency on the Fold, battery over a 10-minute session, and 16 KB alignment of the prebuilt `.so` files before committing to it.
