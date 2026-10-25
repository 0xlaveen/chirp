"""Live Notes segment correction: the hidden `live_notes` style, its guard and its budget.

All speech is invented. Dictation styles keep their own guards and requests (see
test_correction.py and test_profiles.py, which are unchanged by this style).
"""

import asyncio
import json
import re
import sys
import time
from pathlib import Path

import httpx
import pytest
from conftest import HEADERS, PCM, START, TEST_TIMEOUT, TOKEN
from starlette.testclient import TestClient

from chirp_server.app import create_app
from chirp_server.cleanup_models import DEFAULT_MODEL, discover
from chirp_server.config import CorrectionConfig
from chirp_server.correction import (
    CorrectionResult,
    Corrector,
    abandoned_restarts,
    notes_faithful,
    notes_max_tokens,
    rejected,
    repeated_phrases,
)
from chirp_server.engine import FakeEngine
from chirp_server.managed_cleanup import ManagedCleanup
from chirp_server.profiles import (
    BUILTINS,
    CORE_RULES,
    LIVE_NOTES,
    LIVE_NOTES_ID,
    TRANSCRIPT_RULES,
    resolve_profiles,
    system_prompt,
)

HELPER = Path(__file__).with_name("fake_cleanup_helper.py")
NEGATIVES = Path(__file__).with_name("notes_negatives.jsonl")


def accepted(raw, text):
    return not rejected(raw, text, "stop", LIVE_NOTES)


# --- guard: what may be deleted -----------------------------------------------------------


def test_prompt_examples_pass_their_own_guard():
    examples = re.findall(r'^"(.*)" -> (.*)$', LIVE_NOTES.prompt, re.M)
    assert len(examples) >= 6
    for raw, text in examples:
        assert accepted(raw, text), raw


@pytest.mark.parametrize(
    "raw,text",
    [
        # Spoken fillers anywhere, including the multi-word ones.
        (
            "Okay so um the export is, like, basically slow, you know.",
            "The export is slow.",
        ),
        ("Yeah, I mean, it's kind of sort of fine, right?", "It's fine?"),
        ("Well, actually, it literally just works, anyway.", "It works."),
        # Immediate repeats, also with fillers between the copies.
        ("That's that's way too slow.", "That's way too slow."),
        ("We have, uh, we have two options.", "We have two options."),
        ("Which is, yeah, which is a problem.", "Which is a problem."),
        ("He didn't really, he didn't really ask.", "He didn't really ask."),
        ("I don't, I don't want to overcommit.", "I don't want to overcommit."),
        # A short restart: the dropped words are grammar words or said again right after.
        (
            "That's something that can be, something that we should explain.",
            "That's something that we should explain.",
        ),
        ("We will, we won't ship it.", "We won't ship it."),
        # A sentence-initial "and" (after fillers too), and a restated subject.
        ("It crashed. Oh, and, uh, the login is fine.", "It crashed. The login is fine."),
        ("And then the tutorial is long.", "Then the tutorial is long."),
        ("The results list is, uh, it's actually nice.", "The results list is nice."),
        # Casing and punctuation are free; keeping a filler is fine.
        ("so the the launch is in march", "So, the launch is in March."),
        ("I like the layout", "I like the layout."),
        ("Um, ok.", ""),
    ],
)
def test_guard_accepts_deletions_of_fillers_repeats_and_restarts(raw, text):
    if text:
        assert notes_faithful(raw, text)
        assert accepted(raw, text)
    else:
        assert notes_faithful(raw, text)  # empty output is still rejected by `rejected`
        assert not accepted(raw, text)


