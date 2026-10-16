"""Render committed numeric benchmark evidence; no recordings or recognized text are copied."""

import json
import shutil
import statistics
from pathlib import Path

cache = Path.home() / "Library/Caches/Chirp"
docs = Path(__file__).resolve().parents[2] / "docs"
evidence = docs / "bench-data"
evidence.mkdir(exist_ok=True)
files = [
    "bench-mlx-fp32-incremental.json",
    "bench-mlx-fp16-incremental.json",
    "bench-mlx-bf16-incremental.json",
    "bench-mlx-fp32-rolling.json",
    "bench-onnx-int8.json",
    "bench-mlx-final-production.json",
    "bench-mlx-paused-segments.json",
    "bench-paired-finalization.json",
    "bench-fluid.json",
    "bench-apple.json",
]
for name in files:
    shutil.copyfile(cache / name, evidence / name)
lines = [
    "# Chirp M1 measurements",
    "",
    "Measured 2026-10-17 on Apple M5 Pro, 64 GiB unified memory, "
    "18 logical CPUs, macOS 27.0.1 (26A434), Swift 6.4 Command Line Tools; no Xcode.",
    "",
    "The host was shared with active build/test workers. Recorded 1-minute load averages "
    "were approximately 25–57. These are observed contended results, not isolated performance "
    "budgets. Different rows were measured at different times; cross-engine speed rankings "
    "are provisional. CPU process peak RSS excludes some GPU allocations and out-of-process "
    "system speech services, so Apple’s low RSS is not its total system memory footprint.",
    "",
    "## Selected behavior",
    "",
    "Keep Parakeet MLX v2 fp32, rolling eight-second previews with upstream timestamped token "
    "merging, and full-quality final re-decode. Stop drops queued partial inference and feeds "
    "undecoded audio directly to finalization. Startup runs a real silent model decode on the "
    "same dedicated thread, bypassing the runtime silence guard.",
    "",
    "The final real uvicorn/root-path/WebSocket simulator check on the 5.85 s fixture measured "
    "196 ms first partial, **96 ms stop-to-final**, and 0.54 s model load plus actual decode "
    "warmup (a previous smoke measured 187/107 ms and 1.05 s). These short checks are "
    "observations, not a latency SLA. The full test path passed 62 protocol/privacy tests "
    "and 2 real-model tests. No service or Tailscale publication was installed.",
    "",
    "Model metadata was checked on Hugging Face on 2026-10-17. The newer "
    "[MLX Community v3 conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3) "
    "is multilingual; the selected English-only "
    "[v2 conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2) still resolves to "
    "pinned revision `8ae155301e23d820d82aa60d24817c900e69e487`. No model repository "
    "or floating revision is resolved at server startup.",
    "",
    "## Same-clip finalization comparison",
    "",
    "One loaded, actually warmed model; full vs segment modes run back-to-back on each exact "
    "WAV, two repetitions with order reversed. Medians below include any in-flight partial "
    "work at stop. Every streamed final had 0% normalized WER. Short continuous 5 s regression "
    "means pause precommit remains **opt-in** (`--finalization segments`). This deliberately "
    "leaves default `stable` empty; segment mode exposes only its frozen prefixes, and final "
    "correction suppresses them.",
    "",
    "| Fixture | Actual audio (s) | Full final (ms) | Segments final (ms) | 1-min load range |",
    "|---|---:|---:|---:|---:|",
]
paired = json.loads((cache / "bench-paired-finalization.json").read_text())["paired"]
for dataset in ("fixtures", "fixtures-paused"):
    manifest = json.loads((cache / dataset / "manifest.json").read_text())
    for target in (5, 15):
        rows = [r for r in paired if r["dataset"] == dataset and r["target_seconds"] == target]
        medians = [
            statistics.median(r["stop_to_final_ms"] for r in rows if r["mode"] == mode)
            for mode in ("full", "segments")
        ]
        loads = [r["load_average"][0] for r in rows]
        duration = next(r["seconds"] for r in manifest if r["target_seconds"] == target)
        lines.append(
            f"| {'Continuous' if dataset == 'fixtures' else '600 ms pauses'} {target} s "
            f"| {duration:.2f} | {medians[0]:.0f} | {medians[1]:.0f} "
            f"| {min(loads):.1f}–{max(loads):.1f} |"
        )
