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
uv run chirp-server --root-path /chirp   # serves /chirp/v1/... and /v1/..., so Tailscale Serve may strip the mount point or not
uv run chirp-server pair --url https://mainframe.tail676ff2.ts.net/chirp
uv sync --locked --extra onnx
uv run --extra onnx chirp-server --engine onnx
uv run chirp-server model fetch --engine onnx
```

Pair prints a **secret** URI and terminal QR locally. Do not paste it into logs or chat.
The generated bearer token is `~/.config/chirp/token`, mode 0600. HTTP and WS authentication
share a constant-time comparison. A browser WS can send `{"type":"auth","token":"…"}` as its
first frame instead of an Authorization header. Audio is rejected before authentication.
Unauthenticated health deliberately reports only `{"ok":true}`; authenticated health exposes
readiness, retention and correction information. See [the protocol](../docs/architecture.md#3-wire-protocol-v1-frozen-for-parallel-work).

One model processes one utterance at a time. Requests wait up to 10 seconds before `busy`.
First-frame authentication has a separate five-second deadline; at most eight sockets may
await credentials concurrently. A socket supports sequential utterances and closes after 60 seconds without client traffic.
PCM must be mono, little-endian signed 16-bit at 16 kHz. Frames of 1 MB or more are rejected;
utterances are capped at 120 seconds. POST accepts a WAV body with the same format and limit.
Cancel or disconnect during finalization discards the utterance: no correction request (an
in-flight one is cancelled) and nothing retained. A cancelled utterance delivers no final and
no error acknowledgement; the socket stays usable for the next start.
Rolling partials consume roughly 200 ms of new audio at a time, coalescing up to two seconds
per inference when the engine lags. MLX previews decode an eight-second window and reuse the
library's timestamped token merger to retain the whole live transcript. The default final
performs a full-utterance decode, using overlapping 30-second chunks for
long utterances. At stop, queued partial inference is skipped and its audio is buffered directly
for the final. `stable` is deliberately empty in this mode because the full final can revise any
word. Silence produces no hallucinated final. `--finalization segments` explicitly enables pause
precommit: after at least 400 ms of low signal, full-decode and freeze the preceding segment,
then decode only the remaining tail at stop. Its `stable` contains frozen segments (suppressed
when final correction can revise them). Both modes matched full-decode WER on the measured
continuous and controlled-pause fixtures, but segment mode regressed the short continuous
fixture's paired median final latency, so it remains opt-in. `--streaming incremental` uses
upstream's documented cached
context and one-second chunks, with full re-decoding for final quality; the measured rolling path
is the default. `--precision float16|bfloat16` enables experiments; spectral preprocessing stays
fp32 because upstream 0.5.3's reduced-precision FFT view has an invalid shape.

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

### Pointing correction at LM Studio (operator steps)

LM Studio is installed at `/Applications/LM Studio.app`. Chirp never starts it, loads no models
in it, and sends nothing until correction is enabled below. The operator does, once:

1. Open LM Studio, go to the **Developer** (local server) tab and press **Start Server**.
   Note the local endpoint, by default `http://127.0.0.1:1234/v1`.
2. Load a model there and copy its exact identifier (for example
   `lmstudio-community/Qwen2.5-7B-Instruct-GGUF`) from the server page, or list it with
   `curl http://127.0.0.1:1234/v1/models` while it runs.
3. Point Chirp at it in `~/.config/chirp/server.toml`:

   ```toml
   [correction]
   enabled = true
   base_url = "http://127.0.0.1:1234/v1"
   model = "<the identifier copied above>"
   ```

4. LM Studio needs no API key; when none is configured no Authorization header is sent.

A loopback `base_url` keeps final text on this machine (health/doctor report it as such).
If LM Studio is stopped, times out or answers like an assistant, the corrector fails closed
to the raw transcript and `correction_error` says why.

## Doctor

```sh
uv run chirp-server doctor          # full run, including a real model load and fixture decode
uv run chirp-server doctor --quick  # same checks, but skips the model load/decode
```

