"""Scorer checks and synthetic, fake-helper cleanup regressions."""

import sys
from pathlib import Path

import pytest
from conftest import TEST_TIMEOUT

from chirp_server.cleanup_eval import load_cases, score
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector, rejected
from chirp_server.managed_cleanup import ManagedCleanup
from chirp_server.profiles import BUILTINS, LIVE_NOTES, LIVE_NOTES_ID

CASES = load_cases(Path(__file__).with_name("cleanup_eval.jsonl"))
PROFILES = {**BUILTINS, LIVE_NOTES_ID: LIVE_NOTES}


def test_synthetic_fixture_contract():
    assert len(CASES) >= 75
    assert len({case["id"] for case in CASES}) == len(CASES)
    for case in CASES:
        assert score(case, case["expected"]).passed, case["id"]
        assert not rejected(
            case["raw"], case["expected"], "stop", PROFILES[case.get("profile", "default")]
        ), case["id"]


def test_scorer_keeps_order_counts_and_required_phrases():
    case = CASES[0]
    assert score(case, case["expected"].upper().rstrip(".").replace(",", "")).passed
    assert not score(case, "Meet on Tuesday at 3 p.m. and bring the slides.").passed
    assert not score(case, case["expected"] + " Monday").passed
    assert not score(
        case, "So Tuesday meet on I think we should at 3 p.m. and bring the slides."
    ).passed
    assert not score(case, case["raw"]).passed  # Raw fallback is not successful cleanup.
    assert not score(CASES[6], "Please send the the draft to Maya.").passed
    assert not score(CASES[33], "I think we should keep the current plan!").passed


def test_near_match_is_bounded_and_does_not_override_must_keep():
    case = {
        "raw": "",
        "expected": "I think we should send the report before lunch and then call Maya today",
        "must_keep": ["I think we should", "before lunch"],
        "must_drop": ["um"],
    }
    assert score(case, case["expected"].replace("today", "tomorrow")).near
    assert not score(case, case["expected"].replace("think ", "")).passed
    assert not score(case, case["expected"] + " um").passed
    assert not score(case, "Send the report.").near


@pytest.mark.parametrize(
    "raw,reply",
    [
        (CASES[0]["raw"], "Meet on Tuesday at 3 p.m. and bring the slides."),
        ("I think maybe we should wait.", "We should wait."),
        (
            "I do not think we should delete the backup yet.",
            "I do think we should delete the backup yet.",
        ),
        (
            "First check the logs, then restart the worker.",
            "First restart the worker, then check the logs.",
        ),
        ("I like the layout.", "I the layout."),
        ("Do you know the answer?", "Do the answer?"),
        ("That was very, very good.", "That was very good."),
        ("I mean what I said.", "What I said."),
        ("Open package dot json.", "Open package.json."),
        ("Run git rebase dash i.", "Run git rebase -i."),
        ("Set retry_count = 3.", "Set retry_count > 3."),
        ("Call fetch_data(url).", "Call fetch_data[url]."),
        (
            "Visit https://example.org/a_b?q=2&lang=es.",
            "Visit https://example.org/a_b?q=2&lang=es#now.",
        ),
        ("The total is 19.95.", "The total is 19:95."),
        ("I am really pissed off.", "I am really upset."),
        ("Can you explain the failure?", "The failure was caused by a timeout."),
        ("Meet Monday no wait Tuesday and bring the slides.", "Meet Tuesday."),
        ("Meet at the blue door I mean the green door.", "Meet at the green door."),
    ],
)
async def test_fake_helper_rejects_unfaithful_edits(raw, reply):
    config = CorrectionConfig(mode="managed", timeout=TEST_TIMEOUT)
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
        result = await corrector.process(raw)
        assert result.text == raw and result.error == "rejected" and not result.corrected
    finally:
        await corrector.close()
