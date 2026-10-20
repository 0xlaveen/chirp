#!/bin/sh
# The Live Notes speaker-label bench (docs/bench.md, Speaker labels). Needs a local chirp-server with the MLX engine
# (word timings) and its token. Audio lives in ~/Library/Caches/Chirp/speaker-bench and is never committed: synthetic
# clips from `say`, and AMI meetings (CC-BY-4.0) fetched by fetch_ami.sh.
#
#   run.sh http://127.0.0.1:7911 /path/to/token
set -eu
SERVER=$1
TOKEN=$2
HERE=$(cd "$(dirname "$0")" && pwd)
B=${CHIRP_SPEAKER_BENCH:-$HOME/Library/Caches/Chirp/speaker-bench}
OUT=$B/out
(cd "$HERE" && swift build -c release -q)
BIN=$HERE/.build/release/SpeakerBench
if [ ! -s "$B/clips/three_60min_seed60.wav" ]; then
    uv run -q --no-project --with numpy python "$HERE/make_clips.py" "$B/clips"
    for seed in 1 2 3; do CHIRP_CLIP_SEED=$seed uv run -q --no-project --with numpy python "$HERE/make_clips.py" "$B/clips" four_distinct; done
    CHIRP_CLIP_SEED=60 uv run -q --no-project --with numpy python "$HERE/make_clips.py" "$B/clips" three_60min
fi
bench() { "$BIN" --server "$SERVER" --token "$TOKEN" "$@"; }
C=$B/clips
SYNTH="$C/two_distinct.wav $C/three_mixed.wav $C/four_distinct.wav $C/two_long.wav"
SEEDS="$C/four_distinct_seed1.wav $C/four_distinct_seed2.wav $C/four_distinct_seed3.wav"
mkdir -p "$OUT/live" "$OUT/seeds" "$OUT/ami" "$OUT/long" "$OUT/fp16-synthetic" "$OUT/fp16-ami"
# The app's model. Real time first: the label lag is only meaningful live. Then Record → Stop (10 s) → Record.
bench --out "$OUT/live" --speed 1 $SYNTH
bench --out "$OUT/live" --speed 1 --restart-at 40 --gap 10 "$C/three_mixed.wav"
# Faster than live for accuracy and cost on long audio (the diarizer keeps up; lags are not representative).
bench --out "$OUT/seeds" --speed 4 $SEEDS
bench --out "$OUT/ami" --speed 6 "$B"/ami/*.Mix-Headset.wav "$B"/ami/*.Array1-01.wav
bench --out "$OUT/long" --speed 6 "$C/three_60min_seed60.wav"
# The fp16 build, for comparison.
bench --out "$OUT/fp16-synthetic" --precision fp16 --speed 1 $SYNTH
bench --out "$OUT/fp16-ami" --precision fp16 --speed 6 "$B"/ami/*.Mix-Headset.wav "$B"/ami/*.Array1-01.wav
score() { uv run -q --no-project --with numpy --with scipy python "$HERE/score.py" "$@"; }
for d in live seeds long fp16-synthetic; do echo "## $d"; score "$C" "$OUT/$d"; done
for d in ami fp16-ami; do echo "## $d"; score "$B/ami" "$OUT/$d" "$B/ami/ann/words"; done