Read-only diagnostics, one `[OK]/[WARN]/[FAIL]` line per check with a remediation hint where
needed: Python/uv environment, MLX availability, the model directory (which path) and a warm
decode of the synthetic 5 s fixture (`--quick` skips it; the transcript is matched on a
keyword in memory and never printed), config file parse, token presence and mode (the value is
never printed or created), port 7821 free vs held by chirp-server, debug retention state plus
the count and size of retained files, the correction host and whether final text leaves the
machine, `tailscale serve status --json` parsed read-only to report whether `/chirp` is
published and tailnet-only (doctor never changes Tailscale), and whether the optional
LaunchAgent is installed. The exit code is 1 only when a check FAILs. Doctor creates no files
and starts no services.

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
uv run chirp-server doctor --quick
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
uv run chirp-server --root-path /chirp service install   # flags before "service" are kept in the LaunchAgent
uv run chirp-server service uninstall
```

Install renders the current virtual environment's absolute Python path and bootstraps a user
LaunchAgent. Keep this checkout and virtual environment in place while installed. Output goes
to `/dev/null`; run in a terminal for metadata diagnostics or visible debug warnings. Debug
retention is also always visible in the health/ready flags. Installation has **not** been run.
Tailnet publication is managed by integration; this package does not change Tailscale settings.

## Explicit optional downloads and cleanup

Starting `chirp-server`, running the ordinary test suite, and running `scripts/bench.py` never
fetch a missing recognition model. Missing models produce a `chirp-server model fetch` hint.
Real-model tests use existing cached weights and generate only synthetic `say` fixtures.
The optional Swift runners never request Microphone or Speech Recognition authorization.
Apple probing checks installed assets and skips if they are missing; grant-dependent paths
are not invoked. No launch agent or Tailscale setting is installed by benchmarks.

| Explicit command | Download or generated files | Removal |
|---|---|---|
| `chirp-server model fetch` | Pinned MLX v2 weights in `~/Library/Application Support/Chirp/models/parakeet-mlx/` | Delete that directory; Koi's existing model is untouched |
| `chirp-server model fetch --engine onnx` | Pinned ONNX v2 int8 weights in `~/Library/Application Support/Chirp/models/parakeet-onnx/` | Delete that directory |
| `scripts/generate_fixtures.py` | Synthetic WAVs + reference manifest in `~/Library/Caches/Chirp/fixtures/` | Delete that directory |
| `uv run --extra onnx python scripts/bench.py --engine onnx` | No download; requires explicit ONNX extra install and already local weights | Remove explicitly fetched Chirp weights if no longer needed |
| `scripts/bench.py --with-fluidaudio` | Stable FluidAudio 0.17.7 source/build in `~/Library/Caches/Chirp/FluidAudio-0.17.7/`, CoreML v2 models in `~/Library/Caches/Chirp/FluidModels/`; compiler/SwiftPM may populate their normal caches | Delete these two Chirp cache subdirectories; optional Swift build caches are shared system tooling caches |
| `scripts/bench.py --with-apple` | Builds a small CLI in `~/Library/Caches/Chirp/apple-bench`; **does not download assets** | Delete the CLI; speech models are owned/managed by macOS |

For candidate-only runs, `uv run python scripts/run_swift_benches.py --with-fluidaudio --with-apple`
uses the same explicit gates. Without either flag it skips everything. `scripts/prepare_fluid.sh`
is an explicit source-download/build command, and never acquires recognition weights by itself.
Both candidates print metrics only; recognized output stays in process memory.

The initial M1 Apple probe explicitly downloaded the en-US `SpeechTranscriber` model through
`AssetInventory` (system-managed asset storage, outside the Chirp cache). It did not call any
permission-request API, open a microphone, install software/services or change Tailscale.
The benchmark no longer contains an asset-install path. Removing OS-managed speech assets is
an operator action through macOS asset/storage controls; do not delete system asset files by hand.
`~/Library/Caches/Chirp/` can be removed entirely to clear generated fixtures, candidate source/builds,
FluidAudio models and metrics. It contains no user recordings or user transcripts.
