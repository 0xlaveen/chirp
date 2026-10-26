"""Saved voices (#247): the `voices.json` store, `GET/POST /v1/speakers/voices`, `matches` on
`final.speakers`, the `chirp-server voices` CLI, and the logs."""

import asyncio
import base64
import json
import logging
import os
import sys

import numpy as np
import pytest
from conftest import HEADERS, START, TOKEN, has_mode
from starlette.testclient import TestClient
from test_protocol import final
from test_speakers import model_path, pcm, say

from chirp_server import cli, speakers_model
from chirp_server import speakers as sp
from chirp_server import voices as vs
from chirp_server.app import create_app
from chirp_server.engine import FakeEngine

URL = "/v1/speakers/voices"
MODEL = speakers_model.MODEL_ID
WORDS = " ".join(f"w{i}" for i in range(20))
BANDS = 16


def tone(freq, seconds, amplitude=0.3):
    t = np.arange(int(seconds * sp.RATE)) / sp.RATE
    return (amplitude * np.sin(2 * np.pi * freq * t)).astype(np.float32)


class PitchEmbedder:
    """A model stand-in with many "voices": a clip's energy in 100 Hz bands, so tones in
    different bands are orthogonal people and a tone is always itself."""

    def embed(self, clips):
        out = []
        for clip in clips:
            spectrum = np.abs(np.fft.rfft(clip)) ** 2
            freqs = np.fft.rfftfreq(len(clip), 1 / sp.RATE)
            v = np.array(
                [spectrum[(freqs >= 100 * b) & (freqs < 100 * (b + 1))].sum() for b in range(BANDS)]
            )
            out.append(v / max(np.linalg.norm(v), 1e-9))
        return np.asarray(out, dtype=np.float32)


def band(index):
    v = np.zeros(BANDS, dtype=np.float32)
    v[index] = 1
    return v


def service(library=None, downloaded=True):
    return sp.SpeakerLabels(
        embedder_factory=PitchEmbedder,
        downloaded=lambda: downloaded,
        library=library if library is not None else vs.VoiceLibrary(),
    )


@pytest.fixture
def library():
    return vs.VoiceLibrary()


@pytest.fixture
def app(settings, library):
    with TestClient(create_app(settings, FakeEngine(WORDS), TOKEN, speakers=service(library))) as c:
        yield c


def session(n):
    return f"note-{n:016d}"


def stream(client, note, audio):
    """One Live Notes segment of `audio` (floats) for `note`: its `final.speakers`."""
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json({**START, "client": "ios", "speakers": {"session": note}})
        assert ws.receive_json()["type"] == "ready"
        data = pcm(audio)
        for i in range(0, len(data), 64000):
            ws.send_bytes(data[i : i + 64000])
        ws.send_json({"type": "stop"})
        return final(ws)["speakers"]


def clip(audio):
    return base64.b64encode(pcm(audio)).decode()


def post(client, body, status=200):
    response = client.post(URL, headers=HEADERS, json=body)
    assert response.status_code == status, response.text
    return response.json()


# The store


def test_store_is_private_atomic_and_never_written_by_reading(tmp_path):
    folder = tmp_path / "speakers"
    library = vs.VoiceLibrary(vs.VoiceStore(folder))
    assert library.listing() == {"enabled": True, "model": MODEL, "voices": []}
    assert not folder.exists()
    saved = library.remember("Maya", band(1), 20.0)
    assert has_mode(folder, 0o700) and has_mode(folder / "voices.json", 0o600)
    assert sorted(p.name for p in folder.iterdir()) == ["voices.json", "voices.lock"]
    data = json.loads((folder / "voices.json").read_text())
    assert data["enabled"] is True and data["version"] == 1
    (stored,) = data["voices"]
    assert set(stored) == {"id", "name", "model", "embedding", "seconds", "created", "updated"}
    assert stored["model"] == MODEL and stored["name"] == "Maya"
    np.testing.assert_allclose(vs.decode(stored["embedding"]), band(1))
    assert saved == {
        "id": stored["id"],
        "name": "Maya",
        "seconds": 20.0,
        "created": stored["created"],
        "updated": stored["created"],
        "compatible": True,
    }