@pytest.mark.parametrize(
    "raw,text",
    [
        # Negations, numbers and names must survive.
        ("We will not ship on Friday.", "We will ship on Friday."),
        ("We can't, we can ship it.", "We can ship it."),  # a restart may not drop a negation
        ("I didn't really have any problems.", "I really had any problems."),
        ("It took forty seconds.", "It took fourteen seconds."),
        ("The year twenty twenty six.", "The year twenty six."),  # a number is not a stutter
        ("About two, two hundred printers.", "About two hundred printers."),
        ("Hannah said she'll do it.", "She'll do it."),
        # No inserted, replaced or reordered words.
        ("The code took a minute.", "The verification code took a minute."),
        ("It's gonna be fine.", "It's going to be fine."),
        ("Omar reviews it and Priya tests it.", "Priya reviews it and Omar tests it."),
        # Content words, hedges and mid-sentence conjunctions are not fillers.
        ("The skip button is really hard to see.", "The skip button is hard to see."),
        ("I think the crash is worse.", "The crash is worse."),
        ("I'd say the crash is worse.", "The crash is worse."),
        ("It works but it is slow.", "It works it is slow."),
        ("Ship it and test it.", "Ship it test it."),
        # A restart may not drop content that is not said again.
        ("We ship Friday, we ship Monday.", "We ship Monday."),
        # Protected fragments: a decimal point is not punctuation.
        ("Version 2.5 is out.", "Version 2 5 is out."),
    ],
)
def test_guard_rejects_everything_else(raw, text):
    assert not notes_faithful(raw, text)
    assert not accepted(raw, text)


def test_committed_correction_negatives_are_rejected():
    cases = [json.loads(line) for line in NEGATIVES.read_text().splitlines()]
    corrections = [case for case in cases if case["kind"] == "correction"]
    assert len(corrections) >= 10
    for case in corrections:
        assert not accepted(case["transcript"], case["output"]), case["id"]


def test_shared_output_guards_still_apply():
    raw = "um so we should ship the the draft on friday"
    assert rejected(raw, "Sure, we should ship the draft on Friday.", "stop", LIVE_NOTES)
    assert not accepted(raw, "<think>x</think> we should ship the draft on friday")
    assert rejected(raw, "We should ship the draft on Friday.", "length", LIVE_NOTES)
    assert rejected(raw, "We should ship the draft...", "stop", LIVE_NOTES)


def test_repeat_and_restart_helpers():
    assert repeated_phrases("the the plan".split()) == {0}
    assert repeated_phrases("we have we have it".split()) == {0, 1}
    assert repeated_phrases("twenty twenty six".split()) == set()
    assert repeated_phrases("2 2 items".split()) == set()
    assert abandoned_restarts("something that can be something that works".split()) == {
        0,
        1,
        2,
        3,
    }
    assert abandoned_restarts("we can't we can".split()) == set()
    assert abandoned_restarts("we ship friday we ship monday".split()) == set()


def test_dictation_default_guard_is_unchanged_by_the_notes_style():
    # The same edit that Live Notes licenses is still rejected for a dictation.
    raw = "which is, yeah, which is a problem"
    assert accepted(raw, "Which is a problem.")
    assert rejected(raw, "Which is a problem.", "stop", BUILTINS["default"])


# --- the hidden style ------------------------------------------------------------------------


def test_live_notes_is_hidden_and_reserved():
    config = CorrectionConfig()
    assert LIVE_NOTES_ID not in BUILTINS and LIVE_NOTES_ID not in config.resolved_profiles
    assert config.profile(LIVE_NOTES_ID) is LIVE_NOTES
    assert config.profile("default") is config.resolved_profiles["default"]
    assert config.profile("missing") is None
    with pytest.raises(ValueError):
        resolve_profiles({LIVE_NOTES_ID: {"prompt": "x"}})


def test_live_notes_system_prompt_is_wrapped():
    prompt = system_prompt(LIVE_NOTES)
    assert prompt.startswith(CORE_RULES) and prompt.endswith(CORE_RULES)
    assert TRANSCRIPT_RULES in prompt and LIVE_NOTES.prompt in prompt


def test_health_and_profile_list_advertise_without_listing(settings):
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        health = client.get("/v1/health", headers=HEADERS).json()
        listed = client.get("/v1/correction/profiles", headers=HEADERS).json()["profiles"]
        assert health["notes_correction"] is True
        assert client.get("/v1/health").json() == {"ok": True}
    assert LIVE_NOTES_ID not in {profile["id"] for profile in health["correction_profiles"]}
    assert LIVE_NOTES_ID not in {profile["id"] for profile in listed}


