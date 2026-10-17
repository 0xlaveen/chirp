"""One supervised, warm helper; transcripts travel only through anonymous pipes."""

import asyncio
import contextlib
import json
import logging
import os
import sys

from .cleanup_models import discover

log = logging.getLogger("chirp")

# A background prewarm overlaps the cold load with speech (~2.5 s, ~10 s on a busy
# host). It is bounded well beyond the per-call timeout so a wedged helper manager
# can never outlive a dictation session; a final may still wait for the in-flight
# load inside its own whole-call budget.
PREWARM_SECONDS = 30.0


class ManagedCleanup:
    def __init__(self, config, *, command=None):
        self.config = config
        self.command = command
        self.process = None
        self.lock = asyncio.Lock()
        self.idle = None
        self.load_task = None
        self.ready = False
        self.keep_loaded = False
        self.memory_mb = None

    @property
    def loaded(self) -> bool:
        return self.process is not None and self.process.returncode is None

    @property
    def loading(self) -> bool:
        return self.load_task is not None and not self.load_task.done()

    def memory(self, estimate_mb):
        """(memory MiB, estimated?); last measured value, else the catalog estimate."""
        if self.memory_mb is not None:
            return self.memory_mb, False
        return estimate_mb, estimate_mb is not None

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
        self.ready = False

    async def _ensure_ready(self):
        await self._start()
        if self.ready:
            return
        payload = await self._read()
        if payload.get("ready") is not True:
            raise ValueError("Helper unavailable")
        memory = payload.get("memory_mb")
        if isinstance(memory, (int, float)) and not isinstance(memory, bool) and memory >= 0:
            self.memory_mb = int(memory)
        self.ready = True

    def prewarm(self):
        """Begin the cold load in the background; never blocks the caller.

        Concurrent callers share one load. The load never counts against an
        utterance's correction timeout (only a final's own budget may wait for it),
        and on completion it arms the normal idle timer so a cancelled or aborted
        utterance still leaves a warm helper that unloads when idle.
        """
        if self.loaded or self.loading:
            return
        self.load_task = asyncio.create_task(self._prewarm())

    async def _prewarm(self):
        try:
            async with asyncio.timeout(PREWARM_SECONDS):
                async with self.lock:
                    try:
                        await self._ensure_ready()
                    except BaseException:
                        await self._stop()
                        raise
                    self._arm_idle()
        except asyncio.CancelledError:
            raise
        except Exception:
            # A failed background load is silent; the next final retries fresh and
            # falls back to raw text exactly as a cold start would.
            log.info("code=cleanup_prewarm_failed")
        finally:
            self.load_task = None

    async def wait_warm(self):
        """Await an in-flight background load (used by tests and benchmarks)."""
        if self.load_task is not None:
            await self.load_task

    async def generate(self, raw, prompt):
        # Queue time consumes the same budget, but a queued timeout never kills another call.
        async with asyncio.timeout(self.config.timeout):
            if self.load_task is not None:
                # A start-triggered prewarm may still be loading; this final's
                # whole-call timeout includes waiting for it.
                await self.load_task
            async with self.lock:
                if self.idle:
                    self.idle.cancel()
                    self.idle = None
                try:
                    await self._ensure_ready()
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
                    self._arm_idle()

    def _arm_idle(self):
        if self.idle:
            self.idle.cancel()
            self.idle = None
        if not self.keep_loaded:
            self.idle = asyncio.create_task(self._unload())

    async def _unload(self):
        await asyncio.sleep(self.config.idle_seconds)
        async with self.lock:
            if self.keep_loaded:
                return  # keep_loaded raced the armed timer; the helper stays resident.
            await self._stop()

    async def set_keep_loaded(self, value: bool):
        self.keep_loaded = value
        async with self.lock:
            if value:
                if self.idle:
                    self.idle.cancel()
                    self.idle = None
            elif self.loaded:
                self._arm_idle()

    async def _stop(self):
        process, self.process = self.process, None
        self.ready = False
        if process is not None:
            if process.returncode is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
            await process.wait()

    async def close(self):
        task, self.load_task = self.load_task, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        if self.idle:
            self.idle.cancel()
            self.idle = None
        async with self.lock:
            await self._stop()
