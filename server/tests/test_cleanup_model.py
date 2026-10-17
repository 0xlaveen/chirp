"""Cached-only, synthetic real cleanup. Failure messages contain case IDs only."""

from pathlib import Path

import pytest

from chirp_server.cleanup_eval import load_cases, score
from chirp_server.cleanup_models import DEFAULT_MODEL, MODELS, discover
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector

pytestmark = pytest.mark.model

# The default must clean at least 90% and retain every required content phrase.
# Alternatives have explicit, lower regression floors; they are not default candidates.
THRESHOLDS = {DEFAULT_MODEL: 0.90, "qwen3.5-2b-4bit": 0.55, "qwen3.5-0.8b-4bit": 0.45}


@pytest.mark.parametrize("model_id", MODELS)
async def test_real_cleanup_eval(model_id):
    try:
        discover(model_id)
    except ValueError:
        pytest.skip("cleanup weights missing; explicitly run model fetch --cleanup")
    cases = load_cases(Path(__file__).with_name("cleanup_eval.jsonl"))
    corrector = Corrector(CorrectionConfig(mode="managed", model=model_id, timeout=120))
    failures = []
    lost_content = []
    try:
        for case in cases:
            result = await corrector.process(case["raw"])
            measured = score(case, result.text)
            if not measured.passed:
                failures.append(case["id"])
            if not measured.must_keep:
                lost_content.append(case["id"])
        assert 1 - len(failures) / len(cases) >= THRESHOLDS[model_id], failures
        if model_id == DEFAULT_MODEL:
            assert not lost_content, lost_content
    finally:
        await corrector.close()
