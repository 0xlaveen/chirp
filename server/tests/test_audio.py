import io
import wave

import pytest

from chirp_server.audio import AudioError, decode_wav


@pytest.mark.parametrize("body", [b"", b"invalid", b"RIFF\0\0\0\0WAVE", b"\0" * 64])
def test_malformed(body):
    with pytest.raises(AudioError):
        decode_wav(body)


def test_truncated(wav):
    with pytest.raises(AudioError):
        decode_wav(wav[:-20])


@pytest.mark.parametrize("channels,width,rate", [(2, 2, 16000), (1, 1, 16000), (1, 2, 48000)])
def test_format(channels, width, rate):
    out = io.BytesIO()
    with wave.open(out, "wb") as audio:
        audio.setparams((channels, width, rate, 0, "NONE", "not compressed"))
        audio.writeframes(b"\0" * 100)
    with pytest.raises(AudioError):
        decode_wav(out.getvalue())