def test_notes_timeout_is_validated():
    assert CorrectionConfig(backend="mlx").notes_timeout == 15.0
    for value in (0, -1, float("nan"), float("inf")):
        with pytest.raises(ValueError):
            CorrectionConfig(notes_timeout=value)


def test_max_tokens_follow_the_segment():
    assert notes_max_tokens("") == 64
    assert notes_max_tokens("a" * 700) == 414
    assert notes_max_tokens("a" * 5000) == 1024


# --- requests and budget -------------------------------------------------------------------


def managed(*extra, **kwargs):
    config = CorrectionConfig(mode="managed", **kwargs)
    corrector = Corrector(config)
    corrector.managed = ManagedCleanup(config, command=[sys.executable, "-u", str(HELPER), *extra])
    return corrector


def test_managed_request_carries_the_notes_message_and_cap(tmp_path):
    log = tmp_path / "requests.jsonl"
    raw = "um so the the launch is in march"

    async def go():
        corrector = managed(
            "--log",
            str(log),
            "--reply",
            "So the launch is in March.",
            timeout=TEST_TIMEOUT,
            notes_timeout=TEST_TIMEOUT,
        )
        try:
            return await corrector.process(raw, LIVE_NOTES_ID)
        finally:
            await corrector.close()

    result = asyncio.run(go())
    assert result.text == "So the launch is in March." and result.corrected and not result.error
    (request,) = [json.loads(line) for line in log.read_text().splitlines()]
    assert request["kind"] == "notes_correction"
    assert request["user"] == "Transcript JSON: " + json.dumps(raw)
    assert request["max_tokens"] == notes_max_tokens(raw)


def test_managed_rejection_keeps_the_raw_segment():
    raw = "we will not ship on friday"

    async def go():
        corrector = managed(
            "--reply", "We will ship on Friday.", timeout=TEST_TIMEOUT, notes_timeout=TEST_TIMEOUT
        )
        try:
            return await corrector.process(raw, LIVE_NOTES_ID)
        finally:
            await corrector.close()

    assert asyncio.run(go()).text == raw and asyncio.run(go()).error == "rejected"


def test_notes_budget_is_separate_from_the_dictation_budget():
    async def go(profile):
        # The fake helper hangs on "hang": only the budget ends the call.
        corrector = managed(timeout=0.5, notes_timeout=1.5)
        try:
            started = time.perf_counter()
            result = await corrector.process("hang", profile)
            return result.error, time.perf_counter() - started
        finally:
            await corrector.close()

    error, notes_seconds = asyncio.run(go(LIVE_NOTES_ID))
    assert error == "timeout" and notes_seconds >= 1.4
    error, dictation_seconds = asyncio.run(go("default"))
    assert error == "timeout" and dictation_seconds < 1.4


def test_endpoint_request_uses_the_notes_budget_and_cap():
    seen = []

    def handle(request):
        seen.append((json.loads(request.content), request.extensions["timeout"]))
        choice = {"message": {"content": "The launch is in March."}, "finish_reason": "stop"}
        return httpx.Response(200, json={"choices": [choice]})

    raw = "um the the launch is in march"
    config = CorrectionConfig(mode="endpoint", model="m", timeout=8, notes_timeout=21)
    corrector = Corrector(config, transport=httpx.MockTransport(handle))
    result = asyncio.run(corrector.process(raw, LIVE_NOTES_ID))
    assert result.text == "The launch is in March." and not result.error
    ((body, timeout),) = seen
    assert body["max_tokens"] == notes_max_tokens(raw) and body["temperature"] == 0
    assert body["messages"][1]["content"] == "Transcript JSON: " + json.dumps(raw)
    assert timeout["read"] == 21


