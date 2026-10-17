"""One supervised, warm helper; transcripts travel only through anonymous pipes."""

import asyncio
import json
import os
import sys

from .cleanup_models import discover


class ManagedCleanup:
    def __init__(self, config, *, command=None):
        self.config = config
        self.command = command
        self.process = None
        self.lock = asyncio.Lock()
        self.idle = None

    async def _read(self):
        line = await self.process.stdout.readline()
        payload = json.loads(line)
        if not isinstance(payload, dict):
            raise ValueError("Invalid helper reply")
        return payload

    async def _start(self):
        if self.process is not None and self.process.returncode is None:
            return
        if self.process is not None:
            await self.process.wait()
        command = self.command
        if command is None:
            directory = discover(self.config.model)
            command = [sys.executable, "-m", "chirp_server.cleanup_worker", str(directory)]
        self.process = await asyncio.create_subprocess_exec(
            *command,
            str(self.config.idle_seconds),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            env={**os.environ, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"},
            limit=256 * 1024,
        )
        if (await self._read()).get("ready") is not True:
            raise ValueError("Helper unavailable")

    async def generate(self, raw, prompt):
        # Queue time consumes the same budget, but a queued timeout never kills another call.
        async with asyncio.timeout(self.config.timeout):
            async with self.lock:
                if self.idle:
                    self.idle.cancel()
                    self.idle = None
                try:
                    await self._start()
                    self.process.stdin.write(
                        json.dumps({"text": raw, "system": prompt}).encode() + b"\n"
                    )
                    await self.process.stdin.drain()
                    reply = await self._read()
                    if reply.get("ok") is not True:
                        raise ValueError("Helper failed")
                    return reply["text"], reply.get("finish_reason")
                except BaseException:
                    # Cancellation must discard late replies before the next utterance.
                    await self._stop()
                    raise
                finally:
                    if self.process is not None:
                        self.idle = asyncio.create_task(self._unload())

    async def _unload(self):
        await asyncio.sleep(self.config.idle_seconds)
        async with self.lock:
            await self._stop()

    async def _stop(self):
        process, self.process = self.process, None
        if process is not None:
            if process.returncode is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
            await process.wait()

    async def close(self):
        if self.idle:
            self.idle.cancel()
            self.idle = None
        async with self.lock:
            await self._stop()
