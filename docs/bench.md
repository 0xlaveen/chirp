# Chirp M1 measurements

Measured 2026-10-17 on Apple M5 Pro, 64 GiB unified memory, 18 logical CPUs, macOS 27.0.1 (26A434), Swift 6.4 Command Line Tools; no Xcode.

The host was shared with active build/test workers. Recorded 1-minute load averages were approximately 25–57. These are observed contended results, not isolated performance budgets. Different rows were measured at different times; cross-engine speed rankings are provisional. CPU process peak RSS excludes some GPU allocations and out-of-process system speech services, so Apple’s low RSS is not its total system memory footprint. A quieter-host rerun the same day is recorded in the 'Quiet-host rerun' section below; every other section is the original contended measurement.

## Selected behavior

Keep Parakeet MLX v2 fp32, rolling eight-second previews with upstream timestamped token merging, and full-quality final re-decode. Stop drops queued partial inference and feeds undecoded audio directly to finalization. Startup runs a real silent model decode on the same dedicated thread, bypassing the runtime silence guard.

The final real uvicorn/root-path/WebSocket simulator check on the 5.85 s fixture measured 196 ms first partial, **96 ms stop-to-final**, and 0.54 s model load plus actual decode warmup (a previous smoke measured 187/107 ms and 1.05 s). These short checks are observations, not a latency SLA. The full test path passed 62 protocol/privacy tests and 2 real-model tests. No service or Tailscale publication was installed.

Model metadata was checked on Hugging Face on 2026-10-17. The newer [MLX Community v3 conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) is multilingual; the selected English-only [v2 conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2) still resolves to pinned revision `8ae155301e23d820d82aa60d24817c900e69e487`. No model repository or floating revision is resolved at server startup.

## Quiet-host rerun (2026-10-17)

Same day, same synthetic fixtures and paired method, rerun while the host was quiet: recorded 1-minute load averages were approximately 5.0–6.2 across the paired rows (the contended sections below ran at 25–57). The real uvicorn/root-path/WebSocket simulator check measured 244 ms first partial, **107 ms stop-to-final** and 0.52 s model load plus actual decode warmup (the contended run measured 196/96 ms and 0.54 s). Every streamed final kept 0% normalized WER.

| Fixture | Actual audio (s) | Full final (ms) | Segments final (ms) | 1-min load range |
|---|---:|---:|---:|---:|
| Continuous 5 s | 5.85 | 155 | 135 | 5.3–5.8 |
| Continuous 15 s | 15.46 | 222 | 270 | 5.0–6.2 |
| 600 ms pauses 5 s | 6.45 | 153 | 114 | 5.1–5.5 |
| 600 ms pauses 15 s | 17.86 | 240 | 91 | 5.0–5.8 |

Quiet-host segments verdict: `--finalization segments` now wins the continuous 5 s median (135 vs 155 ms) but still loses the continuous 15 s median (270 vs 222 ms), while the pause fixtures improve further (114 vs 153 ms; 91 vs 240 ms). There is no clear margin for ≤20 s continuous utterances across lengths, so the default stays `full`; segments remain recommended when the speaker pauses. The same engine rows rerun under these conditions:

| Variant | Audio (s) | Warm RTFx | WER (%) | Peak process RSS (MiB) | 1-min load range |
|---|---:|---:|---:|---:|---:|
| MLX fp32 rolling | 5.85 | 87.7 | 0.00 | 1022 | 3.7–4.0 |
| MLX fp32 rolling | 15.46 | 113.0 | 0.00 | 1022 | 3.7–4.0 |
| MLX fp32 rolling | 60.45 | 104.3 | 0.00 | 1022 | 3.7–4.0 |
| ONNX v2 int8 CPU | 5.85 | 76.9 | 0.00 | 1414 | 2.7–11.4 |
| ONNX v2 int8 CPU | 15.46 | 36.1 | 0.00 | 1414 | 2.7–11.4 |
| ONNX v2 int8 CPU | 60.45 | 26.0 | 12.94 | 1414 | 2.7–11.4 |

Two observations on the quiet ONNX rows: its 60 s clip reproduces the contended run's 12.94% WER exactly, suggesting a deterministic int8 long-audio degradation rather than a load artifact, and its 1-minute loadavg climbs during the run itself because ONNX inference saturates CPU cores (unlike the GPU-side MLX rows).

