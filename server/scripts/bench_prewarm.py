"""First-final cleanup latency after an idle unload, with and without start prewarm.

Runs the real cached cleanup helper over the actual WebSocket path with a fake ASR
engine, so the numbers isolate managed cleanup from ASR. Cached-only; never
downloads weights. Each measured utterance follows an idle unload, so the helper
starts cold: prewarm overlaps the cold load with ~3 s of speech, no-prewarm pays it
inside the final.
"""

import argparse
import json
import os
import statistics
import tempfile
import time
from pathlib import Path

import numpy as np
from starlette.testclient import TestClient

from chirp_server.app import create_app
from chirp_server.cleanup_models import DEFAULT_MODEL
from chirp_server.config import CorrectionConfig, Settings
from chirp_server.correction import Corrector
from chirp_server.engine import FakeEngine

RAW = "um, so, please send the, uh, project schedule tomorrow"
PCM = (np.sin(np.arange(8000) * 0.1) * 10000).astype("<i2").tobytes()
START = {
    "type": "start",
    "sample_rate": 16000,
    "encoding": "pcm_s16le",
    "client": "mac",
    "correction": True,
}
TOKEN = "bench-credential"
HEADERS = {"Authorization": f"Bearer {TOKEN}"}


def build(temp, idle_seconds, prewarm):
    config = CorrectionConfig(
        mode="managed", model=DEFAULT_MODEL, timeout=8.0, idle_seconds=idle_seconds
    )
    corrector = Corrector(config)
    if not prewarm:
        # The "before" variant: the helper only loads inside the final.
        corrector.managed.prewarm = lambda: None
    settings = Settings(
        config_dir=Path(temp) / "config",
        debug_dir=Path(temp) / "debug",
        state_path=Path(temp) / "state" / "server-state.json",
        idle_seconds=30,
        correction=config,
    )
    return corrector, create_app(settings, FakeEngine(RAW), TOKEN, corrector)


def utterance(client, speech_seconds):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START)
        assert ws.receive_json()["type"] == "ready"
        if speech_seconds:
            time.sleep(speech_seconds)  # the user is speaking; prewarm overlaps this
        ws.send_bytes(PCM)
        stopped = time.perf_counter()
        ws.send_json({"type": "stop"})
        while True:
            message = ws.receive_json()
            if message["type"] == "final":
                return message, (time.perf_counter() - stopped) * 1000


def wait_unloaded(managed, idle_seconds, deadline=20):
    time.sleep(idle_seconds + 0.2)
    end = time.perf_counter() + deadline
    while managed.process is not None and time.perf_counter() < end:
        time.sleep(0.05)
    assert managed.process is None, "helper did not idle-unload"


def measure(label, prewarm, runs, speech_seconds, idle_seconds):
    stop_ms, correction_ms, corrected, fallbacks, loads = [], [], 0, 0, []
    with tempfile.TemporaryDirectory() as temp:
        corrector, app = build(temp, idle_seconds, prewarm)
        managed = corrector.managed
        with TestClient(app) as client:
            # Warm the helper once, then let it idle-unload so each measured
            # utterance starts cold.
            utterance(client, 0)
            wait_unloaded(managed, idle_seconds)
            for _ in range(runs):
                message, wall = utterance(client, speech_seconds)
                assert message["raw"] == RAW
                stop_ms.append(wall)
                correction_ms.append(message["timings_ms"]["correction"])
                corrected += bool(message["corrected"])
                fallbacks += message["correction_error"] is not None
                loads.append(os.getloadavg()[0])
                wait_unloaded(managed, idle_seconds)
    return {
        "label": label,
        "speech_seconds": speech_seconds,
        "runs": runs,
        "stop_to_final_ms": {
            "median": round(statistics.median(stop_ms), 1),
            "min": round(min(stop_ms), 1),
            "max": round(max(stop_ms), 1),
        },
        "correction_ms": {
            "median": round(statistics.median(correction_ms), 1),
            "min": round(min(correction_ms), 1),
            "max": round(max(correction_ms), 1),
        },
        "corrected": corrected,
        "raw_fallbacks": fallbacks,
        "loadavg_min_max": [round(min(loads), 1), round(max(loads), 1)],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--speech-seconds", type=float, default=3.0)
    parser.add_argument("--idle-seconds", type=float, default=1.0)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("runs must be positive")
    for label, prewarm in (("no-prewarm", False), ("prewarm", True)):
        print(
            json.dumps(measure(label, prewarm, args.runs, args.speech_seconds, args.idle_seconds)),
            flush=True,
        )


if __name__ == "__main__":
    main()
