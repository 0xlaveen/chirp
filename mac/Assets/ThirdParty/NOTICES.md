# Chirp for Mac: third-party notices

Chirp's own code has no third-party dependencies except the one below, used only for Live Notes speaker labels.

## FluidAudio 0.17.7

<https://github.com/FluidInference/FluidAudio>, Apache License 2.0: the full text is in
`FluidAudio/LICENSE.txt` next to this file. FluidAudio's own third-party licences (fastcluster, VBx and the
others it vendors) are in `FluidAudio/ThirdPartyLicenses/`. Chirp links FluidAudio without its
`NemoTextProcessing` trait, so that prebuilt binary is not part of the app. Chirp does not modify FluidAudio.

## Speaker model (downloaded on first use, not bundled)

"Sortformer CoreML Models" (`v3/palettized/Sortformer_v2.1.mlmodelc`) by FluidInference,
<https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml> at revision
`ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`, licensed under Creative Commons Attribution 4.0 International
(CC BY 4.0, <https://creativecommons.org/licenses/by/4.0/>).

It is a CoreML conversion (6-bit palettized weights) by FluidInference of NVIDIA's Streaming Sortformer
`nvidia/diar_streaming_sortformer_4spk-v2.1` (<https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1>,
CC BY 4.0). Chirp downloads it unchanged, only after you choose Download, checks it against the pinned file hashes,
and runs it on this Mac only. No warranties are given by the licensors.

## Voice model (downloaded only if you turn on Recognize saved voices, not bundled)

"Speaker Diarization CoreML" (`wespeaker_v2.mlmodelc` only) by FluidInference,
<https://huggingface.co/FluidInference/speaker-diarization-coreml> at revision
`df2625ac79a7ac6b65ad868fee6d80f320da4232`, licensed under Creative Commons Attribution 4.0 International
(CC BY 4.0, <https://creativecommons.org/licenses/by/4.0/>).

It is a CoreML conversion by FluidInference of pyannote's WeSpeaker ResNet34 speaker-embedding model
(`pyannote/wespeaker-voxceleb-resnet34-LM`, CC BY 4.0), itself from the WeSpeaker project. Chirp downloads it
unchanged, only after you choose Download, checks it against the pinned file hashes, and runs it on this Mac only.
No warranties are given by the licensors.
