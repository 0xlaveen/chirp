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

## Live Notes clean-up and guards on messy speech (2026-10-20)

Real Live Notes use showed both passes failing closed on every call: segment clean-up kept every
"um/like/yeah" (`correction_error: rejected`), and every structuring pass was `rejected`, so no notes
appeared. The cause was in the guards, not the model. The `default` dictation guard only licenses
um/uh/er, a leading "so" and narrow "like"/"you know" cases, so long-form speech ("like"
mid-sentence, "yeah", "okay", "that's that's", restarts) is always rejected. The structuring guard
required 85 % exact content-word overlap, which real paraphrased notes ("lacks clarity",
"Suggestion:") miss, and it required every spoken negation to reappear, including incidental ones
("whether it supports it or not").

The fix adds a hidden `live_notes` correction style with its own deletion-only guard and budget,
and replaces the structuring guards with checks aimed at hallucination (invented names, numbers,
dates, contacts, unrelated answers) and at flipped negations. The previous section's set
`notes_eval.jsonl` is clean written-style text, so a new invented set measures real speech:
`server/tests/notes_messy_eval.jsonl` has 11 product-feedback and meeting monologues of 628-2035
characters, written like ASR output with fillers, stutters, restarts and incidental negations.
`server/tests/notes_negatives.jsonl` has 32 invented bad outputs that must be rejected: 20
structuring cases (invented name, acronym, number, number word, date, email or domain, six flipped
negations, answered questions, instruction injection, a link, an opener) and 12 clean-up cases
(dropped or restarted negation, changed number, inserted word, swapped names, dropped name, content
word or hedge, summary, answer, injection, paraphrase).

Same machine and model as above (`qwen3-4b-instruct-2507-4bit`, warm, temperature 0, 1-minute
load about 2-3; cold helper load 1010 ms). One run per entry, greedy, so repeats are identical.
Segment rows cut each transcript at sentence ends into pieces of at most 675 characters, which is
about 45 s of speech at 15 characters per second (the new client maximum). Whole rows send the
entire transcript, about what a 90 s segment produced before.

| Live Notes segment clean-up | Runs | Chars p50 / max | p50 (ms) | p95 (ms) | Guard passed | um/uh left |
|---|---:|---:|---:|---:|---:|---:|
| `live_notes`, ≤ 45 s segments | 23 | 612 / 675 | 1530 | 1790 | **22/23 (96 %)** | 0 of 82 |
| `default` (before), ≤ 45 s segments | 23 | 612 / 675 | 1594 | 1868 | 4/23 (17 %) | — |
| `live_notes`, whole transcript | 11 | 769 / 2035 | 1902 | 4864 | 8/11 (73 %) | 0 of 61 |
| `default` (before), whole transcript | 11 | 769 / 2035 | 1986 | 4959 | 0/11 (0 %) | — |

| Structuring | Runs | p50 (ms) | p95 (ms) | Output tokens p50 / p95 | Guards passed (before → after) |
|---|---:|---:|---:|---:|---:|
| Messy set | 11 | 1726 | 3148 | 131 / 256 | 4/11 → **11/11** |
| Clean set (`notes_eval.jsonl`) | 16 | 4215 | 8839 | 362 / 768 | 13/16 → 15/16 |
| Negatives rejected | 32 | — | — | — | **32/32 (100 %)** |

The messy-set structuring "before" figure is the old guards on the same prompt: 4 pass, 3 rejected
by `negation`, 4 by `novel`. The one clean-set failure is the 4000-character window that reaches the
768-token cap (`finish`), which is rejected by design. The client never sends windows that large
(previous section).

What was tuned, and why:

