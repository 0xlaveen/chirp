# M1: Mac speech server (`chirp/server`)

Goal: `server/` is a uv-managed Python 3.13 package, `chirp_server`, that serves the v1 protocol ([architecture §3](../architecture.md)) with real streaming partials from local Parakeet on this M5 Pro, as fast as the hardware allows.

## Scope

1. **Project:** `server/pyproject.toml` (uv, hatchling), a console script `chirp-server`, and `ruff` + `pytest` config.
   - Dependencies: `starlette`, `uvicorn[standard]`, `parakeet-mlx` (latest; Koi uses 0.5.2), `mlx`, `numpy`, `httpx` (for correction).
   - Optional extra `onnx`: `onnx-asr`, `onnxruntime`.
   - Use the latest stable versions and lock them in `uv.lock`.
2. **Engine layer** (`engine/`):
   - The `Engine` protocol: `load()`, `transcribe(pcm: np.ndarray) -> str`, and a streaming session API `open_stream() -> StreamSession` with `feed(pcm) -> partial | None` and `finish() -> final`.
   - Implementations:
     - `ParakeetMLX`, the default. **All MLX calls run on one dedicated thread**, the one that loaded the model (Koi PR #3595 lesson). The asyncio side talks to it through a queue/future.
     - `ParakeetONNX` (fallback)
     - `FakeEngine` (tests)
   - Model discovery:
     1. `--model-dir`
     2. `~/.koi/voice-models/parakeet-mlx` (already holds TDT 0.6B v2; verify `config.json`)
     3. `~/Library/Application Support/Chirp/models/`
     - `chirp-server model fetch` downloads `mlx-community/parakeet-tdt-0.6b-v2` (check Hugging Face for the newest English Parakeet MLX conversion and note it in bench.md) with a pinned revision.
   - Warm the model at start-up with a short silent decode, so the first utterance is not cold.
   - Consider bf16/fp16 weights if parakeet-mlx supports them; Koi's cached safetensors are 2.3 GB, which suggests fp32. Measure the speed and accuracy before switching the default.
3. **Streaming:**
   - Implement partials using parakeet-mlx's streaming API (`transcribe_stream` / context cache, as available in the installed version). Fall back to re-decoding a rolling window.
   - Partials go out at most every ~150–250 ms of new audio. The `stable` field carries the prefix that will not change.
   - `stop` produces the best-quality final. A full-utterance decode is fine up to the model's comfortable length; beyond that, use chunk + stitch (see Koi `voice/stitch.py`).
   - Include Koi-style silence detection, using peak/RMS in the logs.
4. **Server** (`app.py`, Starlette):
   - Routes: `GET /v1/health`, `POST /v1/transcribe` (16 kHz mono PCM16 WAV; reuse or adapt Koi `voice/wav.py`), `WS /v1/stream`.
   - Bind to `127.0.0.1:7821` by default. `--root-path /chirp` serves behind `tailscale serve`.
   - Auth: a bearer header, or the first `auth` frame on the WS. Compare tokens in constant time. The token lives in `~/.config/chirp/token` (0600) and is generated on first run.
   - `chirp-server pair --url https://mainframe.tail676ff2.ts.net/chirp` prints the `chirp://pair?...` string plus a terminal QR code (`qrcode` or `segno`).
   - Limits: one engine with a queue, 120 s max, and the error codes from the protocol. Log `Tailscale-User-Login` presence (not the value) for diagnostics.
5. **Correction** (`correction.py`):
   - Port the Koi `voice/cleanup.py` behaviour: an OpenAI-compatible chat endpoint, Koi's prompt adapted for dictation into arbitrary text fields, timeout, and fallback to raw on timeout, HTTP error, empty output or answer-shaped output.
   - It runs on the final only, and only when the server config enables it **and** the client's `start.correction` is true.
   - Config lives in `~/.config/chirp/server.toml` `[correction]`. The API key comes from an env var or the Keychain (`security find-generic-password`), never from the file.
   - Health reports `correction_leaves_machine`.
6. **Privacy:**
   - No-retention default: audio and transcripts are never written anywhere.
   - Opt-in debug retention follows [architecture §4](../architecture.md): visible flags, a 0700 directory, purge after N days, and `chirp-server debug purge`.
   - Tests prove the default writes no files under HOME or the temp dir during a session, and that the logs never contain the transcript.
7. **Run as a service (documented, not installed):** `server/launchd/dev.chirp.server.plist` plus `chirp-server service install|uninstall` (user LaunchAgent). Do not install it yourself; M4 decides.
8. **Bench** (`server/scripts/bench.py`, output in `docs/bench.md`):
   - Engines: parakeet-mlx (fp32 and reduced precision if available), onnx-asr int8. Also benchmark FluidAudio (Swift CLI, ANE) and Apple SpeechAnalyzer if they can be driven from a small CLI without Xcode. If not, record why.
   - Metrics: load time, warm RTFx, WER on a small fixture set, peak RSS, first-partial latency, partial cadence, stop→final latency (5/15/60 s clips).
   - Commit the generator for `say`-based fixtures, not big WAVs. Small (<200 KB) WAV fixtures are OK.
   - State the conclusion and the chosen default.
9. **Tests:**
   - `uv run pytest`: protocol (with `FakeEngine`), auth, limits, retention and correction fallback (with a mock HTTP server).
   - `uv run pytest -m model`: the real model on fixtures.
   - `server/tests/client_sim.py`: a CLI that streams a WAV over the WS at real-time pace and prints partials and timings. M2, M3 and M4 use it.

## Acceptance

- `cd server && uv sync && uv run pytest` passes. `uv run pytest -m model` passes on this Mac.
- `uv run chirp-server` starts in under a few seconds once the model is cached. `uv run python tests/client_sim.py fixtures/<clip>.wav` shows live partials and an accurate final.
- `docs/bench.md` has real numbers from this M5 Pro and a justified engine choice.
- `server/README.md` covers commands, config, privacy and the debug mode.