lines += [
    "",
    "Segment mode also matched full-decode 0% WER on the 60.15 s controlled-pause clip, "
    "committing 15 segments / 837 characters with 930 ms final latency before the later "
    "stop-priority optimization. This demonstrates bounded tails when pauses exist, but "
    "does not prove short-utterance latency non-regression.",
    "",
    "## Engine and streaming experiments",
    "",
    "Same synthetic sentence generator and continuous WAV set (5.85, 15.46, 60.45 s). Warm "
    "decode is median of three full decodes; punctuation/case are normalized for WER. "
    "These early experiments predate the actual startup warmup and stop-priority fix. Their "
    "`load_and_warm_seconds` field meant load plus the silence guard, not an actual GPU decode; "
    "use the final smoke and paired measurements for current startup/final behavior. Early "
    "per-feed streaming loops were paced but could fall behind inference; only evidence "
    "marked `coalesced:true` uses an independent real-time producer. Do not compare the "
    "early stop numbers to current protocol timings.",
    "",
    "| Variant | Audio (s) | Warm RTFx | WER (%) | Peak process RSS (MiB) |",
    "|---|---:|---:|---:|---:|",
]
for name, label in [
    ("bench-mlx-fp32-rolling.json", "MLX fp32 rolling"),
    ("bench-mlx-fp32-incremental.json", "MLX fp32 tuned native (rejected)"),
    ("bench-mlx-fp16-incremental.json", "MLX fp16 tuned native (rejected)"),
    ("bench-mlx-bf16-incremental.json", "MLX bf16 tuned native (rejected)"),
    ("bench-onnx-int8.json", "ONNX v2 int8 CPU"),
]:
    data = json.loads((cache / name).read_text())
    for clip in data["clips"]:
        lines.append(
            f"| {label} | {clip['audio_seconds']:.2f} | {clip['rtfx']:.1f} "
            f"| {clip['wer'] * 100:.2f} | {data['peak_rss_mib']:.0f} |"
        )
lines += [
    "",
    "Reduced precision did not establish a reproducible accuracy/latency improvement, "
    "so fp32 stays default. In parakeet-mlx 0.5.3, feeding fp16/bf16 directly into `get_logmel` "
    "reinterprets complex64 FFT values using the wrong element width (514 vs 257 bins); "
    "preprocessing therefore stays fp32 before casting model features.",
    "",
    "The low-lookahead native tuning `(128,16)` was a usage/quality failure, not evidence "
    "that the upstream streaming API is generally inaccurate. A sanity check reproducing "
    "[upstream’s streaming example]"
    "(https://github.com/senstella/parakeet-mlx#streaming-transcription) "
    "on the same short clip with one-second chunks and `(256,256)` context gave 0% WER "
    "(0 finalized / 43 draft tokens); `(128,16)` gave 52.94% WER. At 200 ms chunks, tuned "
    "context-only finals had 91–100% WER. Production’s optional native mode now buffers "
    "one-second chunks with upstream context; it never uses the rejected context-only final. "
    "Rolling stays default because it gives responsive, complete live text without needing "
    "the upstream 20.48 s right-context window.",
    "",
    "## Production-style continuous streaming before stop optimization",
    "",
    "Independent real-time producer, coalesced inference, complete transcript retained by "
    "timestamp merging. Final and last-partial WER were 0% at all lengths. This older snapshot "
    "includes work now skipped at stop; current short protocol timing is above.",
    "",
    "| Audio (s) | First partial (ms) | Changed-partial cadence (ms) | Stop→final (ms) |",
    "|---|---:|---:|---:|",
]
for c in json.loads((cache / "bench-mlx-final-production.json").read_text())["clips"]:
    lines.append(
        f"| {c['audio_seconds']:.2f} | {c['first_partial_ms']:.0f} "
        f"| {c['partial_cadence_ms']:.0f} | {c['stop_to_final_ms']:.0f} |"
    )