@pytest.mark.parametrize(
    "name",
    ["", "   ", "Maya: hi", "x" * 61, "Ma\nya", "Ma\tya", "12345", "Maya​\u0007", None, 7],
)
def test_names_are_one_line_no_colon_with_a_letter(library, name):
    with pytest.raises(vs.VoiceError) as caught:
        library.remember(name, band(1), 30.0)
    assert caught.value.code == "bad_speakers"


def test_names_are_trimmed_and_collapsed(library):
    assert library.remember("  Maya   van Dijk ", band(1), 30.0)["name"] == "Maya van Dijk"
    assert library.remember("x" * 59 + "é", band(2), 30.0)["name"] == "x" * 59 + "é"


def test_cap_too_short_and_unknown_voice(library):
    for i in range(vs.MAX_VOICES):
        library.remember(f"P{i}", band(i % BANDS), 30.0)
    with pytest.raises(vs.VoiceError, match="full"):
        library.remember("One more", band(1), 30.0)
    with pytest.raises(vs.VoiceError, match="too_short"):
        library.remember("Short", band(1), vs.ENROL_SECONDS - 0.1)
    for call in (
        lambda: library.rename("0" * 16, "X"),
        lambda: library.forget("0" * 16),
        lambda: library.remember("X", band(1), 30.0, voice="0" * 16),
    ):
        with pytest.raises(vs.VoiceError, match="no_voice"):
            call()


def test_update_is_a_seconds_weighted_mean(library):
    voice = library.remember("Maya", band(0), 30.0)
    updated = library.remember("Maya", band(1), 20.0, voice=voice["id"])
    assert updated["id"] == voice["id"] and updated["seconds"] == 50.0
    (candidate,) = library.candidates()
    np.testing.assert_allclose(candidate.embedding, vs.unit(np.array([3, 2] + [0] * 14)), atol=1e-6)


def test_other_model_is_listed_incompatible_and_never_compared(tmp_path):
    store = vs.VoiceStore(tmp_path / "v")
    vs.VoiceLibrary(store, model="old-model@1").remember("Old", band(1), 30.0)
    library = vs.VoiceLibrary(store)
    assert [v["compatible"] for v in library.listing()["voices"]] == [False]
    assert library.candidates() == []
    # Updating it replaces the voiceprint with this model's.
    old = library.listing()["voices"][0]["id"]
    assert library.remember("Old", band(2), 25.0, voice=old)["compatible"]
    assert library.listing()["voices"][0]["seconds"] == 25.0


def test_switch_and_forget_all(library):
    library.remember("Maya", band(1), 30.0)
    library.disable()
    assert library.listing()["enabled"] is False and library.candidates() == []
    assert len(library.listing()["voices"]) == 1
    with pytest.raises(vs.VoiceError, match="disabled"):
        library.remember("Akshay", band(2), 30.0)
    # Forget all while off keeps the switch off.
    library.forget_all()
    assert library.listing() == {"enabled": False, "model": MODEL, "voices": []}
    library.enable()
    library.remember("Maya", band(1), 30.0)
    library.disable(forget=True)
    assert library.listing()["voices"] == []
    library.enable()
    library.forget_all()
    assert not library.store.path.exists()


def test_invalid_file_is_refused_and_forget_all_recovers(library):
    library.store.directory.mkdir(parents=True)
    library.store.path.write_text('{"enabled": true, "voices": [{"name": "x"}]}')
    with pytest.raises(ValueError):
        library.listing()
    assert library.health()["error"] == "unreadable"
    library.forget_all()
    assert library.listing()["voices"] == []


