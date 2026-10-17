"""Cached-only, synthetic real cleanup. Never log input or output."""

import pytest

from chirp_server.cleanup_models import discover
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector

pytestmark = pytest.mark.model


async def test_real_cleanup_dictation():
    try:
        discover()
    except ValueError:
        pytest.skip("cleanup weights missing; explicitly run model fetch --cleanup")
    corrector = Corrector(CorrectionConfig(mode="managed", timeout=60))
    try:
        result = await corrector.process(
            "um please send the project schedule tomorrow "
            "we need to review the API changes before lunch"
        )
        accepted = result.error is None and result.corrected
        preserved = all(word in result.text.lower() for word in ("schedule", "api", "lunch"))
        assert accepted and preserved
        repair = await corrector.process(
            "please book the review for monday no wait make that tuesday "
            "send the kubernetes notes before the meeting"
        )
        respected_repair = (
            repair.error is None
            and "tuesday" in repair.text.lower()
            and "monday" not in repair.text.lower()
            and "wait" not in repair.text.lower()
        )
        assert respected_repair
        repair = await corrector.process("book the review wednesday no wait make that friday")
        generalized_repair = (
            repair.error is None
            and "friday" in repair.text.lower()
            and "wednesday" not in repair.text.lower()
            and "wait" not in repair.text.lower()
        )
        assert generalized_repair
        question = await corrector.process(
            "can you explain how the database migration works "
            "please include the postgres rollback steps"
        )
        preserved_question = (
            question.error is None
            and question.text.lower().startswith("can you explain")
            and "rollback" in question.text.lower()
            and "?" in question.text
        )
        assert preserved_question
    finally:
        await corrector.close()
