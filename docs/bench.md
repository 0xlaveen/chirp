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