Reproduce the quiet rerun with `uv run python scripts/smoke.py`; `uv run python scripts/compare_finalization.py` (kept as `bench-paired-finalization-quiet.json`; the M1 contended raw was preserved as `bench-paired-finalization-contended.json`); `uv run python scripts/bench.py --output "$HOME/Library/Caches/Chirp/bench-mlx-fp32-rolling-quiet.json"`; 
`uv run --extra onnx python scripts/bench.py --engine onnx --output "$HOME/Library/Caches/Chirp/bench-onnx-int8-quiet.json"`.

## Same-clip finalization comparison (contended)

One loaded, actually warmed model; full vs segment modes run back-to-back on each exact WAV, two repetitions with order reversed. Medians below include any in-flight partial work at stop. Every streamed final had 0% normalized WER. Short continuous 5 s regression means pause precommit remains **opt-in** (`--finalization segments`). This deliberately leaves default `stable` empty; segment mode exposes only its frozen prefixes, and final correction suppresses them. These are the original contended-host measurements.

| Fixture | Actual audio (s) | Full final (ms) | Segments final (ms) | 1-min load range |
|---|---:|---:|---:|---:|
| Continuous 5 s | 5.85 | 723 | 904 | 33.0–35.4 |
| Continuous 15 s | 15.46 | 1384 | 943 | 28.9–33.9 |
| 600 ms pauses 5 s | 6.45 | 308 | 203 | 24.9–27.1 |
| 600 ms pauses 15 s | 17.86 | 362 | 162 | 24.7–28.3 |

Segment mode also matched full-decode 0% WER on the 60.15 s controlled-pause clip, committing 15 segments / 837 characters with 930 ms final latency before the later stop-priority optimization. This demonstrates bounded tails when pauses exist, but does not prove short-utterance latency non-regression.

## Engine and streaming experiments

Same synthetic sentence generator and continuous WAV set (5.85, 15.46, 60.45 s). Warm decode is median of three full decodes; punctuation/case are normalized for WER. These early experiments predate the actual startup warmup and stop-priority fix. Their `load_and_warm_seconds` field meant load plus the silence guard, not an actual GPU decode; use the final smoke and paired measurements for current startup/final behavior. Early per-feed streaming loops were paced but could fall behind inference; only evidence marked `coalesced:true` uses an independent real-time producer. Do not compare the early stop numbers to current protocol timings.

| Variant | Audio (s) | Warm RTFx | WER (%) | Peak process RSS (MiB) |
|---|---:|---:|---:|---:|
| MLX fp32 rolling | 5.85 | 31.9 | 0.00 | 1107 |
| MLX fp32 rolling | 15.46 | 39.0 | 0.00 | 1107 |
| MLX fp32 rolling | 60.45 | 42.3 | 0.00 | 1107 |
| MLX fp32 tuned native (rejected) | 5.85 | 6.0 | 0.00 | 795 |
| MLX fp32 tuned native (rejected) | 15.46 | 11.1 | 0.00 | 795 |
| MLX fp32 tuned native (rejected) | 60.45 | 12.3 | 0.00 | 795 |
| MLX fp16 tuned native (rejected) | 5.85 | 6.5 | 0.00 | 723 |
| MLX fp16 tuned native (rejected) | 15.46 | 9.2 | 0.00 | 723 |
| MLX fp16 tuned native (rejected) | 60.45 | 13.9 | 0.00 | 723 |
| MLX bf16 tuned native (rejected) | 5.85 | 8.4 | 0.00 | 855 |
| MLX bf16 tuned native (rejected) | 15.46 | 7.9 | 0.00 | 855 |
| MLX bf16 tuned native (rejected) | 60.45 | 8.6 | 0.00 | 855 |
| ONNX v2 int8 CPU | 5.85 | 3.9 | 0.00 | 1376 |
| ONNX v2 int8 CPU | 15.46 | 13.3 | 0.00 | 1376 |
| ONNX v2 int8 CPU | 60.45 | 9.1 | 12.94 | 1376 |

Reduced precision did not establish a reproducible accuracy/latency improvement, so fp32 stays default. In parakeet-mlx 0.5.3, feeding fp16/bf16 directly into `get_logmel` reinterprets complex64 FFT values using the wrong element width (514 vs 257 bins); preprocessing therefore stays fp32 before casting model features.

