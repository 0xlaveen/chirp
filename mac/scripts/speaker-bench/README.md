# Speaker-label bench

Measures Live Notes speaker labels (issue #18) through the shipped code: `SpeakerBench` links the app's `ChirpCore`
and `ChirpSpeakers`, feeds a WAV as 50 ms capture frames into the real `NotesRecorder` (real `NotesSegmenter` cuts,
rolling `/v1/stream` sockets with `word_timings` to a local chirp-server, one Sortformer diarizer per document), and
writes the labelled document, the diarizer's spans, label lags and costs as JSON. `score.py` scores them.

No audio is committed. Everything lives in `~/Library/Caches/Chirp/speaker-bench/`:

- synthetic conversations from macOS `say` voices with ground truth (`make_clips.py`, from the #18 spike);
- AMI meetings ES2004a, IS1009a, TS3003a, ES2014a (CC-BY-4.0), headset mix and far-field array mic, with the
  pyannote AMI-diarization-setup RTTMs and the AMI word-level annotations (`fetch_ami.sh`).

```sh
./fetch_ami.sh
# a throwaway local server with the MLX engine (word timings), its own HOME and token:
H=$(mktemp -d); (cd ../../../server && HOME=$H uv run chirp-server --port 7911 --model-dir ~/.koi/voice-models/parakeet-mlx) &
./run.sh http://127.0.0.1:7911 $H/.config/chirp/token
```

`run.sh` runs the synthetic clips live (label lag is only meaningful in real time), a Record → Stop (10 s) → Record
continuity run, the AMI meetings and the hour-long three-voice session faster than live (6×; the diarizer keeps up),
and the fp16 build for comparison, then prints the tables recorded in
[docs/bench.md](../../../docs/bench.md#speaker-labels-mac-live-notes).

Word attribution aligns the transcript's raw words (real Parakeet words, real segments) to the reference words by
text, so it needs no forced alignment; a word scores when its Person maps to the reference speaker under the best
one-to-one mapping. `aligned` is the share of reference words the transcript recovered at all.
