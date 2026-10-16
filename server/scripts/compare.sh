#!/bin/sh
# Run from server/. Metrics and generated fixtures live outside the repository.
set -eu
CHIRP_BENCH_CACHE="$HOME/Library/Caches/Chirp"
uv run python scripts/generate_fixtures.py
uv run python scripts/bench.py --precision float16 --output "$CHIRP_BENCH_CACHE/bench-mlx-fp16-incremental.json"
uv run python scripts/bench.py --precision bfloat16 --output "$CHIRP_BENCH_CACHE/bench-mlx-bf16-incremental.json"
uv run python scripts/bench.py --streaming rolling --output "$CHIRP_BENCH_CACHE/bench-mlx-fp32-rolling.json"
uv run --extra onnx python scripts/bench.py --engine onnx --streaming rolling --output "$CHIRP_BENCH_CACHE/bench-onnx-int8.json"
swiftc -parse-as-library -O scripts/apple_bench.swift -o "$CHIRP_BENCH_CACHE/apple-bench"
"$CHIRP_BENCH_CACHE/apple-bench" "$CHIRP_BENCH_CACHE/fixtures/synthetic-5s.wav" > "$CHIRP_BENCH_CACHE/bench-apple-status.json"