lines += [
    "",
    "## Swift candidates",
    "",
    "Both candidates run with CLT only. FluidAudio 0.17.7 compiled successfully; its explicit "
    "v2 CoreML model acquisition plus first load took 59.39 s. FluidAudio rows are median "
    "of three warm batch file decodes after a discarded warm decode. Apple rows are single "
    "file runs after prepare (33–107 ms). They are **not** real-time protocol measurements: "
    "first-partial cadence and stop→final are TBM for both Swift candidates. Apple's file "
    "first-result times are not microphone/live first-partial latency.",
    "",
    "| Candidate | Audio (s) | Batch decode (ms) | RTFx | WER (%) | Process RSS (MiB) |",
    "|---|---:|---:|---:|---:|---:|",
]
fluid = json.loads((cache / "bench-fluid.json").read_text())
for c in fluid["clips"]:
    lines.append(
        f"| FluidAudio v2 ANE | {c['audio_seconds']:.2f} | {c['decode_ms']:.0f} "
        f"| {c['rtfx']:.1f} | {c['wer'] * 100:.2f} | {fluid['peak_rss_mib']:.0f} |"
    )
for c in json.loads((cache / "bench-apple.json").read_text()):
    lines.append(
        f"| Apple SpeechAnalyzer | {c['audio_seconds']:.2f} | {c['decode_ms']:.0f} "
        f"| {c['rtfx']:.1f} | {c['wer'] * 100:.2f} | {c['peak_rss_mib']:.0f} |"
    )
lines += [
    "",
    "FluidAudio is a promising follow-up for longer recordings; the contended 15 s outlier "
    "and lack of a live-protocol comparison prevent a defensible default flip. MLX now "
    "finalizes the 5.85 s protocol fixture in 96–107 ms, comparable to FluidAudio’s 98 ms "
    "batch-only result. Apple trades some synthetic accuracy for speed. No new Swift bridge "
    "or runtime permission dependency is added to the production server.",
    "",
    "## Reproduce and remove artifacts",
    "",
    "```sh",
    "cd server",
    "uv sync --locked --all-extras",
    "uv run python scripts/generate_fixtures.py",
    "uv run python scripts/generate_fixtures.py --pause-ms 600 "
    '--output "$HOME/Library/Caches/Chirp/fixtures-paused"',
    "uv run python scripts/bench.py",
    "uv run python scripts/compare_finalization.py",
    "uv run python scripts/native_sanity.py",
    "uv run --extra onnx python scripts/bench.py --engine onnx",
    "uv run python scripts/bench.py --with-fluidaudio --with-apple",
    "uv run python scripts/smoke.py",
    "uv run python scripts/render_bench.py",
    "```",
    "",
    "Model/alternate downloads require the explicit commands/flags documented in "
    "[server/README.md](../server/README.md#explicit-optional-downloads-and-cleanup). "
    "Default server/bench startup never downloads missing recognition models. Apple "
    "benchmarking checks already installed assets and never asks for authorization or "
    "installs assets. The initial explicitly requested M1 model probe downloaded only "
    "the en-US speech model via AssetInventory; it did not call TCC request APIs or use a "
    "microphone. No permissions, services, or Tailscale configuration were changed.",
    "",
    "Synthetic WAVs, candidate source/build/models and raw numeric results live under "
    "`~/Library/Caches/Chirp/` and may be deleted together. Apple assets are macOS-managed; "
    "use OS asset/storage controls. Only numeric benchmark evidence is committed in "
    "[bench-data/](bench-data/); no audio or recognized text is retained. These synthetic "
    "fixtures do not establish WER on accents, spontaneous speech or microphone noise. "
    "Natural recorded fixtures, isolated-host comparisons and Swift live-protocol latency "
    "remain TBM, with no production latency budget claimed.",
    "",
]
(docs / "bench.md").write_text("\n".join(lines))
