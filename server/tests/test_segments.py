"""Speech/pause boundaries yield frozen prefixes and only re-decode the uncommitted tail."""

import numpy as np

from chirp_server.engine.base import Partial
from chirp_server.engine.mlx import RollingStream


def test_pause_commit_and_tail_only_final():
    class RecordingEngine:
        finalization = "segments"

        def __init__(self):
            self.sizes = []

        def transcribe(self, pcm):
            self.sizes.append(len(pcm))
            if len(pcm) == 0:
                return ""
            return "First sentence." if np.max(pcm) < 0.2 else "Second sentence."

    engine = RecordingEngine()
    stream = RollingStream(engine)
    voice = np.full(16000, 0.1, dtype=np.float32)
    assert stream.feed(voice).stable == ""
    committed = stream.feed(np.zeros(6400, dtype=np.float32))
    assert committed == Partial("First sentence.", "First sentence.")
    live = stream.feed(np.full(8000, 0.3, dtype=np.float32))
    assert live.stable == "First sentence."
    assert live.text.startswith(live.stable)
    result = stream.finish()
    assert result == "First sentence. Second sentence."
    assert engine.sizes[-1] == 8000


def test_initial_silence_never_committed():
    assert RollingStream.pause_cut(np.zeros(16000, dtype=np.float32)) == 0


def test_short_gap_is_not_a_segment_boundary():
    audio = np.r_[np.ones(16000), np.zeros(3200), np.ones(16000)].astype(np.float32)
    assert RollingStream.pause_cut(audio) == 0


def test_pause_in_coalesced_chunk_keeps_new_speech():
    audio = np.r_[np.ones(16000), np.zeros(6400), np.ones(8000)].astype(np.float32)
    assert RollingStream.pause_cut(audio) == 22400
