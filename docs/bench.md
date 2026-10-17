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
