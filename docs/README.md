# Chirp documentation

Index of everything under `docs/`. Start with the architecture doc; everything else branches from it.

| Document | What it holds |
|---|---|
| [architecture.md](architecture.md) | The v1 shape: components, frozen wire protocol, privacy and retention rules, permissions, measurement plan, reuse decisions |
| [bench.md](bench.md) | Measured results on the M5 Pro: engines, finalization modes, cleanup models and profiles, prewarm/keep_loaded memory and latency |
| [TESTING.md](TESTING.md) | How Chirp is tested: automated checks, operator acceptance steps, privacy checks |
| [android-input-options.md](android-input-options.md) | Research record: Android input paths considered (voice IME, RecognitionService, accessibility overlay) and what ships |
| [android-keyboard-validation.md](android-keyboard-validation.md) | Chirp Keyboard 0.3.0 validation record |
| [milestones/](milestones/README.md) | M1 server, M2 macOS client, M3 Android IME, M4 integration, M5 iOS — specs and worker rules |
| [review/ios-foundation.md](review/ios-foundation.md) | iOS foundation evidence: portable ChirpCore + shared package, macOS-CLT test results, pending Xcode/device gates |
| [review/ios-keyboard.md](review/ios-keyboard.md) | iOS keyboard, intents and Live Activity evidence: insertion-safety tests, fake-host validation, pending simulator/runtime acceptance |
| [review/round2.md](review/round2.md) | Independent review, round 2 (findings and evidence) |
| [review/word-waveform.md](review/word-waveform.md) | Design notes for the Mac word-waveform HUD overlay: shipped variant, rejected alternatives, protocol and latency benchmarks |
| [screenshots/](screenshots/) | UI captures: [mac](screenshots/mac/) (curated light/dark snapshots) and [android](screenshots/android/) (described in its [README](screenshots/android/README.md)) |
| [bench-data/](bench-data/) | Committed numeric benchmark results (no audio or transcripts) |
| [assets/](assets/) | Resized artwork used by the top-level README |

Component READMEs live with their code: [server/README.md](../server/README.md), [mac/README.md](../mac/README.md), [android/README.md](../android/README.md) and [ios/README.md](../ios/README.md) (install, usage, privacy and current blockers for the iPhone/iPad client). The cross-component end-to-end check is [scripts/e2e-local.sh](../scripts/e2e-local.sh) (see [TESTING.md](TESTING.md)).
