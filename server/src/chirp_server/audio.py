"""Koi's standard-library WAV validation, with no temporary files."""

import io
import wave

import numpy as np

RATE = 16000
MAX_SECONDS = 120
MAX_PCM = RATE * 2 * MAX_SECONDS
MAX_FRAME = 1_000_000


class AudioError(ValueError):
    def __init__(self, code: str = "bad_audio"):
        self.code = code
        super().__init__(code)


def decode_wav(body: bytes) -> bytes:
    try:
        with wave.open(io.BytesIO(body), "rb") as audio:
            frames = audio.getnframes()
            if frames > RATE * MAX_SECONDS:
                raise AudioError("too_long")
            if (
                audio.getnchannels(),
                audio.getsampwidth(),
                audio.getframerate(),
                audio.getcomptype(),
            ) != (1, 2, RATE, "NONE") or frames <= 0:
                raise AudioError()
            pcm = audio.readframes(frames)
            if len(pcm) != frames * 2:
                raise AudioError()
            return pcm
    except (wave.Error, EOFError) as exc:
        raise AudioError() from exc


def samples(pcm: bytes) -> np.ndarray:
    return np.frombuffer(pcm, dtype="<i2").astype(np.float32) / np.float32(32768)


def levels(pcm: np.ndarray) -> tuple[float, float]:
    if not pcm.size:
        return 0.0, 0.0
    return float(np.max(np.abs(pcm))), float(np.sqrt(np.mean(pcm * pcm)))


def silent(pcm: np.ndarray) -> bool:
    peak, rms = levels(pcm)
    return peak < 0.001 and rms < 0.0002


def wav_bytes(pcm: bytes) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        audio.writeframes(pcm)
    return output.getvalue()