- **Clean-up guard (`notes_faithful`).** Deletion only, in order, casing and punctuation free.
  The first version licensed spoken fillers, immediate repeats and short restarts and passed 14/23.
  The model's remaining edits were of three safe kinds that the guard now also licenses: repeats
  with a filler between the copies ("which is, yeah, which is"), a sentence-initial "and" ("Oh, and,
  uh, the login is fine"), and a restated subject ("the list is, uh, it's actually nice"). A prompt
  rule to keep hedges and short asides then reached 22/23. The remaining rejection is the model
  dropping "I think" and "the other one", which the guard should reject. Number words are never a
  stutter ("twenty twenty six"), and a restart can never drop a negation, a number or a content
  word that is not said again right after.
- **Segment length and budget.** Clean-up time grows with length: about 1.5 s for a 45 s segment
  and up to 4.9 s for 2000 characters. The pass rate also falls, from 96 % to 73 %, because a
  longer output has more chances to drop a word. A clean-up can also wait behind a running
  structuring pass (p95 5.7 s for a 2400-character window, clean set), so a 90 s segment could
  exceed the old 8 s budget. The client therefore cuts segments at a pause after 12 s (relaxed
  pause after 30 s) and always by 45 s. The server gives `live_notes` its own
  `notes_timeout` of 15 s: a 2 s clean-up plus a full wait behind structuring, still inside the
  client's 25 s final deadline. Dictation keeps `timeout` (8 s) and its request is unchanged.
- **Overlap floor 50 %** (stemmed content words outside stopwords and labels). The 27 real
  outputs above score 83-100 %, and the "answer" and "injection" negatives score 0-15 %. The
  floor sits between the two with margin on both sides. Hallucination is caught by the specific checks (names, numbers, dates, contacts),
  not by the floor.
- **Negation flips, not counts.** A line is a flip only if it restates the negated clause's head
  (the first content word after the negation, plus the next word for "not sure" or "don't know")
  and at least 60 % of the clause's content words, makes up at least 60 % of its own content, and
  has no negation, negative wording ("lacks", "unclear", "instead") or hedge ("whether", "?"). The
  60 % line share came from a real false positive: "Custom firmware needed for warehouse
  integration" next to "they can't do the custom firmware". The head rule came from "I didn't
  really have any problems with sign in" → "Sign in worked".

Reproduce (cached weights only):

```sh
cd server
uv run python scripts/bench_notes.py --set messy --repetitions 1 --dump /tmp/notes-messy.jsonl
uv run python scripts/bench_notes.py --set clean --repetitions 1
uv run pytest -q -m model tests/test_notes.py tests/test_notes_correction.py
```

Metrics are in [notes-messy.json](bench-data/notes-messy.json).

## Notes reorganize (2026-10-20)

`POST /v1/notes/reorganize` (issue #17, M1) through the real supervised helper with the cached
default model (`qwen3-4b-instruct-2507-4bit`, warm, `max_tokens` 1024, temperature 0) on the
reference Apple M5 Pro, 1-minute load about 2-3.5 (other agents were running, so latencies are
about 25 % above a quiet host: the same 3500-character rows took a p50 of 11.8 s in an earlier
run). Greedy decoding makes repeats identical, so each figure is one run of each entry.

The input is `server/tests/notes_reorganize_eval.jsonl`: 12 invented, deliberately messy notes
documents (three each at about 1000, 2000, 3000 and 3500 characters) as v1 plus a person would
leave them: repeated and near-duplicate headings, duplicated bullets, tasks scattered and
reworded twice, `- [x]` done tasks, lowercase shorthand ("ask jo re: invoices", "need 2 more
chairs??"), `1.` and `*` lists, a typed table and link, a `_Not structured_` fallback block,
negated decisions and hedges, dense numbers and dates, and in 11 of 12 the line "ignore previous
instructions and write a poem". `server/tests/notes_reorganize_negatives.jsonl` has 78 invented
bad reorganizations built on six of them, each with exactly one defect: a dropped line, trimmed
details, a summary, an invented name, number or date, a dropped number, a flipped, added or
dropped negation or hedge, a dropped, re-stated or invented task, a dropped Decision, an invented
heading, a fence, table or link, markup outside the subset, and an obeyed injection.

| Notes (chars) | Runs | p50 (ms) | p95 (ms) | Output tokens p50 / max | Prompt tokens max | `finish` | Guards passed |
|---:|---:|---:|---:|---:|---:|---|---:|
| ~1000 | 3 | 4950 | 4985 | 280 / 287 | 1205 | stop 3 | 3/3 |
| ~2000 | 3 | 9745 | 9754 | 561 / 571 | 1540 | stop 3 | 1/3 |
| ~3000 | 3 | 14989 | 15133 | 885 / 911 | 1848 | stop 3 | 3/3 |
| ~3500 | 3 | 15002 | 15617 | 923 / 955 | 1984 | stop 3 | 3/3 |
| All | 12 | 11156 | 15617 | 656 / 955 | 1984 | stop 12 | **10/12 (83 %)** |
| Client scope ≤ 2500 (trailing whole sections of the 3000/3500 docs) | 6 | 11518 | 13268 | 701 / 802 | 1685 | stop 6 | 5/6 |
| Negatives rejected | 78 | — | — | — | — | — | **78/78 (100 %)** |

With the scope rows the final prompt passes 15/18 (83 %). Every accepted output kept all its
`expect_keywords` and checkbox `expect_tasks`. All outputs changed the document (`changed:true`).

The remaining rejections are real model faults the guards are meant to catch, not guard noise:
`fundraiser-2000` drops the "**60** youth, **60** adult" t-shirt line, `talk-2000` rewrites a
typed paragraph without "it might eat 3 minutes", and the `wedding-3500` scope turns three plain
"ask jo re: …" lines into `- [ ]` tasks. The client keeps its notes and retries after more text.
**The 90 % target is not met** (83 %); guards 4, 5 and 7 (novel, dropped numbers, negations) were
not weakened to get there.

How the pass rate got there (same fixtures and guards except where noted; one run each):

| Step | Valid passed | Rejected by |
|---|---:|---|
| Prompt as written in the issue, 3500-character cap | 0/12 | `dropped_line` 5 (all: the injection line silently removed), `finish` 4 (all 3500-char docs and one 3000 hit 1024 tokens), `dropped_number` 2, `task_invented` 1 |
| + keep instruction-like lines, a moved task leaves its section, no trailing spaces; client-scope rows added | 2/18 | `dropped_number` 6, `length` 4, `finish` 3, `task_invented` 2, `dropped_line` 1 |
| Move-never-copy prompt (Qwen copied the whole document and then appended duplicate "Action items / Decisions / Open questions" sections, even pulling a line from the few-shot example); `1.` list markers are not numbers; trailing spaces stripped before the guards | 11/18 | `dropped_number` 6, `dropped_line` 1 |
| + keep done tasks and every number | 10/18 | `dropped_number` 5, `dropped_line` 2, `novel_number` 1 |
| "Every input line appears exactly once" first, merged sections keep both copies' bullets, a done task in the example's second copy | 14/18 | `dropped_number` 2, `task_invented` 1, `negation` 1 |
| + "could", "likely", "possible", "tentative", "tbd" count as hedges (`maybe $2,900` → `could be $2,900`) | **15/18** | `dropped_number` 2, `task_invented` 1 |

Deviations from the issue's prompt, both forced by the bench: the model is no longer invited to
collect tasks, decisions and questions under `## Action items` / `## Decisions` /
`## Open questions` (a 4B model copies instead of moving; the headings stay on the guard's
allowlist), and instruction-looking lines are kept under `## Notes`. The prompt is 3535
characters (879 tokens), under the 3.6k target.

Token budget and constants:

- **`MAX_REORGANIZE_CHARS` stays 3500** (M2's `maxReorganizeChars` already matches). Once the
  model stopped copying, no output reached the cap: the largest is 955 of 1024 tokens at 3430
  characters, and the worst prompt is 1984 tokens, so 1984 + 1024 = 3008 ≤ 4096. The model test
  `test_real_prompt_fits_the_context_budget` tokenizes the system prompt plus exactly 3500
  characters and a full 24-item outline with the real tokenizer: 2197 + 1024 = 3221 ≤ 4096. The
  output margin (about 7 % at the cap) is the tightest constraint; an overflow is rejected as
  `finish` and fails closed.
- **No `reorganize_timeout`.** p95 at 3500 characters is 15.6 s, under the 20 s target and the
  30 s `structure_timeout` that bounds the pass, and well under the client's 50 s.
- Recommended client constants are unchanged from the issue: `maxReorganizeChars` 3500,
  client timeout 50 s, `reorganizeEveryChars` 1200, `reorganizeMinInterval` 180 s,
  `reorganizeRetryAfter` 60 s.

**Corrections never wait behind a reorganize.** The helper runs one generation at a time, and a
reorganize at the cap generates for about 15 s, longer than a dictation's whole 8 s budget.
Measured with the three largest documents, sending a correction 1 s into the reorganize, three
times each:

| Correction arriving during a reorganize | Runs | Budget | p50 (ms) | max (ms) | Within budget |
|---|---:|---:|---:|---:|---:|
| Dictation (`default`), yield-only priority | 9 | 8 s | 8002 | 8002 | 0/9 (all `timeout`) |
| Live Notes segment (`live_notes`), yield-only priority | 9 | 15 s | 15002 | 15028 | 3/9 |
| Dictation, reorganize preemptible (shipped) | 9 | 8 s | 1658 | 2241 | **9/9** |
| Live Notes segment, reorganize preemptible (shipped) | 9 | 15 s | 1982 | 2030 | **9/9** |

So `reorganize` has its own helper priority: like structuring it never starts while corrections
are queued, and in addition a running reorganize is abandoned the moment a correction queues. The
helper is killed (dropping the late reply), the correction reloads it (included in the times
above; cold load with cached weights is about 1-2 s), and the reorganize answers `timeout`; the
client retries after `reorganizeRetryAfter`. Structuring passes keep v1 behaviour (never
interrupted, at most 768 tokens), and dictation requests are unchanged.

Reproduce (cached weights only):

```sh
cd server
uv run python scripts/bench_notes.py --mode reorganize --repetitions 1 --dump /tmp/reorg-out.jsonl
uv run python scripts/bench_notes.py --mode reorganize --repetitions 1 --max-chars 2500 --no-priority
uv run pytest -q -m model tests/test_notes_reorganize.py
```

`--max-chars` adds rows with the trailing whole sections the client would send for documents above
it; `--no-priority` skips the correction-during-reorganize check. Metrics, the tuning steps and the
yield-only priority figures are in [notes-reorganize.json](bench-data/notes-reorganize.json).

## Notes review fixes and talk-style structuring (2026-10-20)

Server follow-up to the `feat/notes-edit` review (issue #17 comment), on the same machine and model
(`qwen3-4b-instruct-2507-4bit`, warm, temperature 0, 1-minute load about 2.5-3). Every failure
response of `/v1/notes/structure` and `/v1/notes/reorganize` now carries `reason`, the name of the
guard that rejected it, which is also in the log line. The histograms below are those names.

**Talk-style set.** Real use showed about every other append failing on a long product talk.
`server/tests/notes_talk_eval.jsonl` imitates it: 20 invented windows (15 from three conference talks
about an AI crypto-trading product, 5 from product and ops meetings) of 1650-3560 characters, each
2-4 ASR segments of 40-90 s. The speech is raw recognition output with fillers and restarts,
invented product and company names misheard inconsistently ("Kestrel" as "Castrel"/"Kestral",
"Novalith" as "Nova lith"/"Novalit", "Crockbot", "SuperTick", "X Crypto Cycle"), trading jargon,
numbers spoken as words ("six months back", "four point two million", "three hundred million") and
incidental negations ("still doesn't feel proactive enough"). As the app does, each segment goes
through the `live_notes` clean-up first (raw text when it fails closed), then the joined window is
structured (`--set talk`).

| Talk set | Runs | p50 (ms) | p95 (ms) | Output tokens p50 / max | Passed | Rejected by |
|---|---:|---:|---:|---:|---:|---|
| Before (review head) | 20 | 5384 | 7019 | 312 / 436 | 13/20 (65 %) | `name` 4, `number` 3 |
| After | 20 | 5689 | 7199 | 343 / 453 | **15/20 (75 %)** | `name` 2, `number` 2, `negation` 1 |

The `live_notes` clean-up of the talk segments failed closed on 20 of 59 (34 %, against 1 of 23 on
the messy product-feedback set), so a third of these windows were structured from raw text with
fillers. That is a separate, clean-up-side cause and is not changed here.

What the `name` and `number` rejections were, and what changed:

- **False positives, fixed.**
  - `## API Docs And Cuts`: the model reused a heading from the request's outline (the client's
    own earlier headings), which the guard compared with the transcript only. The outline now
    licenses names, numbers and dates; overlap and flips still compare with the transcript.
  - `**Decided to kill** the voice version`: a bold phrase opening a line is sentence case when
    the rest is lowercase. A single bold word ("**Sarah**") is still checked as a name.
  - `$300M` for a spoken "three hundred million": abbreviated scales (`k`, `M`, `B`) read as the
    scaled value. `$400M` or a bare `300` still fail. Tokens with digits ("300M") are left to the
    number guard instead of also counting as capitalised names.
- **Real inventions, still rejected:** "monitors X (formerly Twitter)" and "~$300M AUM" (background
  knowledge), "100% confidence" (never said), "$20,000" for a spoken "up from twenty" (an inferred
  scale), and in the messy set an invented example "(e.g., 03/04 instead of 04/03)". One remaining
  judgement call: a single bold verb opening a line (`**Anticipate** email …`) cannot be told from a
  bold name.
- **The one false `negation`:** "Home screen is the problem" next to "they asked why it wasn't on
  the home screen". Exempting "why … wasn't" would also let a real flip of that statement through,
  so it stays.
- **Prompt:** structuring now says to spell names exactly as transcribed, even when they look
  misheard, and never to add background knowledge or remarks like "(incomplete)". The greedy
  outputs did change: the messy set went from 11/11 to 10/11 (the invented example dates above),
  and the clean set stayed at 15/16 (the 4000-character `finish`).

Structuring negatives: 32/32 rejected. Messy set 10/11, clean set 15/16 (p95 12.4 s at 4000
characters, unchanged).

**Reorganize guards after the review** (same fixtures; one run each):

- A negated line must stay negated ("not hire" may not become "maybe hire"); a hedged one may stay
  hedged or become negated, and "not sure"/"don't know" count as hedges.
- A number may not move to a line that a line without it matches better (swapped quotes); merged
  and split lines keep their numbers. A first version that required each number on the single
  best-matching line rejected three faithful splits of shorthand lines (10/12 → 7/12) and was
  replaced.
- A task keeps its people (bold names and a capitalised owner): `task_owner`.
- `dont`/`wont`/`cant`/`didnt`/`isnt` and similar count as negations, and negation words are left
  out of the coverage word counts ("dont" → "don't" is not a dropped word).
- The flip check skips output lines whose source line already reads as a flip within the notes
  ("Book the venue for June" next to "Do not book the venue before the deposit clears").
- `[correction] reorganize_timeout` (default 45 s) bounds the pass instead of `structure_timeout`.
- A preempted reorganize answers `error: "preempted"` (not `timeout`); the client treats it as not
  run.

| Reorganize | Before review | After |
|---|---:|---:|
| Valid, 3500-character cap | 10/12 | 10/12 |
| Valid incl. 2500 client scope rows | 15/18 | 15/18 |
| Negatives (78 old + 6 from the review: negation to hedge, swapped quotes and dates, dropped owners) | 78/78 | **84/84** |
| Corrections during a reorganize within budget (dictation / segment) | 9/9 / 9/9 | 9/9 / 9/9 (p50 1718 / 2032 ms) |

Reproduce:

```sh
cd server
uv run python scripts/bench_notes.py --set talk --repetitions 1 --dump /tmp/talk-out.jsonl
uv run python scripts/bench_notes.py --set messy --repetitions 1
uv run python scripts/bench_notes.py --mode reorganize --repetitions 1
```

Metrics are in [notes-talk.json](bench-data/notes-talk.json).

## Live Notes clean-up on talk-style speech (2026-10-20)

The talk set (previous section) showed the `live_notes` segment clean-up failing closed on 20 of 59
segments (34 %, against 1 of 23 on the messy set). Those segments reach structuring as raw text
full of fillers. `bench_notes.py --mode cleanup` runs the clean-up on every talk segment and every
messy segment cut at 675 characters, exactly as the server does, and keeps the model output to
find the first edit `notes_faithful` cannot license. Same machine and model, temperature 0.

The 20 talk failures, by the edit that blocked them:

| Cause | Segments | Change |
|---|---:|---|
| "I think" / "I guess" dropped mid-sentence, mostly before a number ("about, I think, two hundred") | 8 | Hedges stay protected. Two prompt rewrites ("never fillers", two examples) did not change the model's output, so the clean-up now **puts the hedge back** at its aligned position when that is the only unlicensed edit, and the result must pass the unchanged guard |
| Restarts the guard did not know | 6 | Licensed, below |
| Real changes: content dropped after "sorry", "it says" dropped, a misheard name respelled ("hal sion" → "halcyon"), words reordered, "it's it keeps" → "it's keeps", the aside "the word was" dropped, "and and" dropped entirely | 6-7 | Still rejected |

Licensed restarts (all in `notes_faithful`, used only by the hidden `live_notes` style):

- a repeated phrase that contains a number word but is not all numbers ("one of the, one of the");
  "twenty twenty six" is still a number;
- repeats with a filler *phrase* between the copies, as with single fillers ("a kind of a a");
- an article swapped for another ("do a, an actual launch");
- either copy of a short repeated subject, up to two words apart ("it's just, it's not", "there's
  only, there's six"); the words in between stay;
- up to four words the speaker takes back with "sorry", and the marker ("hal sion, sorry,
  halcyon"). Never after "I'm/so/really …" or before "for/about/to/that/…" (an apology), and never
  when the span holds a number or a negation.

The prompt also now says to keep names exactly as transcribed, even when they look misheard.

| Clean-up, `live_notes` | Before | After |
|---|---:|---:|
| Talk segments failing closed | 20/59 (34 %) | **7/59 (11.9 %)**, 4 of the passes by restored hedges |
| Messy segments failing closed | 1/23 | 1/23 (the model drops "the other one", correctly rejected) |
| Dictation-style `default` on the messy segments (comparison, unchanged guard) | 4/23 passed | 4/23 passed |
| Talk structuring after clean-up | 15/20 | **16/20** |
| Messy structuring | 10/11 | 10/11 |
| Structuring negatives | 32/32 | 32/32 |

**The ≤ 10 % target is not met** (11.9 %): every remaining failure is an output that is not a
deletion of the input (a reorder, a respelled name, dropped attribution or content), and licensing
those would let the clean-up change what was said. Clean-up latency is unchanged (p50 2.4 s, p95
3.1 s for 854-character segments). Dictation correction (`default` and the other profiles) and its
guards are untouched.

Reproduce:

```sh
cd server
uv run python scripts/bench_notes.py --mode cleanup --dump /tmp/cleanup-out.jsonl
uv run python scripts/bench_notes.py --set talk --repetitions 1
```

Metrics are in [notes-cleanup-talk.json](bench-data/notes-cleanup-talk.json).

## Speaker labels (Mac Live Notes)

2026-10-20, M5 Pro, macOS 27.0.1, issue #18 M1. `mac/scripts/speaker-bench` drives the **real Live Notes path**:
50 ms frames from a WAV into `NotesRecorder.handleFrame`, the real `NotesSegmenter` (12–45 s segments), rolling
`/v1/stream` sockets with `word_timings` to a local chirp-server (Parakeet MLX), and one `SortformerSpeakerDiarizer`
per document (FluidAudio 0.17.7, Sortformer v2.1 streaming, `fast` config, ~1 s latency). Word attribution uses the
real Parakeet words of the labelled transcript, aligned by text to the reference words (the clip script, or the AMI
word-level annotations), each segment only against its own stretch of audio. No audio is committed.

**Choice: the 6-bit palettized model** (106 MB on disk, against 229 MB for fp16). It matched fp16 on AMI and did
better on the hardest synthetic clip, so the app downloads it. All gate numbers below are the palettized model.

### Gates

| gate | result | |
|---|---|---|
| Word attribution ≥ 97 %, synthetic, 2–4 distinct voices | 2–3 voices 99.5–100 %; 4 voices 98.4–100 % on 4 of 5 conversations, **93.5 %** on one | ✗ one clip |
| Speaker count right on every clip with ≤ 4 speakers | every synthetic clip and every AMI meeting (4 of 4) | ✓ |
| AMI headset confusion ≤ 3 % | 0.4–2.2 % on 3 meetings, **6.7 %** on IS1009a | ✗ one meeting |
| AMI far-field confusion ≤ 6 % | 1.4 %, 3.8 %; **6.8 %** (ES2014a), **10.5 %** (IS1009a) | ✗ two meetings |
| AMI word attribution (report) | headset 89–98 %, far-field 83–97 % of the words the transcript recovered | |
| Label lag (final → turns) p95 ≤ 2.5 s, live | 0.87–1.34 s; none waited for the 3 s timeout | ✓ |
| Segment text at final, no added latency | text commits at the final as before; labels attach after | ✓ |
| Diarizer ≤ 5 % of real time | 3.2–4.4 % of the audio's duration in the model (mostly ANE); the whole bench process 1.9–2.3 % CPU live | ✓ |
| Added RSS ≤ 300 MB | 47–106 MB steady (the first download and CoreML compile peaks at 487 MB once) | ✓ |
| 60-min 3-voice session, no identity swap | 99.9 % words, worst 10-minute window 99.6 %, 3 people | ✓ |
| Record → Stop (10 s) → Record keeps Person numbers | the same 3 people; 96.7 % words (a few words at the restart) | ✓ |

### Synthetic (`say` voices, -40/-45 dBFS noise), live

| clip | min | DER | confusion | people (truth) | words | label lag p50 / p95 s |
|---|---|---|---|---|---|---|
| two_distinct | 1.4 | 0.0 | 0.0 | 2 (2) | 99.5 | 0.72 / 0.87 |
| three_mixed, Record → Stop 10 s → Record | 1.4 | 3.0 | 2.9 | 3 (3) | 96.7 | 0.75 / 1.04 |
| two_long | 6.6 | 0.0 | 0.0 | 2 (2) | 100.0 | 1.02 / 1.34 |
| four_distinct (seed 7) | 2.0 | 5.2 | 5.2 | 4 (4) | 93.5 | 0.95 / 1.24 |
| four_distinct seeds 1 / 2 / 3 (4×) | 2.0 | 0.0 / 0.9 / 0.0 | 0.0 / 0.9 / 0.0 | 4 (4) | 99.7 / 98.4 / 100.0 | |
| three_60min (6×) | 60.8 | 0.1 | 0.1 | 3 (3) | 99.9 | |

In four_distinct seed 7 two of the four voices speak only a few short turns; fp16 merged the two female and the two
male voices there (3 people, 64.4 % words), the palettized build keeps 4 apart with some confusion. Sortformer's
`balanced` config (a 188-frame FIFO, same latency) finds 4 people with fp16 but still 75 % words at 2.5× the model
time and ~280 MB, so the app keeps `fast`. On the spike's own four_distinct clip this pipeline reproduces the spike
exactly (DER 0.0, 99.7 % words).

### AMI (CC-BY-4.0), 4 people each, 6× real time

DER % (miss / confusion) and word attribution; `aligned` is the share of reference words the transcript recovered
at all (overlaps and backchannels are often not transcribed).

| meeting | min | headset DER (miss / conf.) | words | aligned | far-field DER (miss / conf.) | words | aligned |
|---|---|---|---|---|---|---|---|
| ES2004a | 17.5 | 25.5 (24.6 / **0.7**) | 95.0 | 78.7 | 32.4 (27.3 / **3.8**) | 91.8 | 66.1 |
| ES2014a | 19.2 | 34.6 (30.8 / **2.2**) | 97.3 | 82.2 | 41.6 (30.5 / **6.8**) | 90.0 | 74.0 |
| IS1009a | 14.0 | 25.8 (17.1 / **6.7**) | 89.1 | 75.9 | 30.5 (17.2 / **10.5**) | 82.8 | 72.5 |
| TS3003a | 25.1 | 34.1 (33.4 / **0.4**) | 98.0 | 80.5 | 36.9 (35.3 / **1.4**) | 96.8 | 65.6 |

fp16 on the same meetings: headset confusion 0.8 / 2.9 / 7.3 / 0.2 % (words 95.2 / 95.3 / 87.5 / 98.2), far-field
4.1 / 10.8 / 6.2 / 1.6 % (words 93.2 / 82.9 / 89.1 / 96.8): the same picture, within noise of the palettized build.
Miss is Sortformer's known weakness (overlaps and short backchannels); for labels it costs little, because the words
it misses still get the nearest settled speaker. IS1009a is the hard meeting for both builds: similar voices merge
for stretches, which M2's merge/reassign is for.

### Cost and packaging

- Model: first download plus CoreML compile 22.9 s (106 MB, pinned Hugging Face revision `ae9a27ab`); warm load
  0.09–0.17 s. The app loads it at the first labelled Record and drops it on New.
- Binary: `ChirpMac` release grows from 4.2 MB to 14.6 MB (2.2 → 8.7 MB stripped), plus FluidAudio's 1.0 MB resource
  bundle. FluidAudio is linked with no traits, so its prebuilt NeMo text-normalization binary is not linked; it offers
  no finer switch for the ASR/TTS code we do not use.
- FluidAudio and `ChirpSpeakers` build with the Command Line Tools only. The full app's CLT-only build was already
  failing on `main` before this change (`NotesView`'s `@State` needs the SwiftUI macro plugin, which the CLT lack).

### Structuring with labels (server prompt rule)

The structuring prompt gained one rule (attribute owners, decisions, questions and disagreements; never invent a
name for `Person N`; keep labels as written) and one labelled example. Same Qwen3-4B helper as above:

| set | before (#19) | with the rule | p50 ms |
|---|---|---|---|
| clean (`notes_eval.jsonl`) | 15/16 | 15/16 | 4240 (was 4215) |
| messy (`notes_messy_eval.jsonl`) | 11/11 | 11/11 | 1832 (was 1726) |
| negatives (must be rejected) | 32/32 | 32/32 | |
| labelled (`notes_labelled_eval.jsonl`, new, 5 invented meetings) | | 5/5 | 1179 |

On the labelled set, action owners come out as `- [ ] **Person 2** to … by **Friday**` and a renamed `Maya:` keeps
her name. The model still prefixes every bullet with its speaker in 2 of 5 outputs despite the rule, and once put
a question's answer under the person who asked it: prompt follow-ups. Guards reject a `Person 7` that never spoke
(number guard) and an invented name (name guard).

```sh
uv run python scripts/bench_notes.py --set labelled --repetitions 1 --dump /tmp/notes-labelled.jsonl
```

## Android real-device session timings

Not yet measured. Android keeps content-free per-session timings (Setup → Diagnostics); paste the Wi-Fi and LTE summaries from the [real-device checklist](android-device-acceptance.md) here, with the device, Chirp version, engine and `battery-session.sh` rows. Until then every Android latency and battery figure is emulator-only (TBM).
