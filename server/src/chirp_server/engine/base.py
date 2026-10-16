"""Engine API and single-thread actor; the worker owns all model/stream state."""

import asyncio
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Protocol

import numpy as np


@dataclass(frozen=True)
class Partial:
    text: str
    # Full-quality finals may revise any word. Never promise an unstable prefix.
    stable: str = ""


class StreamSession(Protocol):
    def feed(self, pcm: np.ndarray) -> Partial | None: ...
    def finish(self) -> str: ...
    def cancel(self) -> None: ...


class Engine(Protocol):
    name: str

    def load(self) -> None: ...
    def transcribe(self, pcm: np.ndarray) -> str: ...
    def open_stream(self) -> StreamSession: ...


class EngineWorker:
    def __init__(self, engine: Engine):
        self.engine = engine
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="chirp-engine")
        self.lease = asyncio.Lock()
        self.ready = False

    async def call(self, method, *args):
        return await asyncio.get_running_loop().run_in_executor(self.executor, method, *args)

    async def start(self):
        await self.call(self.engine.load)
        warm = getattr(self.engine, "warm", None)
        if warm:
            await self.call(warm)
        else:
            await self.call(self.engine.transcribe, np.zeros(8000, dtype=np.float32))
        self.ready = True

    async def close(self):
        self.ready = False
        # Flush/destruct MLX objects on their owning thread too.
        close = getattr(self.engine, "close", None)
        if close:
            await self.call(close)
        self.executor.shutdown(wait=True, cancel_futures=True)
