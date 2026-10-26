"""Live Notes speaker labels (#187): features, clustering, the note's speakers, attribution,
the `start.speakers` / `final.speakers` protocol, the model endpoint and the logs."""

import asyncio
import logging
import os
import shutil
import subprocess
import sys
import time
import wave
from pathlib import Path

import numpy as np
import pytest
from conftest import HEADERS, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server import speakers as sp
from chirp_server import speakers_model
from chirp_server.app import create_app
from chirp_server.config import CorrectionConfig
from chirp_server.correction import CorrectionResult
from chirp_server.engine import FakeEngine, Word

SESSION = "note-0123456789abcdef"
LABELLED = {**START, "client": "android", "speakers": {"session": SESSION}}
WORDS = " ".join(f"w{i}" for i in range(20))  # 20 fake words, 300 ms apart: 6 s


def tone(freq, seconds, amplitude=0.3):
    t = np.arange(int(seconds * sp.RATE)) / sp.RATE
    return (amplitude * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def pcm(audio):
    return (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()


TWO_VOICES = pcm(np.concatenate([tone(200, 3), tone(700, 3)]))
ONE_VOICE = pcm(tone(200, 3))


class BandEmbedder:
    """A model stand-in: a voice is its pitch band (below or above 400 Hz), so two tones are two
    perfectly separable "speakers" and a window that holds both sits between them."""

    def __init__(self):
        self.calls = 0

    def embed(self, clips):
        self.calls += 1
        out = []
        for clip in clips:
            spectrum = np.abs(np.fft.rfft(clip)) ** 2
            freqs = np.fft.rfftfreq(len(clip), 1 / sp.RATE)
            v = np.array([spectrum[freqs < 400].sum(), spectrum[freqs >= 400].sum(), 0.0, 0.0])
            out.append(v / max(np.linalg.norm(v), 1e-9))
        return np.asarray(out, dtype=np.float32)


def labels(embedder=None, **kwargs):
    return sp.SpeakerLabels(
        embedder_factory=lambda: embedder or BandEmbedder(), downloaded=lambda: True, **kwargs
    )


# Features


def test_fbank_matches_kaldi():
    # Reference: kaldi-native-fbank 1.x (dither 0, 80 bins) with the mean over time removed,
    # every 8th frame and bin of this fixed signal.
    rng = np.random.default_rng(7)
    t = np.arange(8000) / 16000
    x = (
        0.3 * np.sin(2 * np.pi * 220 * t)
        + 0.1 * np.sin(2 * np.pi * 1330 * t)
        + 0.01 * rng.standard_normal(8000)
    ).astype(np.float32)
    reference = np.array(
        [
            [1.2912, -0.0102, 1.2589, -0.3077, 0.0081, -0.6983, 0.2285, 0.6861, -0.0285, -0.409],
            [1.2251, -0.0114, 0.4514, 2.0539, -0.0182, -0.823, -0.6368, -0.2281, 0.2401, 0.5414],
            [0.0045, 0.0221, -1.3012, 1.5406, -0.0474, -1.504, -0.8409, 0.3515, -0.5186, -0.2818],
            [-3.151, -0.0182, 0.0737, -0.089, -0.0163, 0.6935, -0.618, -0.1306, -0.1494, -0.206],
            [0.5223, -0.0164, -1.6788, -0.0307, 0.0101, 0.8748, 0.0819, -1.1605, 0.1687, 0.2257],
            [1.3122, -0.0078, -1.2993, 0.8395, 0.0113, 0.2718, -0.328, 0.4862, -0.1818, -0.2351],
        ]
    )
    features = sp.fbank(x)
    assert features.shape == (48, 80) and features.dtype == np.float32
    np.testing.assert_allclose(features[::8, ::8], reference, atol=2e-3)
    assert sp.fbank(np.zeros(100, dtype=np.float32)).shape == (0, 80)


def test_windows_skip_silence_and_short_audio():
    assert sp.windows(np.zeros(4000, dtype=np.float32)) == []  # 0.25 s: nothing to tell
    assert sp.windows(tone(200, 1)) == [(0, 16000)]  # under a window: embedded whole
    speech = np.concatenate([tone(200, 3), np.zeros(3 * sp.RATE, dtype=np.float32)])
    ranges = sp.windows(speech)
    assert ranges and all(b - a == sp.WINDOW for a, b in ranges)
    assert max(a for a, _ in ranges) < 3 * sp.RATE  # no window of only silence
    # A voiced tail past the last full window gets a window of its own.
    assert sp.windows(tone(200, 3.4))[-1] == (int(3.4 * sp.RATE) - sp.WINDOW, int(3.4 * sp.RATE))


# Clustering and the note's speakers


def unit(*v):
    v = np.array(v, dtype=np.float32)
    return v / np.linalg.norm(v)


A, B, C = unit(1, 0, 0, 0), unit(0, 1, 0, 0), unit(0, 0, 1, 0)


def test_cluster_average_linkage():
    assert sp.cluster(np.array([A, A, B, B, A])) == [0, 0, 1, 1, 0]
    assert sp.cluster(np.array([B, unit(0.95, 0.05, 0, 0), A])) == [0, 1, 1]
    assert sp.cluster(np.zeros((0, 4))) == []


def test_note_speakers_match_add_and_learn():
    note = sp.NoteSpeakers()
    assert note.assign(np.array([A, A]), [0, 0], 0.75) == [0, 0]
    # A again matches; B, with 1.5 s of speech, is someone new.
    assert note.assign(np.array([B, A, B]), [0, 1, 0], 0.75) == [1, 0, 1]
    assert [round(s.seconds, 2) for s in note.speakers] == [2.25, 1.5]
    # One-to-one in a segment: two clusters never both become person 0.
    near_a = unit(0.9, 0.1, 0.3, 0)
    assert note.assign(np.array([A, near_a, near_a]), [0, 1, 1], 0.75) == [0, 2, 2]


def test_short_unknown_voice_goes_to_the_nearest_speaker():
    note = sp.NoteSpeakers()
    note.assign(np.array([A, A]), [0, 0], 0.75)
    note.assign(np.array([B, B]), [0, 0], 0.75)
    # 0.75 s of a third voice is not enough for a new person.
    assert note.assign(np.array([unit(0.2, 1, 0.9, 0)]), [0], 0.75) == [1]
    assert len(note.speakers) == 2
    # The very first speech of a note is always somebody.
    fresh = sp.NoteSpeakers()
    assert fresh.assign(np.array([C]), [0], 0.5) == [0]


def test_speaker_cap():
    note = sp.NoteSpeakers()
    for i in range(sp.MAX_SPEAKERS + 2):
        v = np.zeros(16, dtype=np.float32)
        v[i] = 1
        note.assign(np.array([v, v]), [0, 0], 0.75)
    assert len(note.speakers) == sp.MAX_SPEAKERS


def test_spans_from_windows():
    ranges = [(0, 24000), (12000, 36000), (24000, 48000), (36000, 60000)]
    spans = sp.spans(ranges, [0, 0, 1, 1], 64000)
    assert spans == [sp.Span(0, 0.0, 1.875), sp.Span(1, 1.875, 4.0)]
    assert sp.spans([(0, 16000)], [3], 16000) == [sp.Span(3, 0.0, 1.0)]
    # A silent gap between windows stays unlabelled.
    gap = sp.spans([(0, 24000), (72000, 96000)], [0, 0], 96000)
    assert gap == [sp.Span(0, 0.0, 1.5), sp.Span(0, 4.5, 6.0)]


def test_sessions_evict_idle_and_least_recent():
    now = [0.0]
    sessions = sp.Sessions(limit=2, idle=100, clock=lambda: now[0])
    a = sessions.get("a")
    assert sessions.get("a") is a
    sessions.get("b")
    sessions.get("c")  # over the limit: "a" was used least recently
    assert list(sessions.notes) == ["b", "c"]
    now[0] = 50
    sessions.get("c")
    now[0] = 120  # "b" idled past 100 s; "c" did not
    sessions.get("d")
    assert list(sessions.notes) == ["c", "d"]
    again = sessions.get("a")
    assert again is not a and again.generation != a.generation


# Attribution: the Mac's SpeakerAttribution cases


def w(text, start, end):
    return Word(text, start, end)


def turns(words, text=None, spans=(), previous=None, duration=10.0):
    raw = " ".join(x.text for x in words or [])
    return sp.attribute(words, raw, text or raw, duration, list(spans), previous)


def s(slot, start, end):
    return sp.Span(slot, start, end)


def test_words_take_the_span_they_overlap_most():
    t = turns(
        [w("we", 0, 0.3), w("ship", 0.3, 0.6), w("friday", 0.6, 1.0), w("agreed", 1.4, 1.9)],
        spans=[s(2, 0, 1.1), s(0, 0.95, 2.0)],
    )
    assert [(x.slot, x.text, x.start, x.end) for x in t] == [
        (2, "we ship friday", 0, 1.0),
        (0, "agreed", 1.4, 1.9),
    ]


def test_nearest_span_within_a_second_else_neighbours():
    words = [w("right", 0, 0.4), w("so", 0.9, 1.0), w("um", 5, 5.2), w("next", 9, 9.5)]
    t = turns(words, spans=[s(1, 0, 0.4), s(2, 8.8, 9.6)])
    assert [(x.slot, x.text) for x in t] == [(1, "right so um"), (2, "next")]
    t = turns([w("oh", 0, 0.2), w("yes", 5, 5.3), w("indeed", 5.3, 5.8)], spans=[s(3, 5, 6)])
    assert [(x.slot, x.text) for x in t] == [(3, "oh yes indeed")]


def test_no_spans_fall_back_to_the_previous_speaker_or_nothing():
    assert [x.slot for x in turns([w("hello", 0, 0.5)], previous=2)] == [2]
    assert turns([w("hello", 0, 0.5)]) is None


def test_short_undetected_run_is_absorbed_but_a_heard_one_kept():
    words = [w("we", 0, 0.3), w("should", 0.3, 0.6), w("yeah", 2.05, 2.25)]
    words += [w("ship", 2.3, 2.6), w("it", 2.6, 2.8)]
    t = turns(words, spans=[s(0, 0, 0.7), s(1, 1.0, 1.2), s(0, 2.3, 3.0)])
    assert [(x.slot, x.text) for x in t] == [(0, "we should yeah ship it")]
    words = [w("we", 0, 0.3), w("should", 0.3, 0.6), w("yeah", 0.8, 1.0)]
    words += [w("ship", 1.3, 1.6), w("it", 1.6, 1.8)]
    t = turns(words, spans=[s(0, 0, 0.7), s(1, 0.7, 1.75), s(0, 1.25, 2.0)])
    assert [x.slot for x in t] == [0, 1, 0]


def test_no_timings_give_one_approximate_turn():
    t = sp.attribute(None, "a b c", "A b c.", 10, [s(0, 0, 3), s(2, 3, 9)])
    assert t == [sp.Turn(2, 0.0, 10, "A b c.", "a b c", approximate=True)]
    assert sp.attribute([], "x", "x", 1, []) is None


TWO = [w("so", 0, 0.2), w("we", 0.2, 0.4), w("ship", 0.4, 0.7), w("friday", 0.7, 1.0)]
TWO += [w("sounds", 2, 2.3), w("good", 2.3, 2.6)]
TWO_SPANS = [s(0, 0, 1.1), s(1, 1.9, 2.7)]


def test_corrected_text_keeps_the_boundary():
    t = turns(TWO, "So, we ship Friday. Sounds good!", TWO_SPANS)
    assert [(x.slot, x.text, x.raw) for x in t] == [
        (0, "So, we ship Friday.", "so we ship friday"),
        (1, "Sounds good!", "sounds good"),
    ]
    t = turns(TWO, "We ship on Friday. That sounds good.", TWO_SPANS)
    assert [x.text for x in t] == ["We ship on Friday. That", "sounds good."]


def test_dropped_turn_folds_its_raw_text_and_rewrites_keep_raw():
    words = TWO + [w("ok", 3, 3.2), w("then", 3.2, 3.5)]
    t = turns(words, "So we ship Friday. OK then.", TWO_SPANS + [s(0, 2.9, 3.6)])
    assert [(x.slot, x.text, x.raw) for x in t] == [
        (0, "So we ship Friday. OK then.", "so we ship friday sounds good ok then")
    ]
    t = turns(TWO, "The release is planned for the end of the week, which all accepted.", TWO_SPANS)
    assert [x.text for x in t] == ["so we ship friday", "sounds good"]
    assert all(x.kept_original for x in t)
    t = turns(TWO[:4], "Entirely different words here.", TWO_SPANS)
    assert [(x.slot, x.text, x.raw) for x in t] == [
        (0, "Entirely different words here.", "so we ship friday")
    ]


def test_alignment():
    assert sp.alignment(["a", "b"], ["A,", "b."]) == [0, 1]
    assert sp.alignment(["a", "b", "c"], ["a", "x", "c"]) == [0, None, 2]
    assert sp.alignment(["um", "a"], ["a"]) == [1]
    assert sp.alignment(["a"] * 400, ["b"] * 400) is None


# The service and the protocol


def test_labels_two_tones_and_keep_the_note_across_segments():
    async def run():
        service = labels()
        words = [Word(f"w{i}", i * 0.3, i * 0.3 + 0.25) for i in range(20)]
        first = await service.label(SESSION, TWO_VOICES, words, WORDS, WORDS)
        again = await service.label(SESSION, ONE_VOICE, words[:10], WORDS[:29], WORDS[:29])
        other = await service.label("another-note-000000", pcm(tone(700, 2)), None, "x", "x")
        return first, again, other

    first, again, other = asyncio.run(run())
    t = first["turns"]
    assert [x["speaker"] for x in t] == [0, 1]
    assert t[0]["text"].startswith("w0 w1") and t[1]["text"].endswith("w18 w19")
    assert " ".join(x["text"] for x in t) == WORDS
    assert t[1]["start"] >= 2.7 and t[0]["end"] <= 3.6
    assert [x["speaker"] for x in again["turns"]] == [0]
    assert again["generation"] == first["generation"]
    # Another note numbers its own people from 0.
    assert other["turns"][0]["speaker"] == 0 and other["turns"][0]["approximate"]
    assert other["generation"] != first["generation"]


def test_missing_model_and_failures_never_raise():
    async def run():
        missing = sp.SpeakerLabels(downloaded=lambda: False)

        class Broken:
            def embed(self, clips):
                raise RuntimeError("boom")

        broken = sp.SpeakerLabels(embedder_factory=Broken, downloaded=lambda: True)
        return (
            await missing.label(SESSION, ONE_VOICE, None, "a", "a"),
            await broken.label(SESSION, ONE_VOICE, None, "a", "a"),
        )

    assert asyncio.run(run()) == ({"error": "unavailable"}, {"error": "failed"})


def stream(client, start, audio, engine=None, text=None):
    if engine is not None and text is not None:
        engine.text = text
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(start)
        assert ws.receive_json()["type"] == "ready"
        ws.send_bytes(audio)
        ws.send_json({"type": "stop"})
        return final(ws)


@pytest.fixture
def labelled(settings):
    engine = FakeEngine(WORDS)
    with TestClient(create_app(settings, engine, TOKEN, speakers=labels())) as client:
        yield client, engine


def test_final_carries_the_turns(labelled):
    client, engine = labelled
    result = stream(client, LABELLED, TWO_VOICES)
    speakers = result["speakers"]
    assert set(speakers) == {"generation", "turns"}
    assert [t["speaker"] for t in speakers["turns"]] == [0, 1]
    assert set(speakers["turns"][0]) == {
        "speaker",
        "start",
        "end",
        "text",
        "raw",
        "approximate",
        "kept_original",
    }
    # Labels never need `word_timings`, and asking for them does not add `words`.
    assert "words" not in result
    later = stream(client, LABELLED, ONE_VOICE, engine, "w0 w1 w2 w3")
    assert later["speakers"]["generation"] == speakers["generation"]
    assert [t["speaker"] for t in later["speakers"]["turns"]] == [0]


def test_without_the_field_the_final_is_unchanged(labelled, client):
    plain, _ = labelled
    result = stream(plain, START, TWO_VOICES)
    assert "speakers" not in result
    reference = stream(client, START, TWO_VOICES)
    assert set(result) == set(reference)


def test_empty_final_has_no_turns(labelled):
    client, engine = labelled
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(LABELLED)
        ws.receive_json()
        ws.send_json({"type": "stop"})
        assert final(ws)["speakers"]["turns"] == []


def test_missing_model_says_unavailable(client):
    result = stream(client, LABELLED, ONE_VOICE)
    assert result["speakers"] == {"error": "unavailable"}
    assert result["text"]  # the text is never withheld


@pytest.mark.parametrize(
    "value",
    [
        "note",
        {"session": "short"},
        {"session": "x" * 65},
        {"session": "has space in it here"},
        {"session": SESSION, "extra": 1},
        {"session": 12345678901234567},
        {},
    ],
)
def test_invalid_speakers_field_is_bad_audio(client, value):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json({**START, "speakers": value})
        assert ws.receive_json() == {
            "type": "error",
            "code": "bad_audio",
            "message": "Invalid audio or control frame",
        }


def test_turns_follow_the_corrected_text(settings):
    class Corrector:
        async def process(self, raw, profile="default", instructions="", *args, **kwargs):
            return CorrectionResult(raw.upper().replace("W9", "W9."), corrected=True)

    settings.correction = CorrectionConfig(mode="endpoint")
    engine = FakeEngine(WORDS)
    app = create_app(settings, engine, TOKEN, Corrector(), speakers=labels())
    with TestClient(app) as client:
        result = stream(client, {**LABELLED, "correction": True}, TWO_VOICES)
    t = result["speakers"]["turns"]
    assert result["corrected"] and " ".join(x["text"] for x in t) == result["text"]
    assert " ".join(x["raw"] for x in t) == result["raw"]
    assert t[0]["text"].startswith("W0") and [x["speaker"] for x in t] == [0, 1]


def test_logs_carry_counts_only(labelled, caplog):
    client, engine = labelled
    caplog.set_level(logging.INFO, logger="chirp")
    stream(client, LABELLED, TWO_VOICES, engine, "private words " * 10)
    lines = [r.getMessage() for r in caplog.records]
    assert any(line.startswith("speakers turns=") for line in lines)
    joined = "\n".join(lines)
    assert "private" not in joined and SESSION not in joined


# The model endpoint and health


def test_model_endpoint_downloads_and_removes(settings, tmp_path, monkeypatch):
    monkeypatch.setattr(speakers_model, "directory", lambda: tmp_path / "speakers")
    present = {"value": False}

    def fetch():
        time.sleep(0.05)
        present["value"] = True

    service = sp.SpeakerLabels(fetch=fetch, downloaded=lambda: present["value"])
    with TestClient(create_app(settings, FakeEngine(), TOKEN, speakers=service)) as client:
        url = "/v1/speakers/model"
        assert client.post(url, json={"action": "download"}).status_code == 401
        for body in ({}, {"action": "nope"}, {"action": "download", "x": 1}, [1]):
            response = client.post(url, headers=HEADERS, json=body)
            assert response.status_code == 400 and response.json()["code"] == "bad_speakers"
        response = client.post(url, headers=HEADERS, json={"action": "download"})
        assert response.status_code == 202 and response.json()["state"] == "downloading"
        assert client.post(url, headers=HEADERS, json={"action": "remove"}).status_code == 409
        for _ in range(100):
            health = client.get("/v1/health", headers=HEADERS).json()
            if health["speakers_model"]["state"] == "ready":
                break
            time.sleep(0.02)
        assert health["speakers_model"] == {"state": "ready", "size_bytes": speakers_model.SIZE}
        assert "notes_speakers" in health["capabilities"]
        response = client.post(url, headers=HEADERS, json={"action": "download"})
        assert response.status_code == 200
        (tmp_path / "speakers").mkdir()
        (tmp_path / "speakers" / speakers_model.FILE).write_bytes(b"x")
        present["value"] = False
        response = client.post(url, headers=HEADERS, json={"action": "remove"})
        assert response.json()["state"] == "not_downloaded"
        assert not (tmp_path / "speakers").exists()


def test_failed_download_reports_failed(settings):
    def fetch():
        raise ValueError("checksum")

    service = sp.SpeakerLabels(fetch=fetch, downloaded=lambda: False)
    with TestClient(create_app(settings, FakeEngine(), TOKEN, speakers=service)) as client:
        client.post("/v1/speakers/model", headers=HEADERS, json={"action": "download"})
        for _ in range(100):
            state = client.get("/v1/health", headers=HEADERS).json()["speakers_model"]["state"]
            if state != "downloading":
                break
            time.sleep(0.02)
        assert state == "failed"


def test_cancel_stops_process_cleans_partials_and_allows_redownload(
    settings, tmp_path, monkeypatch
):
    folder = tmp_path / "speakers"
    marker = folder / "partial"
    installed = folder / speakers_model.FILE
    monkeypatch.setattr(speakers_model, "directory", lambda: folder)
    original_spawn = asyncio.create_subprocess_exec
    processes = []

    async def downloader(*command, **kwargs):
        assert list(command) == [
            sys.executable,
            "-c",
            "from chirp_server.speakers_model import fetch; fetch()",
        ]
        # The first fetch blocks after writing a partial. The retry completes normally.
        script = (
            "from pathlib import Path; import threading; "
            f"Path({str(folder)!r}).mkdir(parents=True, exist_ok=True); "
            + (
                f"Path({str(marker)!r}).write_bytes(b'partial'); threading.Event().wait(60)"
                if not processes
                else f"Path({str(installed)!r}).write_bytes(b'model')"
            )
        )
        process = await original_spawn(sys.executable, "-c", script, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(sp.asyncio, "create_subprocess_exec", downloader)
    service = sp.SpeakerLabels(downloaded=installed.exists)
    with TestClient(create_app(settings, FakeEngine(), TOKEN, speakers=service)) as client:
        url = "/v1/speakers/model"

        def action(kind):
            response = client.post(url, headers=HEADERS, json={"action": kind})
            assert response.status_code == (202 if kind == "download" else 200)
            return response.json()["state"]

        assert client.post(url, json={"action": "cancel"}).status_code == 401
        assert action("cancel") == "not_downloaded"
        assert not folder.exists()
        assert action("download") == "downloading"
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert marker.exists()
        assert action("cancel") == "not_downloaded"
        assert processes[0].returncode is not None
        assert not folder.exists()
        assert action("cancel") == "not_downloaded"
        assert action("download") == "downloading"
        deadline = time.monotonic() + 10
        while service.state == "downloading" and time.monotonic() < deadline:
            time.sleep(0.02)
        assert service.state == "ready"
        assert action("cancel") == "ready"
        assert installed.read_bytes() == b"model"
        assert len(processes) == 2


def test_cancel_clears_failed_state(settings):
    service = sp.SpeakerLabels(downloaded=lambda: False)
    service.failed = True
    with TestClient(create_app(settings, FakeEngine(), TOKEN, speakers=service)) as client:
        response = client.post("/v1/speakers/model", headers=HEADERS, json={"action": "cancel"})
        assert response.status_code == 200
        assert response.json() == {"state": "not_downloaded", "size_bytes": speakers_model.SIZE}


def test_model_files_are_verified(tmp_path, monkeypatch):
    monkeypatch.setattr(speakers_model, "directory", lambda: tmp_path / "speakers")
    assert not speakers_model.is_downloaded() and not speakers_model.has_files()
    (tmp_path / "speakers").mkdir()
    bad = tmp_path / "speakers" / speakers_model.FILE
    bad.write_bytes(b"not the model")
    assert speakers_model.has_files() and not speakers_model.verify(bad)
    speakers_model.remove()
    assert not (tmp_path / "speakers").exists()


# The real model (`-m model`): two `say` voices, one note


def model_path():
    explicit = os.environ.get("CHIRP_SPEAKER_MODEL")
    path = Path(explicit) if explicit else speakers_model.path()
    if not path.is_file():
        pytest.skip("speaker model not downloaded (chirp-server model fetch --speakers)")
    return path


def say(tmp_path, voice, text):
    if shutil.which("say") is None:
        pytest.skip("needs macOS say")
    out = tmp_path / f"{voice}.wav"
    subprocess.run(
        ["say", "-v", voice, "-o", str(out), "--data-format=LEI16@16000", text], check=True
    )
    with wave.open(str(out)) as clip:
        return np.frombuffer(clip.readframes(clip.getnframes()), "<i2").astype(np.float32) / 32768


@pytest.mark.model
def test_real_model_tells_two_voices_apart(tmp_path):
    path = model_path()
    sentence = "We should ship the beta on Friday, but only if the review is done by then."
    reply = "That works for me. I can send the spec tomorrow morning and check the budget."
    first = say(tmp_path, "Samantha", sentence)
    second = say(tmp_path, "Daniel", reply)
    gap = np.zeros(int(0.6 * sp.RATE), dtype=np.float32)
    # The pause between them and a trailing pause (as Notes cuts segments) are no third person.
    audio = np.concatenate([first, gap, second, np.zeros(2 * sp.RATE, dtype=np.float32)])
    cut = (len(first) + len(gap) / 2) / sp.RATE
    speech_end = (len(first) + len(gap) + len(second)) / sp.RATE
    service = sp.SpeakerLabels(
        embedder_factory=lambda: sp.OnnxEmbedder(path), downloaded=lambda: True
    )

    async def run():
        note, spans = await service.spans(SESSION, pcm(audio))
        later, again = await service.spans(SESSION, pcm(say(tmp_path, "Daniel", sentence)))
        return note, spans, again

    started = time.perf_counter()
    note, spans, again = asyncio.run(run())
    elapsed = time.perf_counter() - started
    assert len(note.speakers) == 2
    # Seconds of audio given the right voice: at least 90 %.
    total = right = 0.0
    for span in spans:
        for t in np.arange(span.start, min(span.end, speech_end), 0.05):
            total += 0.05
            right += 0.05 * ((t < cut) == (span.slot == 0))
    assert right / total >= 0.9
    # The same voice, saying something else in a later segment, is the same person.
    assert {span.slot for span in again} == {1}
    assert elapsed < 10
