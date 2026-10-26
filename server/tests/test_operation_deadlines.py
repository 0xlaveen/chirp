"""Authenticated clients get the effective backend budgets without changing v1 liveness."""

import pytest
from conftest import HEADERS, TOKEN
from starlette.testclient import TestClient

from chirp_server.app import create_app
from chirp_server.config import CorrectionConfig
from chirp_server.engine import FakeEngine


@pytest.mark.parametrize(
    "backend,overrides,expected",
    [
        ("mlx", {}, (8, 15, 30, 45)),
        ("llama_cpp", {}, (30, 45, 90, 120)),
        (
            "llama_cpp",
            {"timeout": 42, "structure_timeout": 135, "reorganize_timeout": 180},
            (42, 45, 135, 180),
        ),
    ],
)
def test_effective_deadlines(settings, speakers, backend, overrides, expected):
    settings.correction = CorrectionConfig(mode="off", backend=backend, **overrides)
    with TestClient(create_app(settings, FakeEngine(), TOKEN, speakers=speakers)) as client:
        assert client.get("/v1/health").json() == {"ok": True}
        assert client.get("/v1/health", headers={"Authorization": "Bearer wrong"}).json() == {
            "ok": True
        }
        deadlines = client.get("/v1/health", headers=HEADERS).json()["operation_deadlines"]
        assert deadlines == dict(
            zip(
                (
                    "dictation",
                    "notes_correction",
                    "notes_structure",
                    "notes_reorganize",
                    "notes_edit",
                ),
                (*expected, expected[-1]),
                strict=True,
            )
        )