def test_a_cli_change_applies_without_a_restart(tmp_path):
    store = vs.VoiceStore(tmp_path / "v")
    server, other = vs.VoiceLibrary(store), vs.VoiceLibrary(vs.VoiceStore(tmp_path / "v"))
    server.remember("Maya", band(1), 30.0)
    assert len(server.candidates()) == 1
    other.disable()
    assert server.candidates() == []


# Matching (the Mac's VoiceMatch)


def candidates(*vectors):
    return [vs.Candidate(f"{i:016x}", f"V{i}", vs.unit(v)) for i, v in enumerate(vectors)]


def test_match_needs_threshold_margin_and_seconds():
    voices = candidates(band(0), band(1))
    near = vs.unit(band(0) * 0.9 + band(2) * 0.3)
    assert {p: v.name for p, v in vs.match({0: (near, 12.0)}, voices).items()} == {0: "V0"}
    # Not enough speech yet.
    assert vs.match({0: (near, vs.MATCH_SECONDS - 0.1)}, voices) == {}
    # Below the threshold.
    assert vs.match({0: (vs.unit(band(0) * 0.5 + band(2)), 12.0)}, voices) == {}
    # Two saved voices too alike to tell apart: no margin, no match.
    close = candidates(band(0), vs.unit(band(0) + band(1) * 0.2))
    assert vs.match({0: (band(0), 12.0)}, close) == {}


def test_match_is_one_to_one_closest_first():
    voices = candidates(band(0), band(5))
    people = {0: (vs.unit(band(0) * 0.8 + band(3) * 0.6), 30.0), 1: (band(0), 30.0)}
    found = vs.match(people, voices)
    assert {p: v.name for p, v in found.items()} == {1: "V0"}


# The protocol


def test_auth_and_bad_requests(app):
    assert app.get(URL).status_code == 401
    assert app.post(URL, json={"action": "forget_all"}).status_code == 401
    voice = "0123456789abcdef"
    for body in (
        [],
        {},
        {"action": "nope"},
        {"action": []},
        {"action": {}},
        {"action": "forget_all", "x": 1},
        {"action": "forget", "voice": "MAYA"},
        {"action": "rename", "voice": voice},
        {"action": "rename", "voice": voice, "name": "a: b"},
        {"action": "disable", "forget": "yes"},
        {"action": "remember", "name": "Maya"},
        {"action": "remember", "name": "Maya", "audio": "", "from": {}},
        {"action": "remember", "name": "Maya", "audio": "not base64!"},
        {"action": "remember", "name": "Maya", "audio": clip(tone(200, 1))[:-4] + "AA=="},
        {"action": "remember", "name": "Maya", "from": {"session": "short", "generation": "g"}},
        {
            "action": "remember",
            "name": "Maya",
            "from": {"session": session(1), "generation": "g", "speaker": True},
        },
        {"action": "remember", "name": "Maya", "audio": "", "voice": "x"},
        {"action": "identify", "people": []},
        {"action": "identify", "people": [{"person": 1, "audio": ""}] * 2},
        {"action": "identify", "people": [{"person": -1, "audio": ""}]},
    ):
        assert post(app, body, 400)["code"] == "bad_speakers", body
    assert app.post(URL, headers=HEADERS, content=b"{nope").status_code == 400


def test_import_rejects_non_string_models(app):
    for model in ([], {}, None, 1):
        body = {
            "action": "import",
            "name": "Maya",
            "embedding": vs.encode(np.ones(vs.DIMENSIONS, dtype=np.float32)),
            "seconds": 30,
            "model": model,
        }
        assert post(app, body, 400)["code"] == "bad_speakers"


def test_clip_limit_checks_decoded_size(app):
    # Enforce the limit on decoded PCM as well as the encoded request.
    audio = base64.b64encode(bytes(30 * sp.RATE * 2 + 2)).decode()
    assert (
        post(app, {"action": "remember", "name": "Maya", "audio": audio}, 413)["code"]
        == "clip_too_long"
    )


