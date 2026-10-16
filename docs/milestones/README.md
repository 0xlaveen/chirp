# Milestones

| ID | Track | Branch | Spec |
|---|---|---|---|
| M1 | Mac speech server (engine, streaming, correction, privacy, bench) | `chirp/server` | [M1-server.md](M1-server.md) |
| M2 | macOS dictation client (menu bar, hotkey, HUD, insertion) | `chirp/mac` | [M2-mac.md](M2-mac.md) |
| M3 | Android voice IME for Galaxy Z Fold 8 | `chirp/android` | [M3-android.md](M3-android.md) |
| M4 | Integration: tailscale serve, end-to-end tests, operator docs, bench numbers | `chirp/integration` | [M4-integration.md](M4-integration.md) |

M1, M2 and M3 run in parallel against the frozen protocol in [architecture §3](../architecture.md#3-wire-protocol-v1-frozen-for-parallel-work). M4 runs after they merge into `chirp/integration`.

## Rules for every worker

- Read `docs/architecture.md` first. It holds the decisions, the protocol and the privacy rules, and none of them is optional.
- Reuse before writing. Koi's installed voice stack is the reference implementation: `~/.local/bin/.koi-upgrades/generation-*/tools/koi/lib/python3.13/site-packages/koi/voice/`, `koi/ui/routes_voice.py` and `koi/tailscale*.py`, plus the browser capture code in `nansen-ai/koi:ui/src/studio/chat/voiceRecorder.ts` (read it with `gh api`). Adapt patterns and code. Do not add Koi as a dependency.
- Prefer maintained libraries and system APIs. Use the latest stable versions. Before writing glue code, check whether a library already does the job.
- Privacy:
  - Never write audio or transcripts to disk or logs outside the opt-in debug-retention path.
  - Never commit secrets, tokens, recordings or personal transcripts.
  - Test fixtures are synthetic: macOS `say` output or public-domain corpora.
- This repo is local-only:
  - Never add a git remote, push or open a PR.
  - Commit on your own branch with clear messages. Do not touch `main` or `chirp/integration`.
  - When you finish, run `koi report --kind done` with the branch, head SHA, what works, the test commands and any blockers.
- Do not start persistent services, launch agents or `tailscale serve` changes on this Mac without saying so in your report. Short-lived test servers on 127.0.0.1 are fine.
- Waiting on long builds or tests: use `koi run -- …` and end your turn.
