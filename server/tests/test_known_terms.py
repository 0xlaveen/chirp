"""Known-term respelling: only clear contexts are licensed, and only exactly that edit."""

import sys
from pathlib import Path

import pytest
from conftest import TEST_TIMEOUT

from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector, rejected
from chirp_server.known_terms import TERMS_RULE, respell
from chirp_server.managed_cleanup import ManagedCleanup
from chirp_server.profiles import BUILTINS, LIVE_NOTES, system_prompt


@pytest.mark.parametrize(
    "raw,fixed",
    [
        ("ask clawed code to fix it", "ask Claude Code to fix it"),
        ("Clawd code is open", "Claude Code is open"),
        ("please ask clawed to review it", "please ask Claude to review it"),
        ("I told clawed about it", "I told Claude about it"),
        ("thanks clawed, that works", "thanks Claude, that works"),
        ("put it behind tail scale", "put it behind Tailscale"),
        ("push it to get hub on mac OS", "push it to GitHub on macOS"),
        ("run kwen 3 locally", "run Qwen locally"),
    ],
)
def test_respell_fixes_clear_contexts(raw, fixed):
    assert respell(raw) == fixed


@pytest.mark.parametrize(
    "raw",
    [
        "the cat clawed the sofa",
        "the bear clawed at the door",
        "with clawed paws",
        "we need to claw back the budget",
        "the cloud code runs in the cloud",
        "he clawed codex",
        "I like the macOS and GitHub already spelled right",
        "the clawedge case",
    ],
)
def test_respell_leaves_everything_else(raw):
    assert respell(raw) == raw


ALL = [*BUILTINS.values(), LIVE_NOTES]


@pytest.mark.parametrize("profile", ALL, ids=lambda profile: profile.id)
def test_respelling_passes_every_guard(profile):
    raw = "um ask clawed code to fix it"
    assert not rejected(raw, "ask Claude Code to fix it", "stop", profile)
    # Leaving the word as heard is still a faithful edit.
    assert not rejected(raw, "ask clawed code to fix it", "stop", profile)


@pytest.mark.parametrize("profile", ALL, ids=lambda profile: profile.id)
@pytest.mark.parametrize(
    "raw,text",
    [
        # Any other substitution of the same word, or a respelling without the context.
        ("ask clawed code to fix it", "Ask Claudia Code to fix it."),
        ("ask clawed to review it", "Ask Maya to review it."),
        ("the cat clawed the sofa", "The cat Claude the sofa."),
        ("the cat clawed the sofa", "The cat scratched the sofa."),
        ("with clawed paws", "With Claude paws."),
        ("the cloud code runs", "The Claude Code runs."),
        # The licence does not extend to dropping a word next to the fixed term.
        ("ask clawed code to not fix it", "Ask Claude Code to fix it."),
    ],
)
def test_no_other_substitution_is_licensed(profile, raw, text):
    assert rejected(raw, text, "stop", profile)


def test_prompts_carry_the_rule():
    for profile in BUILTINS.values():
        if profile.id != "custom":
            assert "Claude Code" in system_prompt(profile), profile.id
    assert TERMS_RULE in system_prompt(LIVE_NOTES)
    assert TERMS_RULE in system_prompt(BUILTINS["chat"])
    # The Live Notes rule that forbids respelling names now names this one exception.
    assert "except a known term" in LIVE_NOTES.prompt


@pytest.mark.parametrize("profile_id", ["default", "live_notes"])
async def test_fake_helper_respelling_is_applied_and_others_fall_back(profile_id):
    raw = "um ask clawed code to fix it"
    for reply, corrected in (("Ask Claude Code to fix it.", True), ("Ask Maya to fix it.", False)):
        config = CorrectionConfig(mode="managed", timeout=TEST_TIMEOUT, notes_timeout=TEST_TIMEOUT)
        corrector = Corrector(config)
        corrector.managed = ManagedCleanup(
            config,
            command=[
                sys.executable,
                "-u",
                str(Path(__file__).with_name("fake_cleanup_helper.py")),
                "--reply",
                reply,
            ],
        )
        try:
            result = await corrector.process(raw, profile_id)
            assert result.corrected is corrected
            assert result.text == (reply if corrected else raw)
        finally:
            await corrector.close()
