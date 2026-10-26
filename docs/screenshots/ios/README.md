# iPhone and iPad screenshots

All displayed speech is a generated synthetic fixture. No user speech, real pairing credential or personal text is included. Captures come from the iOS simulator UI tests and the debug fixtures (`ios/scripts/simulator.sh`, `ios/README.md`). The website's copies are derived from these by `site/prepare_images.py`.

Naming: `iphone-…` and `ipad-…` are the device; a `-dark` suffix (or `iphone-dark-…` / `ipad-dark-…` prefix) is the dark appearance and a bare name is light; `-ax5` is the largest accessibility text size. The `notes-…` family (saved voices and speaker naming) is named `-{light,dark}-{iphone,ipad}`.

## Current

- `iphone-dictate-*`, `iphone-dark-dictate-*`, `iphone-ax5-dictate-*`, `iphone-landscape-dictate-finished-{light,dark}.png`, `iphone-reduce-motion-dictate-listening.png`, `ipad-dictate-listening.png`, `ipad-dark-dictate-listening.png`: the Dictate tab (idle, listening, finished with Copy, Share and Use raw).
- `iphone-notes-*`, `ipad-notes-*`: the Notes library (groups, recording row, Recently Deleted, search, empty, the setup card), a note open for reading and editing, the transcript, kept-audio replay, and the recording dock at AX5.
- `iphone-speakers-{transcript,merged}-*`, `iphone-speakers-settings-light.png`, `ipad-speakers-settings-light.png`, `notes-speakers-*`: speaker chips, merging, the Name speakers line and sheet (with **Remember voice**), and Notes → Speakers settings.
- `notes-saved-voices-*`, `notes-voices-recognised-*`: Settings → Notes → **Saved voices** (the library on your Chirp server, shared by every device) and a recognised voice (✓ on the chip).
- `iphone-history-{list,detail}-*`, `iphone-history-empty-light.png`, `iphone-history-list-ax5.png`, `ipad-history-*`: Dictation history (off until you turn it on).
- `iphone-keyboard-*`, `ipad-keyboard-*`: Chirp Keyboard in each state (armed, listening, polishing, finished, error, no session, info, debug, system keyboard). The top row is Chirp's state row, the same height in every state.
- `iphone-settings-*`, `ipad-settings-*`: the Settings pages (home, Connection, Dictation, Keyboard, the style prompt editor).
- `iphone-onboarding-*`, `iphone-dark-onboarding-*`, `iphone-ax5-onboarding-*`, `ipad-onboarding-1-welcome.png`, `ipad-dark-onboarding-1-welcome.png`: first run (welcome, pair, microphone, keyboard).
- `ipad-sidebar-*`, `ipad-dark-sidebar-*`: the iPad sidebar (Notes, Dictate, History, Settings) expanded and collapsed.
- `iphone-session-capsule.png`, `iphone-dark-session-capsule.png`, `iphone-live-activity-*`, `iphone-dynamic-island-*`: the armed-session capsule, Live Activities and Dynamic Island (`.jpg`).
- `strip-compare-*`: Chirp Keyboard's top row beside Android's keyboard strip, for each device and appearance.

## Out of date

These are kept as evidence and are not current parity coverage. The audit behind this list is araa47/chirp#271 (§3.3, A2-15).

- `iphone-live-notes-stopped-2026-10-25.png`, `ipad-live-notes-stopped-2026-10-25.png`: the earlier five-tab app.
- `iphone-history.png`: the earlier History tab.
- `iphone-landscape-dictate-finished-before.png`: a before capture.
- `iphone-speakers-consent-live.png`, `iphone-speakers-renamed-live.png`, `iphone-speakers-two-people-live.png`: a run from before speaker labels were on by default, including the download-consent alert that no longer exists.
- Captures that still say "Mac" for the paired server (before the "your computer" wording) are being regenerated; the app text is the source of truth.