def test_remember_from_a_note_then_recognise_in_the_next(app):
    first = stream(app, session(1), tone(250, 21))
    assert set(first) == {"generation", "turns"}  # no voices yet: today's message
    origin = {"session": session(1), "generation": first["generation"], "speaker": 0}
    body = post(app, {"action": "remember", "name": "Maya", "from": origin})
    voice = body["voice"]
    assert voice["name"] == "Maya" and voice["seconds"] >= vs.ENROL_SECONDS
    assert body["enabled"] and body["voices"] == [voice] and body["model"] == MODEL
    # The same note now reports her too.
    again = stream(app, session(1), tone(250, 3))
    assert again["matches"] == [{"speaker": 0, "voice": voice["id"], "name": "Maya"}]
    # Note 2: someone else first, then Maya; only Maya is recognised, at her own slot.
    stream(app, session(2), tone(650, 12))
    second = stream(app, session(2), tone(250, 12))
    assert second["matches"] == [{"speaker": 1, "voice": voice["id"], "name": "Maya"}]
    assert {t["speaker"] for t in second["turns"]} == {1}
    # Short speech is not matched yet.
    assert stream(app, session(3), tone(250, 4))["matches"] == []


def test_remember_errors(app, library):
    first = stream(app, session(1), tone(250, 8))
    origin = {"session": session(1), "generation": first["generation"], "speaker": 0}
    assert post(app, {"action": "remember", "name": "Maya", "from": origin}, 409)["code"] == (
        "too_short"
    )
    for wrong in ({"generation": "another"}, {"session": session(9)}, {"speaker": 3}):
        body = {"action": "remember", "name": "Maya", "from": {**origin, **wrong}}
        assert post(app, body, 404)["code"] == "gone"
    library.disable()
    assert post(app, {"action": "remember", "name": "Maya", "from": origin}, 409)["code"] == (
        "disabled"
    )
    assert post(app, {"action": "identify", "people": [{"person": 1, "audio": ""}]}, 409)[
        "code"
    ] == ("disabled")


def test_disabled_library_matches_nothing_and_writes_nothing(app, library):
    library.remember("Maya", band(2), 30.0)
    library.disable()
    written = library.store.path.stat().st_mtime_ns
    result = stream(app, session(1), tone(250, 12))
    assert set(result) == {"generation", "turns"}
    origin = {"session": session(1), "generation": result["generation"], "speaker": 0}
    post(app, {"action": "remember", "name": "Akshay", "from": origin}, 409)
    assert library.store.path.stat().st_mtime_ns == written


def test_remember_and_identify_from_clips(app):
    body = post(app, {"action": "remember", "name": "Maya", "audio": clip(tone(250, 22))})
    maya = body["voice"]["id"]
    post(app, {"action": "remember", "name": "Akshay", "audio": clip(tone(850, 25))})
    people = [
        {"person": 3, "audio": clip(tone(850, 12))},
        {"person": 5, "audio": clip(tone(250, 11))},
        {"person": 7, "audio": clip(tone(1250, 15))},
        {"person": 9, "audio": clip(tone(250, 4))},  # too little speech to tell
    ]
    matches = post(app, {"action": "identify", "people": people})["matches"]
    assert [(m["person"], m["name"]) for m in matches] == [(3, "Akshay"), (5, "Maya")]
    assert matches[1]["voice"] == maya
    # Update Maya from another clip: seconds add up.
    updated = post(
        app, {"action": "remember", "name": "Maya", "audio": clip(tone(250, 25)), "voice": maya}
    )
    assert updated["voice"]["seconds"] == pytest.approx(47, abs=1)
    # A clip of silence is too short; a clip over 30 s is refused before any work.
    silent = clip(np.zeros(25 * sp.RATE, dtype=np.float32))
    assert post(app, {"action": "remember", "name": "X", "audio": silent}, 409)["code"] == (
        "too_short"
    )
    long = clip(tone(250, 31))
    assert post(app, {"action": "remember", "name": "X", "audio": long}, 413)["code"] == (
        "clip_too_long"
    )


