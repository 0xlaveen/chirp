"""Live Notes segment clean-up on long, ASR-mangled talks (`notes_talk_eval.jsonl`, invented):
the restarts the `live_notes` guard now licenses, what it still protects, and hedge restoration.
Dictation guards are not involved."""

import asyncio
import sys
from pathlib import Path

import pytest

from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector, rejected, restore_hedges
from chirp_server.managed_cleanup import ManagedCleanup
from chirp_server.profiles import LIVE_NOTES, LIVE_NOTES_ID

HELPER = Path(__file__).with_name("fake_cleanup_helper.py")


def accepted(raw, text):
    return not rejected(raw, text, "stop", LIVE_NOTES)


@pytest.mark.parametrize(
    "raw,text",
    [
        (
            "my name is Dan and I'm one of the, one of the founders at Nova lith",
            "My name is Dan and I'm one of the founders at Nova lith.",
        ),
        (
            "and it's a kind of a a stress test you can run",
            "And it's a stress test you can run.",
        ),
        (
            "we're going to do a, an actual launch of it",
            "We're going to do an actual launch of it.",
        ),
        ("it's not wrong, it's just, it's not the same", "It's not wrong, it's just not the same."),
        ("there's only, there's six engineers here", "There's only six engineers here."),
        (
            "the second screen is where hal sion, sorry, halcyon talks to you",
            "The second screen is where halcyon talks to you.",
        ),
    ],
)
def test_talk_restarts_are_licensed(raw, text):
    assert accepted(raw, text)


@pytest.mark.parametrize(
    "raw,text",
    [
        # A number said twice is a number, not a stutter.
        ("it ships in twenty twenty six", "It ships in twenty six."),
        # An apology is not a repair.
        ("I'm sorry, we can't make it on Friday", "We can't make it on Friday."),
        ("sorry about that, the build is green", "The build is green."),
        # A repair never drops a number or a negation.
        ("the budget is two, sorry, three thousand", "The budget is three thousand."),
        ("it's not, sorry, it's fine now", "It's fine now."),
        # Only the subject copy may go: "only" survives.
        ("there's only, there's six engineers here", "There's six engineers here."),
        # A hedge is never deleted; a respelled name is a substitution.
        ("we have around I think two hundred seats", "We have around two hundred seats."),
        ("we built Castrel last year", "We built Kestrel last year."),
    ],
)
def test_talk_guard_still_protects(raw, text):
    assert not accepted(raw, text)


def test_dropped_hedges_are_put_back():
    raw = "we have around, uh, I think two hundred seats, and I guess forty teams"
    text = "We have around two hundred seats, and forty teams."
    restored = restore_hedges(raw, text)
    assert restored == "We have around I think two hundred seats, and I guess forty teams."
    assert accepted(raw, restored)
    assert (
        restore_hedges(raw, "We have around, I think two hundred seats, and I guess forty teams.")
        is None
    )
    # Another unlicensed edit: nothing is restored, the segment stays rejected.
    assert restore_hedges(raw, "We have around two hundred seats.") is None
    assert restore_hedges(raw, "We have around two hundred users, and forty teams.") is None


def test_a_hedge_at_the_end_is_put_back_before_the_full_stop():
    raw = "it's about two hundred I think"
    restored = restore_hedges(raw, "It's about two hundred.")
    assert restored == "It's about two hundred I think." and accepted(raw, restored)


def test_the_clean_up_restores_hedges_end_to_end():
    raw = "um so we have around, uh, I think two hundred seats"

    async def go():
        config = CorrectionConfig(mode="managed", notes_timeout=5)
        corrector = Corrector(config)
        command = [
            sys.executable,
            "-u",
            str(HELPER),
            "--reply",
            "We have around two hundred seats.",
        ]
        corrector.managed = ManagedCleanup(config, command=command)
        try:
            return await corrector.process(raw, LIVE_NOTES_ID), await corrector.process(raw)
        finally:
            await corrector.close()

    notes, dictation = asyncio.run(go())
    assert notes.corrected and notes.text == "We have around I think two hundred seats."
    # Dictation correction is untouched: the same reply is rejected there as before.
    assert not dictation.corrected and dictation.error == "rejected"