The low-lookahead native tuning `(128,16)` was a usage/quality failure, not evidence that the upstream streaming API is generally inaccurate. A sanity check reproducing [upstream’s streaming example](https://github.com/senstella/parakeet-mlx#streaming-transcription) on the same short clip with one-second chunks and `(256,256)` context gave 0% WER (0 finalized / 43 draft tokens); `(128,16)` gave 52.94% WER. At 200 ms chunks, tuned context-only finals had 91–100% WER. Production’s optional native mode now buffers one-second chunks with upstream context; it never uses the rejected context-only final. Rolling stays default because it gives responsive, complete live text without needing the upstream 20.48 s right-context window.

## Production-style continuous streaming before stop optimization

Independent real-time producer, coalesced inference, complete transcript retained by timestamp merging. Final and last-partial WER were 0% at all lengths. This older snapshot includes work now skipped at stop; current short protocol timing is above.

| Audio (s) | First partial (ms) | Changed-partial cadence (ms) | Stop→final (ms) |
|---|---:|---:|---:|
| 5.85 | 323 | 632 | 2155 |
| 15.46 | 386 | 734 | 3680 |
| 60.45 | 329 | 964 | 5615 |

## Swift candidates

Both candidates run with CLT only. FluidAudio 0.17.7 compiled successfully; its explicit v2 CoreML model acquisition plus first load took 59.39 s. FluidAudio rows are median of three warm batch file decodes after a discarded warm decode. Apple rows are single file runs after prepare (33–107 ms). They are **not** real-time protocol measurements: first-partial cadence and stop→final are TBM for both Swift candidates. Apple's file first-result times are not microphone/live first-partial latency.

| Candidate | Audio (s) | Batch decode (ms) | RTFx | WER (%) | Process RSS (MiB) |
|---|---:|---:|---:|---:|---:|
| FluidAudio v2 ANE | 5.85 | 98 | 59.5 | 0.00 | 536 |
| FluidAudio v2 ANE | 15.46 | 1091 | 14.2 | 0.00 | 536 |
| FluidAudio v2 ANE | 60.45 | 956 | 63.2 | 0.00 | 536 |
| Apple SpeechAnalyzer | 5.85 | 143 | 40.9 | 5.88 | 18 |
| Apple SpeechAnalyzer | 15.46 | 248 | 62.5 | 2.22 | 19 |
| Apple SpeechAnalyzer | 60.45 | 801 | 75.4 | 2.35 | 21 |

FluidAudio is a promising follow-up for longer recordings; the contended 15 s outlier and lack of a live-protocol comparison prevent a defensible default flip. MLX now finalizes the 5.85 s protocol fixture in 96–107 ms, comparable to FluidAudio’s 98 ms batch-only result. Apple trades some synthetic accuracy for speed. No new Swift bridge or runtime permission dependency is added to the production server.

## Reproduce and remove artifacts

```sh
cd server
uv sync --locked --all-extras
uv run python scripts/generate_fixtures.py
uv run python scripts/generate_fixtures.py --pause-ms 600 --output "$HOME/Library/Caches/Chirp/fixtures-paused"
uv run python scripts/bench.py
uv run python scripts/compare_finalization.py
uv run python scripts/native_sanity.py
uv run --extra onnx python scripts/bench.py --engine onnx
uv run python scripts/bench.py --with-fluidaudio --with-apple
uv run python scripts/smoke.py
uv run python scripts/render_bench.py
```

Model/alternate downloads require the explicit commands/flags documented in [server/README.md](../server/README.md#explicit-optional-downloads-and-cleanup). Default server/bench startup never downloads missing recognition models. Apple benchmarking checks already installed assets and never asks for authorization or installs assets. The initial explicitly requested M1 model probe downloaded only the en-US speech model via AssetInventory; it did not call TCC request APIs or use a microphone. No permissions, services, or Tailscale configuration were changed.

Synthetic WAVs, candidate source/build/models and raw numeric results live under `~/Library/Caches/Chirp/` and may be deleted together. Apple assets are macOS-managed; use OS asset/storage controls. Only numeric benchmark evidence is committed in [bench-data/](bench-data/); no audio or recognized text is retained. These synthetic fixtures do not establish WER on accents, spontaneous speech or microphone noise. Natural recorded fixtures, isolated-host comparisons and Swift live-protocol latency remain TBM, with no production latency budget claimed.

## Initial three-input cleanup benchmark (2026-10-17)

Default: **off**. For managed mode choose **Qwen3 4B Instruct 2507, MLX 4-bit**
(`qwen3-4b-instruct-2507-4bit`). It preserved the intended repair in all three
repetitions of the two-sentence self-correction case, unlike the newer 2B and 0.8B models.
All three are explicit catalog choices; speed alone does not select the default.

Hardware: Apple M5 Pro, 64 GiB. Runtime: mlx-lm 0.32.2, MLX 0.32.4, Python 3.13.16.
The benchmark uses the actual supervised helper, greedy sampling, thinking disabled,
JSON-delimited source and the built-in general-dictation prompt. Three synthetic inputs
(schedule/API dictation, a revised meeting day with Kubernetes notes, and a dictated
Postgres question) repeat three times per model. Inputs and model responses remain in memory;
only counts, timings and load averages are printed. The warm numbers include pipe transport,
template application, prefill, generation and output validation. They exclude ASR and network
latency. Each helper starts once, answers one discarded warmup/cold call, then nine measured
calls. No transcript prefix/KV cache is retained between requests.

| Model | Pinned revision | Cold first final (ms) | Warm median / min–max (ms) | Accepted / keyword checks | Repair / question checks |
|---|---|---:|---:|---:|---:|
| Qwen3 4B Instruct 2507 4-bit | `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b` | 2519 | **343.9 / 318.5–374.5** | 9/9 / 9/9 | **3/3 / 3/3** |
| Qwen3.5 2B 4-bit | `674aaa7240b91e8012fcad5d791b7dfe5ba90207` | 1977 | 177.2 / 173.4–208.9 | 9/9 / 9/9 | 0/3 / 3/3 |
| Qwen3.5 0.8B 4-bit | `da28692b5f139cb0ec58a356b437486b7dac7462` | 1637 | 93.6 / 86.3–109.5 | 9/9 / 9/9 | 0/3 / 3/3 |

“Accepted” means the defensive output guard passed; it does **not** establish semantic
correctness. The smaller models retained the superseded Monday in the longer repair case,
although 0.8B passed the short, one-detail repair. Question checks require a preserved question
and rollback terms, not an assistant answer. These checks do not establish general accuracy.
The default model integration test also checks a different pair of revised weekdays.

The final run's one-minute load average ranged 18.2–19.3. An earlier, busier run (load
27.6–28.7), before the explicit repair example was added to the prompt, measured warm
medians of 701.6 / 478.4 / 353.7 ms and cold first finals of 14.9 / 15.5 / 7.8 seconds
for 4B / 2B / 0.8B respectively. Both prompt and host load changed, so the difference
cannot be attributed to the prompt. The final 4B warm sample meets the approximately
400 ms aim; it is not a tail-latency guarantee on a shared GPU. Cold loads and load spikes
may exceed the default eight-second budget, in which case raw text is returned and the
helper is stopped. The next final retries; idle unload after 60 seconds also makes the
next final cold. The production timeout includes queue wait, model load and inference.

Candidate discovery checked the Hugging Face [Qwen3.5 0.8B 4-bit model](https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit)
and [2B build](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit), both uploaded
2026-03-02, against Koi's [Qwen3 4B Instruct 2507](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit).
The newer [Gemma 4 E2B 4-bit](https://huggingface.co/mlx-community/gemma-4-e2b-4bit)
card specifies mlx-vlm and 3.58 GB of multimodal weights, so it was excluded from this
lean text-only runtime comparison. No claim of an exhaustive model leaderboard is made.

Explicit acquisition used these commands; there were no cached cleanup weights before
this run. Downloads populated only the shared Hugging Face cache (roughly 2.28 GB,
1.75 GB and 0.63 GB of weights respectively, plus tokenizers). No service, application,
LaunchAgent, token, Tailscale configuration or microphone permission was changed.

```sh
cd server
uv sync --locked
uv run chirp-server model fetch --cleanup qwen3-4b-instruct-2507-4bit
uv run chirp-server model fetch --cleanup qwen3.5-2b-4bit
uv run chirp-server model fetch --cleanup qwen3.5-0.8b-4bit
uv run python scripts/bench_cleanup.py
uv run pytest -q -m model
```

Only the three `model fetch --cleanup` commands may download weights. The benchmark and
model tests use local pinned snapshots. For cache location and removal, see
[server/README.md](../server/README.md#private-managed-cleanup).

## Conservative cleanup evaluation (2026-10-17)

Keep **Qwen3 4B Instruct 2507 4-bit** as the managed default; cleanup remains off by
default. The broader synthetic eval exposed aggressive rewriting that the initial
three-input keyword benchmark above missed. On the 40-case set, the old production
prompt/guard (`a88617a`) passed 19/40 cases on 4B. The revised prompt, Unicode JSON
input and ordered word-retention guard passed **40/40**, including the original
hedged meeting-day correction: “So I think we should meet on Tuesday at 3 p.m. and
bring the slides.” The hedge remains intact.

| Model (same pinned revisions as above) | Before passes | After passes | Before warm median (ms) | After warm median / min–max (ms) | Before / after cold first final (ms) | After fallbacks |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3 4B Instruct 2507 4-bit | 19/40 (47.5%) | **40/40 (100%)** | 371.6 | **397.8 / 309.4–702.2** | 18899.2 / 2563.4 | 0/40 |
| Qwen3.5 2B 4-bit | 15/40 (37.5%) | 23/40 (57.5%) | 157.5 | 190.7 / 137.3–343.2 | 6257.9 / 2592.2 | 2/40 |
| Qwen3.5 0.8B 4-bit | 17/40 (42.5%) | 20/40 (50%) | 77.2 | 91.7 / 73.8–170.9 | 2543.4 / 1944.5 | 7/40 |

Same M5 Pro and locked runtime as above. Each model used one fresh helper, one
unscored cold/warmup call and one measured pass over all 40 cases. Calls are sequential
and use the actual managed pipes, template, greedy decoding (temperature 0), disabled
thinking and final output guard. Baseline load averages ranged 28.5–35.3; final tuned
load ranged 13.1–15.7. Before/after latency is observed on a shared host, not an isolated
causal comparison or a latency budget. An earlier tuned 4B run measured a 542.3 ms warm
median and a 10.2 s cold call, exceeding the production eight-second timeout. Eval uses
120 seconds so it measures quality rather than startup timeout behavior. Production
still returns raw on timeout. The final 0.8B cold/warmup call was rejected and returned raw;
it is excluded from the 40 measured cases for every model.

The checked-in [40 synthetic cases](../server/tests/cleanup_eval.jsonl) cover fillers,
explicit and chained repairs, stutters, repetition with emphasis, hedges, negations,
lists, questions, commands, instruction-like dictated content, code, spoken technical
terms, URLs, numbers, dates, names, long clauses, unchanged clean text, profanity and
non-English words. No real transcripts or new weights were acquired. These are tuning
fixtures, not a held-out natural speech accuracy estimate. The initial conservative
prompt scored 37/40 on 4B, 24/40 on 2B and 20/40 on 0.8B. A combined hedge/repair example
and readable Unicode JSON inputs produced the final row. This does not establish which
of those two changes caused each improvement.

The [scorer](../server/src/chirp_server/cleanup_eval.py) normalizes Unicode, casing
and punctuation, then checks exact equality or at most 8% word edit distance against
explicit expected variants. Every pass also requires all case-specific must-keep
phrases, no must-drop phrases, and byte-for-byte equality on already-clean cases.
Words retain order and multiplicity. Near matching never overrides these checks.
The final exact / near counts were 40/40 and 40/40 for 4B, 22/40 and 24/40 for 2B,
and 20/40 and 23/40 for 0.8B. A fallback is scored as returned raw text and generally
fails cleanup checks; guard acceptance alone is never scored as accuracy. Aggregate
counts, failed case IDs, timings and load evidence are in
[cleanup-conservative.json](bench-data/cleanup-conservative.json).

The guard replaces the old roughly 50% set-overlap threshold. It requires ordered
source words, allowing only bounded filler/stutter deletions and single-value repairs
between weekdays, months, spoken numbers, integer values or capitalized names. It
checks literal URL, code-call, identifier, numeric-format and operator fragments too.
It rejects dropped hedges, negations, clauses, paraphrases, invented answers and
reordered content, returning the raw input. Multiword or otherwise ambiguous repairs
can conservatively fall back to raw. Filler classification remains heuristic, and
punctuation/case changes can affect meaning; this is not a semantic proof for arbitrary
speech. The prompt tells the model to preserve ambiguous words and meaningful “like,”
“you know,” “I mean” and repetition.

`pytest -m model` evaluates all three cached models. The 4B default must pass at least
90% with every must-keep phrase preserved; alternative regression floors are 55% for
2B and 45% for 0.8B. These lower floors document their limitations and do not qualify
them as defaults. Ordinary tests use a synthetic fake helper, including attempted
hedge/negation loss, reordered clauses, code/URL changes and the original bad summary.
The complete required validation passed: locked sync, Ruff lint and format checks,
143 ordinary tests and all 5 real-model tests (three cleanup models and two ASR tests).

Reproduce the current evaluation without downloads or a server port:

```sh
cd server
uv sync --locked
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 uv run python scripts/bench_cleanup.py --label conservative
uv run pytest -q -m model
```

To reproduce the baseline, use the correction and helper modules from `a88617a` with
the same new fixtures, scorer and benchmark harness. The `--label` flag labels results;
it does not select an older prompt. `--model` selects a cached catalog model and
`--repetitions` repeats the full set. Benchmark output contains metrics and synthetic
case IDs, never transcript text. No running service, LaunchAgent, token, Chirp user
configuration or Tailscale state was accessed or modified for this tuning.

## Cleanup profiles evaluation (2026-10-17)

The production Qwen3 4B Instruct 2507 MLX 4-bit model passed **59/59 synthetic cases**
with the six built-in profiles. The default profile retains the original 40 cases;
19 new cases exercise casual chat punctuation and hedges, polished email sentences,
literal code and spoken symbols, notes bullets, custom formatting, and hostile custom
instructions or instruction-like dictated text. Each profile has a 90% regression floor
in the real-model test; the two smaller model alternatives retain their existing
conservative-only floors. Cleanup stays off by default.

| Profile | Accuracy | Warm median (ms) | Warm min–max (ms) | Guard fallbacks |
|---|---:|---:|---:|---:|
| `default` | 40/40 (100%) | 412.3 | 322.5–985.7 | 0/40 |
| `chat` | 3/3 (100%) | 314.1 | 311.2–350.0 | 0/3 |
| `email` | 3/3 (100%) | 405.4 | 398.7–436.4 | 0/3 |
| `code` | 6/6 (100%) | 226.5 | 195.3–380.7 | 1/6 |
| `notes` | 3/3 (100%) | 400.3 | 295.8–413.5 | 0/3 |
| `custom` | 4/4 (100%) | 325.4 | 298.4–434.6 | 0/4 |

Hardware and pinned model revision are the same as above (M5 Pro, 64 GiB,
`50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b`), using the locked runtime.
One fresh supervised helper served one discarded cold/warmup request, then one
sequential pass over all 59 cases. Cold first final was **4603.1 ms**;
overall warm median was **397.7 ms**. One-minute host load ranged
9.5–12.6. Timings include profile prompt construction, pipe transport,
template/prefill, generation and guards, and exclude ASR and network. No per-profile
cold-start claim is made because one helper serves all profiles. The eval timeout is
120 seconds; production retains its eight-second whole-call timeout and raw fallback.
These shared-host measurements are observations, not latency guarantees.

All 59 results matched normalized expected words and passed required-content,
must-drop and applicable formatting checks. The scorer now also checks requested
trailing punctuation and literal bullet/identifier fragments; normalized word equality
alone cannot establish chat, code or bullet-format correctness. The sole fallback was in the code profile: the guard preserved raw text that already
satisfied the fixture, so it counted as correct.
A fallback counts as correct only if the returned raw text itself satisfies the fixture.

The immutable safety wrapper applies to every profile, including overrides. Client custom
preferences are JSON-quoted as untrusted data between core rules. Rewriting profiles permit
list formatting and bounded transition/conjunction removal while preserving substantive word
order and multiplicity, negations and technical fragments; they reject novel words and huge
length changes. Code additionally checks literal casing and symbol multiplicity, allowing
only bounded spoken-symbol conversions. Fake-helper regressions cover `correcting` before
helper startup, cancellation after `correcting` with no later final or retention, and a v1
reader ignoring the new event. Heuristic guards and these small tuning fixtures do not
establish semantic safety or accuracy on arbitrary natural dictation.

Metrics are in [cleanup-profiles.json](bench-data/cleanup-profiles.json); fixtures remain
synthetic and no transcript or model response is written by the benchmark. The required
validation passed with **173 ordinary tests and all 5 real-model tests**, locked sync,
Ruff lint and Ruff format checks. Validation used a throwaway HOME, cached local weights
and ephemeral test ports; no running service, LaunchAgent, token, Chirp user configuration
or Tailscale state was touched. No weights were downloaded.

To reproduce the cached profile benchmark:

```sh
cd server
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 uv run python scripts/bench_cleanup.py \
  --model qwen3-4b-instruct-2507-4bit --label profiles
uv run pytest -q -m model
```

## Cleanup prewarm and keep_loaded (2026-10-17)

Managed cleanup now prewarms. A WebSocket `start` with `correction: true` in managed
mode begins the helper cold load in the background, overlapping the ~2.5 s load
(up to ~10 s on a busy host) with the user still speaking. The prewarm never delays
the start ack, partials or ASR, never counts against an utterance's correction
timeout (a final's whole-call timeout may still wait for an in-flight load), a
cancelled or aborted utterance leaves the warm helper on the normal idle timer,
concurrent starts share one load, and a failed background load falls back to raw
text exactly as a cold start does. The server also prewarms at startup when
`keep_loaded` is on. The prewarm load itself is bounded at 30 seconds.

`keep_loaded` (default `false`) keeps the helper resident instead of idle-unloading
it. `[correction] keep_loaded` in `server.toml` is overridden by a client-persisted
runtime flag in `~/Library/Application Support/Chirp/server-state.json` (mode 0600,
atomic write, only `{"correction_keep_loaded": bool}`); the toml file is never
rewritten. `GET/PUT /v1/correction/settings` (same bearer auth as the profiles
endpoint; 400 `bad_request` on invalid bodies; 409 `unsupported` outside managed
mode) reports `{"keep_loaded", "loaded", "loading", "model", "memory_mb",
"memory_estimated", "mode"}`. PUT true loads immediately in the background and never
idle-unloads; PUT false persists and re-arms the idle timer. Authenticated
`/v1/health` adds `correction_keep_loaded` and `correction_loaded`; `chirp-server
doctor` reports the effective keep_loaded state and the loaded-helper memory.

### Measured helper memory

`memory_mb` is the helper process's current physical footprint — the same figure
Activity Monitor's Memory column shows — read by the server via
`proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`, in binary MiB (bytes / 1048576,
rounded to int). It is measured after the model loads and refreshed after every
generate, so it tracks the resident working set rather than a load-time peak. (An
earlier draft of this metric summed peak RSS plus peak Metal wired memory; on
Apple Silicon unified memory the weights appear in both terms, which double-counted
to ~4670 MiB for the 4B and was replaced before deploy.) If the server cannot read a
child's footprint (non-macOS host), the helper's ready-line approximation — peak RSS
plus active Metal memory — is used instead. When the helper is not loaded, the
settings endpoint reports the last measured value for the model, else the
steady-state catalog estimate below with `memory_estimated: true`.

| Cleanup model | At load (MiB) | After one generate (MiB) | Cold load (s) | 1-min load |
|---|---:|---:|---:|---:|
| Qwen3 4B Instruct 2507 4-bit (default) | 2440 | **2563** | 11.64 | 37.7 |
| Qwen3.5 2B 4-bit | 1491 | **1607** | 12.72 | 38.6 |
| Qwen3.5 0.8B 4-bit | 892 | **1011** | 15.60 | 39.6 |

This measurement pass ran while the host was heavily contended (1-min load 37.7–39.6,
hence the slow cold loads; the prewarm/keep_loaded rows above measured 2.9–5.5 s
loads at 1-min load ~20). The catalog estimates use the after-generate steady-state
values, which keep_loaded sessions typically report.

### First-final latency after an idle unload

Real WebSocket path with the real cached 4B helper and a fake ASR engine, so the
numbers isolate managed cleanup. Every measured utterance follows an idle unload,
so the helper starts cold: prewarm overlaps the load with ~3 s of speech, no-prewarm
pays it inside the final. Shared-host observations, not latency budgets.

| Variant | Stop→final median (ms) | Stop→final min–max (ms) | Correction median (ms) | Corrected | 1-min load |
|---|---:|---:|---:|---:|---:|
| No prewarm (before) | 4930.5 | 3745.7–5020.5 | 4927.8 | 3/3 | 19.9–24.7 |
| Prewarm (after) | **1709.8** | 740.1–5961.3 | 1707.9 | 3/3 | 20.9–24.5 |

The prewarm median is ~2.9× faster under this host load; its worst run (5961 ms)
happened when the contended cold load (~5–6 s) outlasted the 3 s of speech, so the
final still waited for the tail of the in-flight load. On a quieter host the
~2.5 s load fits inside the speech window and the final pays only the ~400 ms warm
generation. Quality is unchanged by construction: no prompt, model or guard changed
in this task, and all six measured finals were corrected with zero raw fallbacks.

To reproduce (cached-only; never downloads weights):

```sh
cd server
HF_HUB_OFFLINE=1 uv run python scripts/bench_prewarm.py --runs 3
HF_HUB_OFFLINE=1 uv run pytest -q -m model
```

Metrics are in [cleanup-prewarm.json](bench-data/cleanup-prewarm.json).

## Notes structuring (2026-10-20)

`POST /v1/notes/structure` through the real supervised helper with the cached default model
(`qwen3-4b-instruct-2507-4bit`, warm, `max_tokens` 768, temperature 0), on the reference
Apple M5 Pro (macOS 27.0.1, 1-minute load about 2-4, so close to quiet). The input is
`server/tests/notes_eval.jsonl`: 16 invented transcripts (four topics, each at about 800,
1600, 2400 and 4000 characters; long ones run into the next topic as a real session does),
dense with numbers, decisions, to-dos, questions and negations. Greedy decoding makes repeated
runs identical, so each figure is one run of each entry; cold load of the helper was 968 ms
(cached weights). Guard figures use the committed `notes_rejected`.

| Window (chars) | Runs | p50 (ms) | p95 (ms) | Output tokens p50 / p95 | Guards passed |
|---:|---:|---:|---:|---:|---:|
| ~800 | 4 | 2177 | 2264 | 180 / 188 | 4/4 |
| ~1600 | 4 | 3604 | 6139 | 304 / 332 | 4/4 |
| ~2400 | 4 | 5188 | 5540 | 450 / 494 | 3/4 |
| ~4000 | 4 | 7966 | 8680 | 682 / 768 | 2/4 |
| All | 16 | 4539 | 8680 | 338 / 768 | 13/16 (81%) |

Windows up to 2400 characters, which is the size the client freezes at, pass the guards 11/12
(92%). The p95 of a 2400-character pass is 5.5 s, inside the 10 s target. Both 4000-character
misses are explained below: one was cut off at the 768-token cap (`finish == length`, so it is
rejected by design) and one dropped a negation.

How the guard pass rate got there (same 16 entries, same guards; only the prompt and the
negation bookkeeping changed):

| Step | Passed | Rejected by |
|---|---:|---|
| Prompt as first written | 6/16 (38%) | negation 9, finish 1 |
| + explicit negation rule and a third few-shot example that keeps "not sure" / "haven't" | 9/16 (56%) | negation 5, finish 2 |
| + "don't forget", "no problem", "no worries", "can't wait", "not only" are not counted as spoken negations | 12/16 (75%) | negation 3, finish 1 |
| + a Question bullet keeps its hedge ("**not** sure whether X") | 13/16 (81%) | negation 2, finish 1 |

What was and was not tuned:

- **The novel-content threshold stays at 85 %.** It never rejected a faithful output in any run
  (every rejection above is negation or the token cap), so there was nothing to tune. The
  normalisation was widened from plain suffix stripping to stem variants (`shipping` / `ship`,
  `moving` / `move`, `priorities` / `priority`) and tokens containing digits (`3rd`, `2pm`)
  are left to the number guard; both came out of unit tests rather than the bench.
- **The negation, number and injection guards were not weakened.** The only change on the
  negation side is that five idioms whose "negation" is not semantic (`don't forget to call` is a
  reminder) are not counted on the transcript side. A dropped `not` in any other sentence still
  rejects, as does `we will not ship on friday` to `- Ship on Friday` (tested).
- **What the remaining rejections are.** The model sometimes summarises "I'm not sure who owns it"
  as a bare question, or drops a negated side remark. The guard is deliberately stricter than
  a human reader, because a dropped `not` flips a decision. The cost is a `structured:false,
  error:"rejected"` answer and the client keeps its previous block, then retries or freezes a
  fallback block (see the issue's failure handling). The eval transcripts have about one
  negated sentence in every three to four sentences, which is denser than most meetings, so
  expect a higher pass rate on ordinary speech. This is a synthetic set: it measures the
  guards and latency, not summary quality.
- **The 768-token cap cuts off 4000-character windows.** One of the four 4000-character
  outputs hit it and the median of that row is already 682 tokens. Windows that large should
  not be sent.

Recommended client constants for M2 (the issue's starting values were `freezeChars` 2400 and
`maxWindowChars` 5000):

- `freezeChars` **1600**. The open window can then reach about 1600 plus one segment
  (a 90 s segment is roughly 1300 characters of speech), around 2900 characters, which stays
  where the 2400-character row shows 450-500 output tokens and 5.5 s p95 rather than the
  4000-character row where outputs reach the cap.
- `maxWindowChars` **3600** for the fallback freeze, below the 4000-character row.
- `NOTES_MAX_TOKENS` stays at 768: the largest output in the 2400-character row is 494 tokens,
  and only the 4000-character row reaches the cap.

Reproduce (cached weights only; the script refuses to run without them):

```sh
cd server
uv run python scripts/bench_notes.py --repetitions 1 --dump /tmp/notes-out.jsonl
uv run pytest -q -m model tests/test_notes.py
```

Metrics are in [notes-structuring.json](bench-data/notes-structuring.json). `--dump` writes every
output (synthetic text) to a file you choose, for inspecting which guard rejected what.