def test_clips_need_the_model(settings, library):
    labels = service(library, downloaded=False)
    with TestClient(create_app(settings, FakeEngine(WORDS), TOKEN, speakers=labels)) as client:
        body = {"action": "remember", "name": "Maya", "audio": clip(tone(250, 22))}
        assert post(client, body, 409)["code"] == "unavailable"
        # With nothing saved, identify answers without the model.
        people = [{"person": 1, "audio": clip(tone(250, 12))}]
        assert post(client, {"action": "identify", "people": people}) == {"matches": []}


def test_rename_forget_switch_and_forget_all(app, library):
    maya = library.remember("Maya", band(2), 30.0)["id"]
    library.remember("Akshay", band(5), 30.0)
    body = post(app, {"action": "rename", "voice": maya, "name": "Maya B"})
    assert [v["name"] for v in body["voices"]] == ["Maya B", "Akshay"]
    assert post(app, {"action": "forget", "voice": maya})["voices"][0]["name"] == "Akshay"
    assert post(app, {"action": "forget", "voice": maya}, 404)["code"] == "no_voice"
    assert post(app, {"action": "disable", "forget": False})["enabled"] is False
    health = app.get("/v1/health", headers=HEADERS).json()
    assert health["speakers_voices"] == {"enabled": False, "count": 1, "model": MODEL}
    assert "speaker_voices" in health["capabilities"]
    assert post(app, {"action": "enable"})["enabled"] is True
    assert post(app, {"action": "forget_all"}) == {"enabled": True, "model": MODEL, "voices": []}
    assert not library.store.path.exists()
    library.remember("Maya", band(2), 30.0)
    assert post(app, {"action": "disable", "forget": True}) == {
        "enabled": False,
        "model": MODEL,
        "voices": [],
    }
    assert app.get(URL, headers=HEADERS).json()["enabled"] is False


def test_unreadable_file_is_an_error_not_a_crash(app, library):
    library.store.directory.mkdir(parents=True)
    library.store.path.write_text("not json")
    assert app.get(URL, headers=HEADERS).status_code == 500
    assert post(app, {"action": "enable"}, 500)["code"] == "voices_file"
    # Labels keep working, without matches.
    assert set(stream(app, session(1), tone(250, 3))) == {"generation", "turns"}
    assert app.get("/v1/health", headers=HEADERS).json()["speakers_voices"]["error"] == (
        "unreadable"
    )
    assert post(app, {"action": "forget_all"})["voices"] == []


def test_matches_without_the_session_field_never_appear(app, library):
    library.remember("Maya", band(2), 30.0)
    with app.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START)
        ws.receive_json()
        ws.send_bytes(pcm(tone(250, 12)))
        ws.send_json({"type": "stop"})
        assert "speakers" not in final(ws)


def test_logs_carry_counts_and_codes_only(app, library, caplog):
    caplog.set_level(logging.INFO, logger="chirp")
    first = stream(app, session(1), tone(250, 21))
    origin = {"session": session(1), "generation": first["generation"], "speaker": 0}
    voice = post(app, {"action": "remember", "name": "Zelda Sentinel", "from": origin})["voice"]
    stream(app, session(2), tone(250, 12))
    post(app, {"action": "rename", "voice": voice["id"], "name": "Quentin Sentinel"})
    post(app, {"action": "forget", "voice": "f" * 16}, 404)
    post(app, {"action": "identify", "people": [{"person": 1, "audio": clip(tone(250, 12))}]})
    lines = [r.getMessage() for r in caplog.records]
    assert "speakers voices action=remember code=ok" in lines
    assert "speakers voices action=forget code=no_voice" in lines
    assert "speakers voices count=1 matched=1" in lines
    joined = "\n".join(lines)
    stored = json.loads(library.store.path.read_text())["voices"][0]["embedding"]
    for secret in ("Sentinel", voice["id"], session(1), first["generation"], stored[:12]):
        assert secret not in joined


