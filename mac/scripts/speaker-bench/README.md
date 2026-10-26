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

## Voice profiles (`VoiceBench`)

Measures saved-voice suggestions (issue #18 M3) with no server: `make_voice_clips.py` writes every pair of eight
neural `say` voices as a one-minute conversation into `~/Library/Caches/Chirp/speaker-bench/voices/`, and
`VoiceBench` feeds each through the app's `SortformerSpeakerDiarizer` with the app's `WeSpeakerEmbedder` (the 8 MB
model downloads into FluidAudio's cache on the first run), remembers each voice from its first conversation, and
scores the app's `VoiceMatch.suggest` over the rest with 4 voices saved and 4 unknown. Results:
[docs/bench.md](../../../docs/bench.md#voice-profiles-saved-voices-18-m3).

```sh
B=~/Library/Caches/Chirp/speaker-bench
uv run --no-project --with numpy python make_voice_clips.py $B/voices
swift run -c release VoiceBench --clips $B/voices --out $B/out/voices/rates.json
```

## Saved voices on the server (`VoiceAgreement`)

`server/scripts/bench_voices.py` benches recognition with the server's shared voice library (#247): thresholds for
the server's WeSpeaker ResNet34-LM over the same `say` conversations plus four AMI meetings, and the agreement
spike between that model and the Mac's `wespeaker_v2`. `VoiceAgreement` is the Mac side of the spike: it embeds
every WAV in a folder with the app's `WeSpeakerEmbedder` (offline; the 8 MB model must already be downloaded).
Results: [docs/bench.md](../../../docs/bench.md#saved-voices-server-247).

```sh
B=~/Library/Caches/Chirp/speaker-bench   # voices/ from make_voice_clips.py, ami/ from fetch_ami.sh
S="uv run python scripts/bench_voices.py --model <the pinned ONNX> --clips $B/voices --ami $B/ami --spike $B/spike"
(cd ../../../server && $S --spike-only)   # writes the spike's clips
swift run -c release VoiceAgreement --clips $B/spike/clips --out $B/spike/mac.json
(cd ../../../server && $S --mac-embeddings $B/spike/mac.json --out $B/voices-bench.json)
```
