# Chirp

Local-first, English voice dictation for macOS and Android.

## Product direction

- Mac is the first server target: local speech recognition, with optional explicitly enabled remote correction handled by the Mac.
- Android: a full HeliBoard-based Chirp Keyboard for Samsung Galaxy Z Fold 8, with an integrated microphone that streams to the Mac over Tailscale and inserts text in the focused field.
- macOS should support dictation into the focused input across apps, with a practical copy/paste fallback where direct insertion is unavailable.
- No audio/transcript retention by default. An explicit local-only debug mode may retain data and must be clearly visible and controllable.
- English for v1. Optimize for responsive interaction and low Android battery use; measure latency and power rather than claiming unverified budgets.

## Development

The orchestrator coordinates feature branches/workers and integration. Keep the local repository as the integration point; use focused branches and tests. Never merge changes into `main` without the operator's explicit approval.

## Docs

- [Architecture](docs/architecture.md) — components, protocol, privacy, permissions, measurement plan, reuse decisions.
- [Milestones](docs/milestones/README.md) — M1 server, M2 macOS client, M3 Android IME, M4 integration.

## Android licensing

Chirp Keyboard combines GPL-3.0 HeliBoard code with Chirp's Android client. This is a
personal-use build; the corresponding source is available in this repository. Keep
upstream copyright and license notices intact. See [the pinned upstream record](android/keyboard/UPSTREAM.md)
and [Android setup/build instructions](android/README.md).