def test_only_the_library_file_is_written(settings, tmp_path, monkeypatch):
    """Everything the server writes for saved voices is `voices.json` (and its lock)."""
    import builtins

    library = vs.VoiceLibrary()
    labels = service(library)
    writes = []
    original_open, original_os_open = builtins.open, os.open

    def checked_open(file, mode="r", *args, **kwargs):
        if isinstance(mode, str) and any(flag in mode for flag in "wax+"):
            writes.append(str(file))
        return original_open(file, mode, *args, **kwargs)

    def checked_os_open(file, flags, *args, **kwargs):
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT):
            writes.append(os.path.basename(str(file)))
        return original_os_open(file, flags, *args, **kwargs)

    with TestClient(create_app(settings, FakeEngine(WORDS), TOKEN, speakers=labels)) as client:
        with monkeypatch.context() as patch:
            patch.setattr(builtins, "open", checked_open)
            patch.setattr(os, "open", checked_os_open)
            first = stream(client, session(1), tone(250, 21))
            origin = {"session": session(1), "generation": first["generation"], "speaker": 0}
            post(client, {"action": "remember", "name": "Maya", "from": origin})
            post(client, {"action": "remember", "name": "Kim", "audio": clip(tone(850, 22))})
            stream(client, session(2), tone(250, 12))
    assert writes and all(
        name == "voices.lock" or (name.startswith(".voices.json.") and name.endswith(".tmp"))
        for name in writes
    ), writes
    assert sorted(p.name for p in library.store.directory.iterdir()) == [
        "voices.json",
        "voices.lock",
    ]


# The CLI


def run_cli(monkeypatch, capsys, *args):
    monkeypatch.setattr(sys, "argv", ["chirp-server", "--config", "/nonexistent.toml", *args])
    cli.main()
    return capsys.readouterr().out


def test_cli(monkeypatch, capsys):
    library = vs.VoiceLibrary()
    assert "No saved voices" in run_cli(monkeypatch, capsys, "voices", "list")
    maya = library.remember("Maya", band(2), 30.0)
    library.remember("Kim", band(3), 30.0)
    library.remember("Kim", band(4), 30.0)
    out = run_cli(monkeypatch, capsys, "voices", "list")
    assert "Remember voices: on" in out and "Maya" in out and maya["id"] in out
    listed = json.loads(run_cli(monkeypatch, capsys, "voices", "list", "--json"))
    assert [v["name"] for v in listed["voices"]] == ["Maya", "Kim", "Kim"]
    assert "embedding" not in json.dumps(listed)
    with pytest.raises(SystemExit, match="Several"):
        run_cli(monkeypatch, capsys, "voices", "forget", "kim")
    assert "Forgot Maya" in run_cli(monkeypatch, capsys, "voices", "forget", "maya")
    with pytest.raises(SystemExit, match="No saved voice"):
        run_cli(monkeypatch, capsys, "voices", "forget", "maya")
    assert "off" in run_cli(monkeypatch, capsys, "voices", "off")
    assert library.listing()["enabled"] is False and len(library.listing()["voices"]) == 2
    run_cli(monkeypatch, capsys, "voices", "on")
    run_cli(monkeypatch, capsys, "voices", "off", "--forget")
    assert library.listing() == {"enabled": False, "model": MODEL, "voices": []}
    run_cli(monkeypatch, capsys, "voices", "on")
    library.remember("Maya", band(2), 30.0)
    run_cli(monkeypatch, capsys, "voices", "forget-all")
    assert not library.store.path.exists()


# The real model (`-m model`): `say` voices


def real_service(library):
    path = model_path()
    return sp.SpeakerLabels(
        embedder_factory=lambda: sp.OnnxEmbedder(path), downloaded=lambda: True, library=library
    )


