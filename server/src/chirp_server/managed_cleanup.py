"""One supervised, warm helper; transcripts travel only through anonymous pipes."""

import asyncio
import contextlib
import ctypes
import ctypes.util
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

_RUSAGE_INFO_V4 = 4


class _RUsageInfoV4(ctypes.Structure):
    """rusage_info_v4 from <sys/resource.h>; only libproc writes into it."""

    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


_libproc = None


def helper_footprint_mb(pid: int) -> int | None:
    """The helper's current physical footprint in binary MiB: the same figure
    Activity Monitor's Memory column shows, via proc_pid_rusage(RUSAGE_INFO_V4).
    None when libproc or the call is unavailable (non-macOS host, dead pid)."""
    global _libproc
    try:
        if _libproc is None:
            name = ctypes.util.find_library("libproc")
            if not name:
                return None
            _libproc = ctypes.CDLL(name)
            _libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
            _libproc.proc_pid_rusage.restype = ctypes.c_int
        info = _RUsageInfoV4()
        if _libproc.proc_pid_rusage(pid, _RUSAGE_INFO_V4, ctypes.byref(info)) != 0:
            return None
        return round(info.ri_phys_footprint / 1048576)
    except (OSError, AttributeError, ValueError):
        return None


class Preempted(TimeoutError):
    """A reorganize generation gave way to a queued correction (reported as `timeout`)."""


class ManagedCleanup:
    def __init__(self, config, *, command=None):
        self.config = config
        self.command = command
        self.process = None
        self.lock = asyncio.Lock()
        # Corrections queued for the helper; a structuring caller never takes the lock
        # while any are waiting, so a correction never waits behind a *queued* structure.
        self.waiting = 0
        self.no_waiting = asyncio.Event()
        self.no_waiting.set()
        # Set while any correction waits: a running reorganize gives way to it (see generate).
        self.queued = asyncio.Event()
        self.idle = None
        self.load_task = None
        self.ready = False
        self.keep_loaded = False
        # The idle limit the running helper was launched with; 0 means it never exits on its own.
        self.launched_idle = None
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

    def _measure(self):
        """Refresh the loaded helper's resident footprint (Activity-Monitor-style).
        The helper's ready-line value stays only as the fallback for hosts where
        the server cannot read a child's physical footprint."""
        if self.process is not None and self.process.returncode is None:
            footprint = helper_footprint_mb(self.process.pid)
            if footprint is not None:
                self.memory_mb = footprint

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
        # The helper's own idle exit is a backstop for a wedged server. With keep_loaded it is
        # off (0): the server owns the lifecycle, and a closed pipe still ends the helper.
        self.launched_idle = 0 if self.keep_loaded else self.config.idle_seconds
        self.process = await asyncio.create_subprocess_exec(
            *command,
            str(self.launched_idle),
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
        self._measure()

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

    async def _read_preemptible(self):
        """A reorganize reply, abandoned as soon as a correction queues. A reorganize generation
        is the longest the helper runs (up to 1024 tokens, ~15 s), longer than a dictation's
        whole budget, so it gives way: the caller's error path kills the helper, the correction
        reloads it (about a second with cached weights) and the client retries the reorganize."""
        read = asyncio.ensure_future(self._read())
        queued = asyncio.ensure_future(self.queued.wait())
        try:
            done, _ = await asyncio.wait({read, queued}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in (read, queued):
                if not task.done():
                    task.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await task
        if read in done:
            return read.result()
        raise Preempted()

    async def _acquire(self, priority):
        if priority in {"structure", "reorganize"}:
            while True:
                await self.no_waiting.wait()
                await self.lock.acquire()
                if not self.waiting:
                    return
                # A correction queued while this caller waited for the lock: yield to it.
                self.lock.release()
        self.waiting += 1
        self.no_waiting.clear()
        self.queued.set()
        try:
            await self.lock.acquire()
        finally:
            self.waiting -= 1
            if not self.waiting:
                self.no_waiting.set()
                self.queued.clear()

    async def generate(
        self,
        raw,
        prompt,
        *,
        user=None,
        max_tokens=None,
        timeout=None,  # noqa: ASYNC109 - the whole-call budget includes queue time
        priority="correction",
    ):
        """One helper generation. `user` replaces the whole user message and `max_tokens`
        the output cap; both keys are sent only when given, so correction requests stay
        exactly `{"text", "system"}`. `priority="structure"` yields to queued corrections;
        `priority="reorganize"` also abandons its running generation when one queues."""
        request = {"text": raw, "system": prompt}
        if user is not None:
            request["user"] = user
        if max_tokens is not None:
            request["max_tokens"] = max_tokens
        # Queue time consumes the same budget, but a queued timeout never kills another call.
        async with asyncio.timeout(timeout or self.config.timeout):
            if self.load_task is not None:
                # A start-triggered prewarm may still be loading; this final's
                # whole-call timeout includes waiting for it. Shielded: cancelling
                # this final (timeout or utterance cancel) must not cancel the
                # shared load other finals may be waiting on. A failed load is
                # absorbed by _prewarm, so generate retries cold below.
                await asyncio.shield(self.load_task)
            await self._acquire(priority)
            try:
                if self.idle:
                    self.idle.cancel()
                    self.idle = None
                try:
                    await self._ensure_ready()
                    self.process.stdin.write(json.dumps(request).encode() + b"\n")
                    await self.process.stdin.drain()
                    if priority == "reorganize":
                        reply = await self._read_preemptible()
                    else:
                        reply = await self._read()
                    if reply.get("ok") is not True:
                        raise ValueError("Helper failed")
                    self._measure()
                    return reply["text"], reply.get("finish_reason")
                except BaseException:
                    # Cancellation must discard late replies before the next utterance.
                    await self._stop()
                    raise
                finally:
                    self._arm_idle()
            finally:
                self.lock.release()

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
                if self.loaded and self.launched_idle:
                    # This helper would still exit on its own idle limit; relaunch it without one.
                    # The caller prewarms afterwards.
                    await self._stop()
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
