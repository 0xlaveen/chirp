"""`start.learned` (#220): the user's own terms and app preferences, learned from their edits.

The guards accept a user's term exactly as they accept the built-in known terms: only the
exact heard -> term respelling, nothing free-form, and never an added word. All text synthetic.
"""

import logging

import pytest
import test_correction_server
from conftest import HEADERS, PCM, START, TOKEN
from starlette.testclient import TestClient
from test_protocol import final

from chirp_server.app import create_app
from chirp_server.config import CorrectionConfig
from chirp_server.correction import rejected
from chirp_server.engine import FakeEngine
from chirp_server.known_terms import UserTerm, parse_user_terms, respell
from chirp_server.learned import Learned, learned_prompt, parse_learned
from chirp_server.profiles import BUILTINS, LIVE_NOTES, system_prompt

# The loopback OpenAI-compatible endpoint the correction-server tests use.
fake_lm = test_correction_server.fake_lm

KUBE = UserTerm("Kubernetes", ("cooper netties",))
ANTHROPIC = UserTerm("Anthropic", ("and throw pick",))
BLOCK = {
    "v": 1,
    "terms": [
        {"term": "Kubernetes", "heard": ["cooper netties"]},
        {"term": "Anthropic", "heard": ["and throw pick"]},
    ],
    "style": ["lowercase_start", "no_final_period"],
    "examples": [{"said": "sounds good I'll push it", "wanted": "sounds good, I'll push it"}],
}


def test_parse_a_full_block():
    learned = parse_learned(BLOCK)
    assert learned.terms == (KUBE, ANTHROPIC)
    assert learned.style == ("lowercase_start", "no_final_period")
    assert learned.examples == (("sounds good I'll push it", "sounds good, I'll push it"),)
    assert learned
    assert not Learned()


def test_a_newer_version_is_ignored_not_refused():
    assert parse_learned({"v": 2, "anything": ["new"]}) is None


@pytest.mark.parametrize(
    "block",
    [
        None,
        [],
        {},
        {"v": "1"},
        {"v": 0},
        {"v": 1, "extra": True},
        {"v": 1, "style": ["shout"]},
        {"v": 1, "style": "lowercase_start"},
        {"v": 1, "terms": [{"term": ""}]},
        {"v": 1, "terms": [{"term": "x" * 49}]},
        {"v": 1, "terms": [{"term": "Kubernetes", "heard": "cooper netties"}]},
        {"v": 1, "terms": [{"term": "Kubernetes", "heard": ["a", "b", "c", "d", "e"]}]},
        {"v": 1, "terms": [{"term": "Kube\nrnetes"}]},
        {"v": 1, "terms": [{"term": "Kubernetes", "extra": 1}]},
        {"v": 1, "terms": [{"term": f"t{i}"} for i in range(101)]},
        {"v": 1, "examples": [{"said": "a", "wanted": "b"}] * 4},
        {"v": 1, "examples": [{"said": "a" * 301, "wanted": "b"}]},
        {"v": 1, "examples": [{"said": " ", "wanted": "b"}]},
        {"v": 1, "examples": [{"said": "a"}]},
    ],
)
def test_malformed_blocks_are_refused(block):
    with pytest.raises(ValueError):
        parse_learned(block)


def test_a_term_never_respells_into_a_phrase_that_already_holds_it():
    assert parse_user_terms([{"term": "Go", "heard": ["go lang", "goal"]}]) == (
        UserTerm("Go", ("goal",)),
    )


@pytest.mark.parametrize(
    "raw,fixed",
    [
        ("deploy it to cooper netties today", "deploy it to Kubernetes today"),
        ("Cooper  Netties is down", "Kubernetes is down"),
        ("thanks and throw pick", "thanks Anthropic"),
        ("ask clawed code about cooper netties", "ask Claude Code about Kubernetes"),
    ],
)
def test_user_terms_respell_exactly_what_was_heard(raw, fixed):
    assert respell(raw, (KUBE, ANTHROPIC)) == fixed


@pytest.mark.parametrize(
    "raw",
    ["my cooper nettiess", "super cooper netties-like", "cooper and netties", "the coopers"],
)
def test_user_terms_need_whole_words(raw):
    assert respell(raw, (KUBE,)) == raw


ALL = [*BUILTINS.values(), LIVE_NOTES]


