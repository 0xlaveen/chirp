# Site: shipped features, October 27, 2026

Site-only follow-up to [#271](https://github.com/araa47/chirp/issues/271), including its A2 audit, and [#287](https://github.com/araa47/chirp/issues/287). The branch starts at `origin/main` `680d7be6`. The audit issues describe gaps at an earlier commit; shipped claims below were checked against this checkout's code, not inferred from the plan.

The homepage, architecture and Mac, Android, iPhone/iPad and Notes guides explain the recent features. The changelog links their merged PRs. Get Chirp and the Windows/Linux guides have only small glossary changes. No app code, shared glossary, root README or screenshot source PNG changed.

## Claim checks

| Site claim | Current implementation checked |
| --- | --- |
| Labels default on for Mac, iOS and Android; Name speakers; shared saved voices | Client READMEs; [Mac speakers](../../../mac/Sources/ChirpCore/Speakers.swift), [iOS speaker UI](../../../ios/App/SpeakerViews.swift), [Android speaker UI](../../../android/app/src/main/java/dev/chirp/android/NotesSpeakerUi.kt), [server voice library](../../../server/src/chirp_server/speakers.py); [privacy](../../privacy.md) |
| Mac diarization uses on-device Sortformer; phones use server WeSpeaker; saved recognition uses one server library | [Sortformer](../../../mac/Sources/ChirpSpeakers/SortformerSpeakers.swift), [server architecture](../../architecture.md#saved-voices-v1-compatible-addition-issue-247), current client READMEs |
| “This turn is…” on Mac and Android; iOS still missing | [Mac menu](../../../mac/Sources/ChirpUI/SpeakerMenu.swift), [Android menu](../../../android/app/src/main/java/dev/chirp/android/NotesSpeakerUi.kt), [iOS menu](../../../ios/App/SpeakerViews.swift) |
| Re-transcribe on Mac and Android, consent every run, own server, debug-retention exception, Undo/Restore; iOS in progress | [Mac README](../../../mac/README.md#live-notes), [Android README](../../../android/README.md#notes), [iOS Notes UI](../../../ios/App/LiveNotesView.swift), [protocol](../../architecture.md#notes-re-transcription-v1-compatible-addition-issue-287-s), [privacy](../../privacy.md) |
| Learn from my edits / Teach Chirp / Learned on all three; iOS vocabulary only, no per-app style | [Mac learning](../../../mac/Sources/ChirpCore/LearnFromEdits.swift), [Android learning](../../../android/app/src/main/java/dev/chirp/android/LearnFromEdits.kt), [iOS sealed learned store](../../../ios/Shared/Sources/ChirpIOSCore/Learned.swift), [iOS controls and copy](../../../ios/App/Settings/LearnedViews.swift), [keyboard watcher](../../../ios/Keyboard/ChirpKeyboardViewController.swift) |
| Temporary Private session on Mac/Android; persistent Pause dictation history on iOS, including learning/context gate | [Mac lifetime](../../../mac/Sources/ChirpCore/PrivateSession.swift), [Android settings](../../../android/app/src/main/java/dev/chirp/android/SettingsStore.kt), [iOS settings](../../../ios/App/Settings/SettingsPages.swift), [iOS learning gate](../../../ios/Shared/Sources/ChirpIOSCore/Learned.swift) |
| About 10-minute rolling Mac dictation, spoken line breaks on Mac/Android/iOS keyboard, stop on pause | [Mac rolling policy](../../../mac/Sources/ChirpCore/RollingDictation.swift), [Mac controller](../../../mac/Sources/ChirpMac/DictationController.swift), client READMEs, [iOS stop controls](../../../ios/App/Settings/LearnedViews.swift); desktop has no spoken commands |
| iPad Right Option hold inside Chirp; toggle-only through Shortcuts + Full Keyboard Access elsewhere; typing keyboard row | [iOS README](../../../ios/README.md#dictate-from-any-app-keyboard), [hardware shortcut](../../../ios/App/HardwareShortcut.swift), [keyboard controller](../../../ios/Keyboard/ChirpKeyboardViewController.swift) |
| Notes actions in Shortcuts/Control Center | [Notes intents](../../../ios/Intents/NotesIntents.swift), [shortcut registration](../../../ios/Intents/SessionIntents.swift), [controls](../../../ios/Widgets/ChirpWidgets.swift) |
| Blank typed New note on Mac/Android; also present on desktop, still missing in iOS library | [Mac README](../../../mac/README.md#live-notes), [Android README](../../../android/README.md#notes), [desktop README](../../../desktop/README.md#notes-library), [iOS library](../../../ios/App/NotesLibraryView.swift) |

The glossary is [docs/copy.md](../../copy.md). Speaker recognition is fallible. Features are source-build capabilities, not promises of packaged downloads or hardware acceptance.

## Comparison research

Official pages were revisited in ego-browser on October 27, 2026: [Superwhisper](https://superwhisper.com/) and its [offline explanation](https://superwhisper.com/offline-transcription), [Wispr pricing/platforms](https://wisprflow.ai/pricing), [Typeless pricing](https://www.typeless.com/pricing), [platforms](https://www.typeless.com/) and [privacy](https://www.typeless.com/privacy), [OpenWhispr](https://openwhispr.com/), [MacWhisper](https://www.macwhisper.com/) and its [Mac/iOS edition comparison](https://docs.macwhisper.com/article/40-macwhisper-whisper-transcription-difference).

The new comparison rows leave competitor cells as a dash (“Not compared”), rather than asserting a missing feature. Existing uncertain meeting/speaker/cross-device cells also leave the claim out. The hero no longer implies that Superwhisper requires cloud speech processing. Wispr displayed region-specific pricing, so the old fixed USD quote was removed. Whisper is explicitly a model, with capabilities determined by the app around it. No controlled cross-product performance or accuracy claim is made.

## Validation

- `python3 site/build.py --out /tmp/chirp-site-refresh-site`: 13 pages, 58 source screenshots, 5.25 MB. Links, privacy, SEO and image budgets pass.
- `CHIRP_SITE_TEST_OUTPUT=/tmp/chirp-site-refresh-site python3 -m unittest discover -s site -p 'test_*.py'`: all 8 guardrail tests pass. This is the full local website path in `.github/workflows/pages.yml`; no app gates apply to this site/docs-only change.
- `uv run --with pillow python site/prepare_images.py`: no asset changes. The Notes guide reuses the existing light/dark Re-transcribe consent images already prepared for Architecture.
- [Browser measurements](browser.json): 10 changed pages × 1440/834/390 CSS pixels × light/dark = 60 cases, with no document overflow or broken loaded images. True CDP viewport overrides, scale 1; the browser's normal scrollbar accounts for the smaller document width. All changed pages were visually reviewed in both themes at 1440 and 390, including full-page overviews and focused sections. Narrow full-page overviews use reduced capture scale to stay within the browser's image-height limit; viewport captures retain CSS pixel size.
- [Keyboard interaction](interaction.json): Skip to content focuses main; the comparison region accepts keyboard focus and scrolls horizontally with ArrowRight.
- `git diff --check` passes. Site CSS, JavaScript, dependencies and app source screenshots are unchanged.

### Lighthouse 13.5.0

Same local static server, Chrome and Lighthouse, default simulated mobile throttling. These are single-run lab observations, not field measurements. Reports are summarized in [scores.json](scores.json).

| Metric | Home before | Home after | Architecture before | Architecture after |
| --- | ---: | ---: | ---: | ---: |
| Performance | 95 | 95 | 99 | 98 |
| Accessibility | 100 | 100 | 100 | 100 |
| Best practices | 100 | 100 | 100 | 100 |
| SEO | 100 | 100 | 100 | 100 |
| LCP (ms) | 2,852 | 2,852 | 2,252 | 2,251 |
| CLS | 0 | 0 | 0 | 0 |

### Representative captures

[Homepage features, desktop light](home-features-1440-light.webp) · [Homepage features, phone dark](home-features-390-dark.webp) · [Architecture speakers, desktop dark](architecture-speakers-1440-dark.webp) · [Re-transcribe guide, phone light](notes-retranscribe-390-light.webp) · [iOS learning, phone dark](iphone-learning-390-dark.webp).
