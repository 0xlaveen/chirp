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
    # Alternatives retain their existing conservative regression contract. New styles
    # are evaluated on the production 4B model only.
    if model_id != DEFAULT_MODEL:
        cases = [case for case in cases if case.get("profile", "default") == "default"]
    failures = []
    groups = {}
    lost_content = []
    try:
        for case in cases:
            profile = case.get("profile", "default")
            result = await corrector.process(case["raw"], profile, case.get("instructions", ""))
            measured = score(case, result.text)
            groups.setdefault(profile, []).append(measured.passed)
            if not measured.passed:
                failures.append(case["id"])
            if not measured.must_keep:
                lost_content.append(case["id"])
        assert 1 - len(failures) / len(cases) >= THRESHOLDS[model_id], failures
        if model_id == DEFAULT_MODEL:
            assert not lost_content, lost_content
            for profile, passed in groups.items():
                assert sum(passed) / len(passed) >= 0.90, profile
    finally:
        await corrector.close()