@pytest.mark.parametrize("profile", ALL, ids=lambda profile: profile.id)
def test_every_guard_accepts_a_user_term_like_a_built_in_one(profile):
    raw = "um deploy it to cooper netties"
    assert not rejected(raw, "deploy it to Kubernetes", "stop", profile, (KUBE,))
    # Without the user's term the same respelling is a free-form substitution.
    if profile.id not in {"notes", "custom"}:
        assert rejected(raw, "deploy it to Kubernetes", "stop", profile)
    # Leaving the words as heard is still faithful.
    assert not rejected(raw, "deploy it to cooper netties", "stop", profile, (KUBE,))


@pytest.mark.parametrize("profile", [BUILTINS["default"], BUILTINS["chat"], BUILTINS["email"]])
def test_a_user_term_never_licenses_added_content(profile):
    raw = "deploy it to cooper netties"
    # The term may replace what was heard, never appear where nothing was said.
    assert rejected(raw, "Deploy it to Kubernetes and Anthropic.", "stop", profile, (KUBE,))
    assert rejected("deploy it today", "Deploy Kubernetes today.", "stop", profile, (KUBE,))
    assert rejected(raw, "Deploy it to Kubernetes now.", "stop", profile, (KUBE,))


def test_learned_style_passes_the_guard():
    chat = BUILTINS["chat"]
    assert not rejected("Sounds good. I'll push it.", "sounds good, I'll push it", "stop", chat)


def test_the_prompt_is_unchanged_without_learned():
    for profile in BUILTINS.values():
        assert system_prompt(profile) == system_prompt(profile, learned=None)
        assert system_prompt(profile) == system_prompt(profile, learned=Learned())


def test_the_prompt_lists_terms_style_and_examples_inside_the_core_rules():
    prompt = system_prompt(BUILTINS["chat"], learned=parse_learned(BLOCK))
    section = learned_prompt(parse_learned(BLOCK))
    assert section in prompt
    assert 'Kubernetes (heard as "cooper netties")' in section
    assert "Start with a lowercase letter" in section
    assert "Do not end with a period" in section
    assert "\"sounds good I'll push it\" -> sounds good, I'll push it" in section
    assert "Never add a term the speaker did not say." in section
    # The fixed core rules still open and close the prompt.
    assert prompt.endswith(system_prompt(BUILTINS["chat"]).rsplit("\n\n", 1)[1])


def test_examples_are_one_line_each():
    learned = parse_learned({"v": 1, "examples": [{"said": "a b", "wanted": "line one\nline two"}]})
    assert learned_prompt(learned).splitlines()[-1] == '"a b" -> line one line two'


def stream(settings, start, raw="please deploy it to cooper netties"):
    with TestClient(create_app(settings, FakeEngine(raw), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(start)
            first = ws.receive_json()
            if first["type"] == "error":
                return first
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            return final(ws)


def test_learned_reaches_the_prompt_and_the_guard_through_the_app(settings, fake_lm, caplog):
    settings.correction = CorrectionConfig(
        enabled=True, base_url=fake_lm.url, model="test-7b-instruct", timeout=5.0
    )
    fake_lm.reply = "please deploy it to Kubernetes"
    caplog.set_level(logging.DEBUG)
    result = stream(
        settings, {**START, "correction": True, "correction_profile": "chat", "learned": BLOCK}
    )
    assert result["text"] == "please deploy it to Kubernetes" and result["corrected"] is True
    system = fake_lm.requests[0]["body"]["messages"][0]["content"]
    assert 'Kubernetes (heard as "cooper netties")' in system
    # Never logged: not the terms, not the examples.
    assert "Kubernetes" not in caplog.text and "cooper" not in caplog.text
    assert "sounds good" not in caplog.text


def test_without_learned_the_same_respelling_is_rejected(settings, fake_lm):
    settings.correction = CorrectionConfig(
        enabled=True, base_url=fake_lm.url, model="test-7b-instruct", timeout=5.0
    )
    fake_lm.reply = "please deploy it to Kubernetes"
    result = stream(settings, {**START, "correction": True})
    assert result["text"] == "please deploy it to cooper netties"
    assert result["correction_error"] == "rejected"


def test_a_malformed_block_is_a_bad_request(settings):
    result = stream(settings, {**START, "learned": {"v": 1, "style": ["shout"]}})
    assert result["type"] == "error" and result["code"] == "bad_request"


def test_a_newer_block_and_clean_up_off_are_harmless(settings):
    assert stream(settings, {**START, "learned": {"v": 9, "future": True}})["type"] == "final"
    plain = stream(settings, {**START, "learned": BLOCK})
    assert plain["text"] == "please deploy it to cooper netties" and plain["corrected"] is False
