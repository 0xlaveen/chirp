# Chirp server

Python 3.13, Starlette and local Parakeet MLX on Apple Silicon. The server binds only to
`127.0.0.1:7821`. No service, network publication or model download happens on installation.

```sh
cd server
uv sync --locked
uv run chirp-server
```

The cached English TDT v2 model at `~/.koi/voice-models/parakeet-mlx` is validated and reused.
Otherwise explicitly run `uv run chirp-server model fetch` (pinned Hugging Face revision).
`--model-dir /path/to/model` takes precedence. Startup loads and silently warms the model
on the same dedicated thread used for every decode and streaming-context operation.

```sh
uv run chirp-server --root-path /chirp
uv run chirp-server pair --url https://mainframe.tail676ff2.ts.net/chirp
uv sync --locked --extra onnx
uv run chirp-server --engine onnx
uv run chirp-server model fetch --engine onnx
```

Pair prints a **secret** URI and terminal QR locally. Do not paste it into logs or chat.
The generated bearer token is `~/.config/chirp/token`, mode 0600. HTTP and WS authentication
share a constant-time comparison. A browser WS can send `{"type":"auth","token":"…"}` as its
first frame instead of an Authorization header. Audio is rejected before authentication.
Unauthenticated health deliberately reports only `{"ok":true}`; authenticated health exposes
readiness, retention and correction information. See [the protocol](../docs/architecture.md#3-wire-protocol-v1-frozen-for-parallel-work).

One model processes one utterance at a time. Requests wait up to 10 seconds before `busy`.
A socket supports sequential utterances and closes after 60 seconds without client traffic.
PCM must be mono, little-endian signed 16-bit at 16 kHz. Frames of 1 MB or more are rejected;
utterances are capped at 120 seconds. POST accepts a WAV body with the same format and limit.
Incremental partials consume roughly 200 ms of new audio at a time, coalescing work if inference
lags behind capture. The final restores full attention and decodes the complete utterance;
over 30 seconds it merges overlapping, timestamped chunks. `stable` is conservatively empty
because the authoritative final may revise any word. Silence produces no hallucinated final.
`--streaming rolling` benchmarks the fallback and `--precision float16|bfloat16` enables experiments.

## Config and correction

Optional `~/.config/chirp/server.toml` (or `--config /path/to/server.toml`):

```toml
[correction]
enabled = false
base_url = "http://127.0.0.1:1234/v1"
model = "your-loaded-model"
timeout = 8.0
api_key_env = "CHIRP_LLM_API_KEY"
# keychain_service = "chirp-llm" # security find-generic-password -s SERVICE -w
# prompt = "Custom transcript cleanup prompt"

[debug]
retain = false
retain_days = 3
```

Correction requires both server `enabled=true` and the client's `start.correction=true`.
Only the final transcript is submitted. The raw transcript is always returned for undo;
timeouts, HTTP failures, empty/truncated/answer-shaped output return the raw text safely.
API keys come from the named environment variable or Keychain, never the TOML file.
Enabled external correction reports `correction_leaves_machine=true` and `correction_host`
so clients can label the destination. POST uses raw decoding (no client correction request).

## Privacy and debugging

Audio and text stay in memory and are discarded on stop/cancel/disconnect. No recording,
transcript, temporary WAV, or transcript log is written by default. Diagnostics contain only
random session IDs, byte counts, signal levels, timings and safe error codes. Access logging
is disabled. The simulator likewise prints counts and timings unless `--show-text` is explicit.

`uv run chirp-server --debug-retain` or `[debug] retain=true` explicitly opts into local files:
`~/Library/Application Support/Chirp/debug/<session>.wav` and `.json`, modes 0700/0600.
Startup logs a warning, and authenticated health plus every WS ready frame expose the flag.
Files expire after three days by default and purge at startup and hourly while enabled.
Cancelled utterances are discarded even in debug mode.

```sh
uv run chirp-server debug purge
```

## Validation and benchmarks

```sh
uv run ruff check .
uv run ruff format --check .
uv run pytest
uv run pytest -m model
uv run python scripts/generate_fixtures.py
uv run python tests/client_sim.py "$HOME/Library/Caches/Chirp/fixtures/synthetic-5s.wav"
uv run python scripts/bench.py --output "$HOME/Library/Caches/Chirp/bench.json"
```

The simulator streams 50 ms frames at real-time pace and prints partial arrival counts and final
timings; `--show-text` is for synthetic/public fixtures in an unrecorded local terminal only.
Model tests generate Samantha `say` fixtures outside the repository, never capture a microphone,
and check keywords without including recognized text in assertion output.
The benchmark reports load plus warmup, median of three warm decodes, WER, peak process RSS,
first partial, changed-partial cadence and stop-to-final latency for nominal 5/15/60 second clips.
Fixtures contain complete synthetic sentences, so actual durations differ slightly. Results and
hardware/load caveats are in [bench.md](../docs/bench.md).

## Optional LaunchAgent (operator action)

A reference plist is in `launchd/dev.chirp.server.plist`. Only when the operator chooses:

```sh
uv run chirp-server service install
uv run chirp-server service uninstall
```

Install renders the current virtual environment's absolute Python path and bootstraps a user
LaunchAgent. Keep this checkout and virtual environment in place while installed. Output goes
to `/dev/null`; run in a terminal for metadata diagnostics or visible debug warnings. Debug
retention is also always visible in the health/ready flags. Installation has **not** been run.
Tailnet publication is managed by integration; this package does not change Tailscale settings.
