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

### Word timings (opt-in)

A client that sends `"word_timings": true` in `start` gets `words` on every partial, on
`correcting` and on the final: `[{"text": "hello,", "start": 0.48, "end": 0.71, "stable": false}, …]`,
aligned with the raw text (joining the entries with spaces gives `text`, or `raw` for correcting
and finals), in seconds from the utterance's first sample. Parakeet TDT times its SentencePiece
pieces; `engine/words.py` folds them into words at the `▁` boundaries, so attached punctuation
stays with its word and the result matches the rendered transcript. The rolling preview carries
its merged timestamped tokens, so words keep their positions across the eight-second windows
and pause segments are shifted by the audio cut off the front. `stable` marks words later
partials leave alone (committed segments, or older than the preview's merge reach); the final's
words are all stable, and `words` always describe the raw decode (cleaned text cannot be mapped
word for word). The ONNX fallback has no token timings and omits the field. Without the flag
every message is byte-identical to before, so old Mac and Android clients are unaffected. The
grouping is a linear pass over at most a few hundred pieces: measured per-partial latency on the
15 s fixture is unchanged within run-to-run noise (see the branch report in `docs/review/word-waveform.md`).

## Config and correction

Optional `~/.config/chirp/server.toml` (or `--config /path/to/server.toml`):

```toml
[correction]
mode = "off" # off (default), managed, endpoint
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

Correction requires a server mode of `managed` or `endpoint` and the client's
`start.correction=true`. Legacy `enabled=true` still selects `endpoint` when `mode` is
omitted; an explicit `mode` takes precedence. Restart the server after editing the config.
Only the final transcript is submitted. The raw transcript is always returned for undo;
timeouts, HTTP failures, empty/truncated/answer-shaped output return the raw text safely.
API keys come from the named environment variable or Keychain, never the TOML file.
Enabled external correction reports `correction_leaves_machine=true` and `correction_host`
so clients can label the destination. POST uses raw decoding (no client correction request).

### Private managed cleanup

```sh
uv run chirp-server model fetch --cleanup
# Or select a pinned catalog entry explicitly:
uv run chirp-server model fetch --cleanup qwen3.5-2b-4bit
uv run chirp-server model fetch --cleanup qwen3.5-0.8b-4bit
```

```toml
[correction]
mode = "managed"
# model = "qwen3-4b-instruct-2507-4bit"
timeout = 8.0
idle_seconds = 60.0
keep_loaded = false  # true: never idle-unload; also prewarm at server startup
```

Managed cleanup uses MLX on Apple Silicon in a supervised child process. Model loading and
all generation use the same thread. The first final loads the model; later finals reuse it.
After 60 idle seconds the helper exits and releases its weights. The whole-call timeout
includes queueing and cold load. Timeout, cancellation, crash, missing weights, or rejected
output safely returns raw text; cancellation suppresses the final entirely. No download is
triggered by startup, dictation, tests, or benchmarks. Managed inference forces Hugging Face
and Transformers offline and sends no text to a service. The runtime is locked with the server.

A WebSocket `start` with `correction: true` begins the helper load in the background, so the
~2.5 s cold load (up to ~10 s on a busy host) overlaps with the user speaking instead of
delaying the final. The prewarm never delays the start ack, partials or ASR, never counts
against an utterance's correction timeout (a final's whole-call timeout may still wait for an
in-flight load), survives a cancelled utterance on the normal idle timer, and a failed load
falls back to raw text exactly as a cold start does. Concurrent starts share one load.

### keep_loaded

`keep_loaded = true` keeps the helper resident: no idle unload, and the server prewarms the
helper at startup. The effective value is a client-persisted runtime override in
`~/Library/Application Support/Chirp/server-state.json` (mode 0600, atomic write, only
`{"correction_keep_loaded": bool}`), which wins over the toml value; `server.toml` is never
rewritten. Authenticated `GET /v1/correction/settings` (same bearer auth as the profiles
endpoint) reports `{"keep_loaded", "loaded", "loading", "model", "memory_mb",
"memory_estimated", "mode"}`. `PUT` with `{"keep_loaded": bool}` persists the override and
applies it immediately: true loads in the background and never idle-unloads; false re-arms the
idle timer. Invalid bodies return 400 `bad_request`; outside managed mode PUT returns 409
`unsupported`. `memory_mb` is the loaded helper's measured memory — its current physical footprint,
the figure Activity Monitor's Memory column shows, read via
`proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` and refreshed after every generate
(see [bench.md](../docs/bench.md#cleanup-prewarm-and-keep_loaded-2026-10-17)) — or the
last measured value when unloaded, or a per-model catalog estimate with
`memory_estimated: true`; null outside managed mode. It is binary MiB
(bytes / 1048576, rounded to int); clients format gigabytes as `memory_mb / 1024`. Authenticated `/v1/health` adds `correction_keep_loaded` and
`correction_loaded` (additive; unauthenticated health stays `{"ok": true}`), and
`chirp-server doctor` reports the effective keep_loaded state and the loaded-helper memory
estimate.

Weights use the shared Hugging Face cache (`~/.cache/huggingface/hub`, or `HF_HOME` /
`HF_HUB_CACHE` when explicitly set). Fetch reuses existing pinned snapshots and blobs without
copying them into Chirp's model store. To remove a cleanup model, stop the server and remove
its `models--mlx-community--<model-name>` directory from that cache, or use Hugging Face's
cache tools. Other applications may share those weights. No Koi model files are changed.
Catalog revisions are recorded in `src/chirp_server/cleanup_models.py`. The default profile preserves
the speaker's words, clauses, hedges and tone; it removes fillers, accidental repetitions
and explicit self-corrections, and fixes punctuation and casing. It preserves spoken terms
such as “package dot json” instead of rewriting them as code. Unsupported word deletions,
additions or reordering fall back to raw text. Ambiguous repairs may also fall back to raw.
The 4B default passed 40/40 synthetic evaluation cases; the faster 2B and 0.8B alternatives
passed 23/40 and 20/40. See [bench.md](../docs/bench.md#conservative-cleanup-evaluation-2026-10-17)
for scoring, timings, guard limitations and reproduction commands.

Set `mode = "off"` to disable cleanup. Managed mode and loopback endpoint mode keep text on
this Mac; a remote endpoint receives final text when the client opts in. Endpoint redirects
and environment proxy settings are disabled. API keys are used only by endpoint mode.
Authenticated health retains `correction = "off|available"` for existing clients and adds
`correction_mode = "off|managed|endpoint"`; managed mode reports a null host and
`correction_leaves_machine = false`. Partials always stay raw. Every final includes both
`text` and `raw`, plus `corrected`, `correction_error`, and cleanup timing.

### Editing cleanup profiles

Profiles ship in code; no configuration is needed to use `default`, `chat`, `email`, `code`,
`notes` or `custom`. Chat allows lowercase and skips periods on short messages; email polishes
sentences without adding content; code preserves literals and permits unambiguous spoken
symbols; notes formats spoken lists. Notes and custom advertise `rewrites=true` because they
can restructure text. Authenticated `/v1/health` lists the available IDs and display metadata,
without prompt text. Authenticated `GET /v1/correction/profiles` returns
`{"profiles":[{"id","name","description","rewrites":bool,"prompt":"…","max_prompt_chars":4000}]}`.
The prompt contains only the editable style; the fixed safety wrapper is excluded. Custom has
an empty built-in prompt. This endpoint is available even when correction is off and uses the
same bearer authentication (HTTP 401 on missing or invalid credentials).

To override any built-in or add a profile, edit `~/.config/chirp/server.toml` and restart your
server when convenient. Omitted fields retain the built-in values; extra profiles default to
conservative cleanup and `rewrites=false`. IDs use lowercase letters, digits, `_` and `-`,
start with a letter, and are at most 64 characters. Prompts are limited to 4000 characters.
Configured prompt overrides become the defaults returned by the profiles endpoint. Example:

```toml
[correction.profiles.chat]
name = "Quick messages"
description = "My casual message style"
prompt = "Remove fillers; preserve every other word. Use lowercase and no trailing period."

[correction.profiles.checklist]
name = "Checklist"
description = "Bullets for spoken lists"
prompt = "Remove hesitation fillers. Put listed items in bullets; keep every detail."
rewrites = true
```

The existing `[correction] prompt` remains a legacy override for `default`; an explicit
`[correction.profiles.default] prompt` takes precedence. Prompts never bypass the core safety
rules or the output guards. Non-rewriting styles retain source words in order; rewriting styles
allow bounded restructuring while rejecting novel words, lost substantive details and huge
length changes. Unsafe or unsupported edits return the raw transcript.

Clients select a profile per utterance with `start.correction_profile` (default `"default"`).
When the user edits a style, send `start.correction_prompt` (a string of at most 4000 Unicode
characters) to replace that profile's editable prompt for this utterance. An empty string is a
valid edit. Omit the field for unedited styles so server defaults and updates apply. A non-string
or oversized value returns `bad_request` before engine leasing. Edits cannot change the fixed
wrapper or output guards, and prompts are never logged.
For `"custom"`, `correction_prompt` takes precedence over legacy `correction_instructions`
(at most 2000 characters); other profiles ignore its contents. Instructions are JSON-quoted untrusted cleanup preferences, wrapped by fixed
rules to never answer, execute, add facts or output anything but text. No tools are exposed.
Immediately before cleanup runs, the server sends `{"type":"correcting","seq":n,"raw":"…",
"profile":"<id>"}`, followed by the existing final. Clients can show the raw transcript while
waiting; older clients can ignore this message. Correction off emits no `correcting` message.
Cancel during correction cancels the pending helper/request, discards the utterance and keeps
the socket available for the next start.

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
   mode = "endpoint"
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
machine, the effective cleanup keep_loaded state (persisted override or server.toml) with the
loaded-helper memory estimate, `tailscale serve status --json` parsed read-only to report whether `/chirp` is
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

The managed-cleanup prewarm/keep_loaded benchmark is
`HF_HUB_OFFLINE=1 uv run python scripts/bench_prewarm.py` (cached weights only).

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