LINES = [
    "We should ship the beta on Friday, but only if the review is done by then.",
    "The onboarding flow still drops about a third of new users at the second screen.",
    "I talked to the design team and they want two more days for the settings page.",
    "Can we move the budget meeting to Thursday afternoon instead of Wednesday?",
    "Let's keep the scope small and write down everything we decided today.",
]
OTHER = [
    "I think the numbers from last quarter look better than we expected.",
    "Send me the spec when it is ready and I will read it tonight.",
    "The customer asked whether the export works offline on their laptops.",
]


def speech_of(tmp_path, voice, lines):
    gap = np.zeros(int(0.4 * sp.RATE), dtype=np.float32)
    return np.concatenate([np.concatenate([say(tmp_path, voice, line), gap]) for line in lines])


@pytest.mark.model
def test_real_model_remembers_in_one_note_and_recognises_in_the_next(tmp_path):
    library = vs.VoiceLibrary(vs.VoiceStore(tmp_path / "voices"))
    labels = real_service(library)
    samantha = speech_of(tmp_path, "Samantha", LINES)
    daniel = speech_of(tmp_path, "Daniel", OTHER)

    async def run():
        # Note 1: Samantha alone, cut into segments as Notes would; remember her.
        for start in range(0, len(samantha), 12 * sp.RATE):
            await labels.label(
                session(1), pcm(samantha[start : start + 12 * sp.RATE]), None, "a", "a"
            )
        note = labels.sessions.notes[session(1)]
        embedding, seconds = labels.person(session(1), note.generation, 0)
        library.remember("Samantha", embedding, seconds)
        # Note 2: Samantha and a voice nobody saved (Daniel).
        out = []
        for audio in (daniel, speech_of(tmp_path, "Samantha", OTHER)):
            out.append(await labels.label(session(2), pcm(audio), None, "a", "a"))
        return out

    first, second = asyncio.run(run())
    assert first["matches"] == []
    assert [(m["speaker"], m["name"]) for m in second["matches"]] == [(1, "Samantha")]


@pytest.mark.model
def test_real_model_remembers_and_identifies_from_clips(tmp_path):
    library = vs.VoiceLibrary(vs.VoiceStore(tmp_path / "voices"))
    labels = real_service(library)

    async def run():
        for voice in ("Samantha", "Daniel"):
            embedding, seconds = await labels.clip(
                pcm(speech_of(tmp_path, voice, LINES)[: 30 * sp.RATE])
            )
            library.remember(voice, embedding, seconds)
        heard = {}
        for person, voice in enumerate(("Daniel", "Karen", "Samantha")):
            heard[person] = await labels.clip(
                pcm(speech_of(tmp_path, voice, OTHER)[: 15 * sp.RATE])
            )
        return vs.match(heard, library.candidates())

    found = asyncio.run(run())
    assert {person: voice.name for person, voice in found.items()} == {0: "Daniel", 2: "Samantha"}


def test_import_takes_only_an_agreeing_model(app, library):
    """The Mac's Keychain voices (#18, `wespeaker_v2`, which agrees) move over once."""
    print_ = vs.encode(vs.unit(np.arange(1, vs.DIMENSIONS + 1, dtype=np.float32)))
    body = {
        "action": "import",
        "name": "Maya",
        "embedding": print_,
        "seconds": 31.0,
        "model": "wespeaker_v2@df2625a",
    }
    for bad in (
        {"model": "another@1"},
        {"embedding": vs.encode(np.ones(16, dtype=np.float32))},
        {"embedding": "not base64!"},
        {"seconds": "31"},
        {"seconds": True},
        {"name": "A: B"},
    ):
        assert post(app, {**body, **bad}, 400)["code"] == "bad_speakers", bad
    assert post(app, {**body, "seconds": 12.0}, 409)["code"] == "too_short"
    saved = post(app, body)["voice"]
    assert saved["name"] == "Maya" and saved["compatible"] and saved["seconds"] == 31.0
    (candidate,) = library.candidates()
    np.testing.assert_allclose(candidate.embedding, vs.decode(print_), atol=1e-6)
    library.disable()
    assert post(app, body, 409)["code"] == "disabled"
