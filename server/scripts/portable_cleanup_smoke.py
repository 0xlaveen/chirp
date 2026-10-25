"""Explicit real GGUF download/generation smoke. Synthetic text never enters output."""

import asyncio
import json
import time

from chirp_server.cleanup_models import PORTABLE_MODEL, fetch
from chirp_server.config import CorrectionConfig
from chirp_server.correction import Corrector
from chirp_server.notes import structure


async def main():
    fetch(PORTABLE_MODEL)  # Explicit test action; normal server startup remains offline.
    config = CorrectionConfig(
        mode="managed",
        backend="llama_cpp",
        model=PORTABLE_MODEL,
    )
    corrector = Corrector(config)
    try:
        started = time.perf_counter()
        result = await corrector.process(
            "um please send the schedule for Tuesday to the design group"
        )
        assert result.error is None and result.corrected, "portable cleanup failed"
        assert "tuesday" in result.text.lower() and "design group" in result.text.lower()
        cleanup_seconds = time.perf_counter() - started
        started = time.perf_counter()
        notes = await structure(
            corrector,
            "We decided to keep the current budget. We will not delay the review. "
            "I will send the schedule on Tuesday.",
            [],
        )
        assert notes.error is None, "portable Notes structuring failed"
        assert "not" in notes.markdown.lower(), "portable Notes lost negation"
        print(
            json.dumps(
                {
                    "portable_cleanup": "passed",
                    "notes": "passed",
                    "cleanup_seconds": round(cleanup_seconds, 2),
                    "notes_seconds": round(time.perf_counter() - started, 2),
                }
            )
        )
    finally:
        await corrector.close()


if __name__ == "__main__":
    asyncio.run(main())
