#!/bin/sh
# Fetches the AMI test meetings the bench uses (CC-BY-4.0, groups.inf.ed.ac.uk/ami): headset mix and far-field array
# mic, the pyannote AMI-diarization-setup RTTMs, and the word-level manual annotations. Never committed.
set -u
B=${CHIRP_SPEAKER_BENCH:-$HOME/Library/Caches/Chirp/speaker-bench}/ami
mkdir -p "$B" && cd "$B" || exit 1
for m in ES2004a IS1009a TS3003a ES2014a; do
  for kind in Mix-Headset Array1-01; do
    [ -s "$m.$kind.wav" ] || curl -sfL -o "$m.$kind.wav" "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/$m/audio/$m.$kind.wav"
  done
  for set in test dev train; do
    [ -s "$m.rttm" ] || curl -sfL -o "$m.rttm" "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/$set/$m.rttm"
  done
done
[ -s ami_public_manual_1.6.2.zip ] || curl -sfL -o ami_public_manual_1.6.2.zip "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"
unzip -q -o ami_public_manual_1.6.2.zip 'words/ES2004a*' 'words/ES2014a*' 'words/IS1009a*' 'words/TS3003a*' -d ann