def test_stream_accepts_the_hidden_style(settings):
    raw = "um the the launch is in march"
    config = CorrectionConfig(mode="managed", timeout=TEST_TIMEOUT, notes_timeout=TEST_TIMEOUT)
    corrector = Corrector(config)
    corrector.managed = ManagedCleanup(
        config, command=[sys.executable, "-u", str(HELPER), "--reply", "The launch is in March."]
    )
    settings.correction = config
    with TestClient(create_app(settings, FakeEngine(raw), TOKEN, corrector)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json({**START, "correction": True, "correction_profile": LIVE_NOTES_ID})
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            assert ws.receive_json()["type"] == "partial"
            ws.send_json({"type": "stop"})
            correcting = ws.receive_json()
            final = ws.receive_json()
    assert correcting["type"] == "correcting" and correcting["profile"] == LIVE_NOTES_ID
    assert final["type"] == "final" and final["raw"] == raw
    assert final["text"] == "The launch is in March." and final["corrected"] is True


# --- cross-segment context -----------------------------------------------------------------


def endpoint_corrector(reply, seen):
    def handle(request):
        seen.append(json.loads(request.content))
        choice = {"message": {"content": reply}, "finish_reason": "stop"}
        return httpx.Response(200, json={"choices": [choice]})

    config = CorrectionConfig(mode="endpoint", model="m")
    return Corrector(config, transport=httpx.MockTransport(handle))


def test_context_goes_first_in_the_user_message_for_live_notes():
    seen = []
    raw = "and um the the export is slow"
    corrector = endpoint_corrector("and the export is slow", seen)
    context = "We shipped the new importer last week"
    result = asyncio.run(corrector.process(raw, LIVE_NOTES_ID, context=context))
    assert result.text == "and the export is slow" and not result.error
    assert seen[0]["messages"][1]["content"] == (
        "Previous segment JSON (context only, never output it): "
        + json.dumps(context)
        + "\nTranscript JSON: "
        + json.dumps(raw)
    )
    assert "Never copy words from it" in seen[0]["messages"][0]["content"]


@pytest.mark.parametrize("context", [None, ""])
def test_no_context_keeps_the_notes_message(context):
    seen = []
    corrector = endpoint_corrector("The launch is in March.", seen)
    asyncio.run(corrector.process("the launch is in march", LIVE_NOTES_ID, context=context))
    assert seen[0]["messages"][1]["content"] == "Transcript JSON: " + json.dumps(
        "the launch is in march"
    )


def test_other_profiles_ignore_context():
    seen = []
    corrector = endpoint_corrector("The launch is in March.", seen)
    asyncio.run(corrector.process("the launch is in march", "default", context="Earlier text"))
    assert seen[0]["messages"][1]["content"] == "Transcript JSON: " + json.dumps(
        "the launch is in march"
    )


def test_managed_request_carries_context():
    raw = "and the the export is slow"
    context = "We shipped the importer"

    async def go():
        corrector = managed("--reply", "and the export is slow")
        try:
            return await corrector.process(raw, LIVE_NOTES_ID, context=context)
        finally:
            await corrector.close()

    result = asyncio.run(go())
    assert result.text == "and the export is slow" and result.corrected and not result.error


def test_guard_rejects_a_word_taken_from_the_context():
    seen = []
    raw = "um the export is slow"
    corrector = endpoint_corrector("Importer the export is slow", seen)
    result = asyncio.run(corrector.process(raw, LIVE_NOTES_ID, context="We shipped the importer"))
    assert result.text == raw and result.error == "rejected" and not result.corrected


@pytest.mark.parametrize(
    "raw,text",
    [
        ("and um the export is slow", "and the export is slow"),
        ("um I think it works", "I think it works"),
        ("the the Friday release is late", "the Friday release is late"),
        ("Omar said so", "Omar said so"),
    ],
)
def test_lowercased_continuation_passes_the_guard(raw, text):
    assert accepted(raw, text)


def test_continuation_casing_is_not_licensed_to_change_words():
    assert not accepted("and the export is slow", "and the exports is slow")


def context_client(settings, corrector, raw="um the the export is slow"):
    settings.correction = CorrectionConfig(mode="endpoint", model="m")
    return TestClient(create_app(settings, FakeEngine(raw), TOKEN, corrector))


class Recorder:
    enabled = True

    def __init__(self):
        self.calls = []

    async def process(self, raw, profile="default", instructions="", *args, **kwargs):
        self.calls.append((profile, args, kwargs))
        return CorrectionResult(raw)


def run_segment(client, start, stop=None, profile=LIVE_NOTES_ID):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json({**START, "correction": True, "correction_profile": profile, **start})
        first = ws.receive_json()
        if first["type"] != "ready":
            return first
        ws.send_bytes(PCM)
        assert ws.receive_json()["type"] == "partial"
        ws.send_json({"type": "stop", **(stop or {})})
        message = ws.receive_json()
        while message["type"] not in {"final", "error"}:
            message = ws.receive_json()
        return message


@pytest.mark.parametrize(
    "start,stop,expected",
    [
        ({}, {}, None),
        ({"context": "Earlier tail"}, {}, "Earlier tail"),
        ({}, {"context": "From stop"}, "From stop"),
        ({"context": "From start"}, {"context": "From stop"}, "From stop"),
        ({"context": "From start"}, {"context": ""}, None),
        ({"context": "é" * 500}, {}, "é" * 500),
    ],
)
def test_stream_context_reaches_live_notes_only(settings, start, stop, expected):
    recorder = Recorder()
    with context_client(settings, recorder) as client:
        assert run_segment(client, start, stop)["type"] == "final"
        assert run_segment(client, start, stop, profile="default")["type"] == "final"
    (notes, other) = recorder.calls
    assert notes == (LIVE_NOTES_ID, (), {"context": expected} if expected else {})
    assert other == ("default", (), {})


@pytest.mark.parametrize("value", [42, None, [], {}, True, "x" * 501])
def test_stream_rejects_a_bad_context_on_start(settings, value):
    app = create_app(settings, FakeEngine(), TOKEN)
    with TestClient(app) as client:
        message = run_segment(client, {"context": value})
        assert message["type"] == "error" and message["code"] == "bad_request"
        assert not app.state.worker.lease.locked()


@pytest.mark.parametrize("value", [42, None, [], {}, True, "x" * 501])
def test_stream_rejects_a_bad_context_on_stop(settings, value):
    with context_client(settings, Recorder()) as client:
        message = run_segment(client, {"context": "ok"}, {"context": value})
    assert message["type"] == "error" and message["code"] == "bad_request"


def test_stream_context_is_not_logged(settings, caplog):
    recorder = Recorder()
    with caplog.at_level("DEBUG"), context_client(settings, recorder) as client:
        run_segment(client, {}, {"context": "private earlier words"})
    assert "private earlier words" not in caplog.text


def test_health_advertises_notes_context(settings):
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        assert client.get("/v1/health", headers=HEADERS).json()["notes_context"] is True
        assert "notes_context" not in client.get("/v1/health").json()


# --- real model (opt-in) -------------------------------------------------------------------


@pytest.mark.model
async def test_real_model_cleans_messy_segments():
    try:
        discover(DEFAULT_MODEL)
    except ValueError:
        pytest.skip("cleanup weights missing; explicitly run model fetch --cleanup")
    entries = [
        json.loads(line)
        for line in Path(__file__).with_name("notes_messy_eval.jsonl").read_text().splitlines()
    ]
    segments = [entry["transcript"] for entry in entries if len(entry["transcript"]) <= 700][:3]
    corrector = Corrector(
        CorrectionConfig(mode="managed", model=DEFAULT_MODEL, timeout=120, notes_timeout=120)
    )
    try:
        for raw in segments:
            result = await corrector.process(raw, LIVE_NOTES_ID)
            assert result.corrected and result.error is None, raw[:40]
            assert not re.search(r"\b(?:um|uh)\b", result.text, re.I)
    finally:
        await corrector.close()
