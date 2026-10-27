"""Lease ordering and cancellation must never strand the speech engine."""

import asyncio

import pytest

from chirp_server.config import Settings
from chirp_server.engine.base import EngineLease


async def test_fifo_within_priority_and_live_first():
    lease = EngineLease()
    await lease.acquire(retranscribe=True)
    order = []

    async def use(label, retranscribe):
        await lease.acquire(retranscribe=retranscribe)
        try:
            order.append(label)
        finally:
            lease.release()

    tasks = []
    for label, low in (("replay1", True), ("live1", False), ("replay2", True), ("live2", False)):
        tasks.append(asyncio.create_task(use(label, low)))
        await asyncio.sleep(0)
    lease.release()
    await asyncio.wait_for(asyncio.gather(*tasks), 1)
    assert order == ["live1", "live2", "replay1", "replay2"]
    assert not lease.locked()


@pytest.mark.parametrize("retranscribe", [False, True])
@pytest.mark.parametrize("granted", [False, True])
async def test_cancelled_waiter_does_not_leak_lease(retranscribe, granted):
    lease = EngineLease()
    await lease.acquire()
    cancelled = asyncio.create_task(lease.acquire(retranscribe=retranscribe))
    await asyncio.sleep(0)
    next_waiter = asyncio.create_task(lease.acquire(retranscribe=True))
    await asyncio.sleep(0)
    if granted:
        lease.release()
    cancelled.cancel()
    with pytest.raises(asyncio.CancelledError):
        await cancelled
    if not granted:
        lease.release()
    await asyncio.wait_for(next_waiter, 1)
    lease.release()
    assert not lease.locked()
    assert not lease._live and not lease._retranscribe


def test_retranscribe_queue_timeout_default_and_config(tmp_path):
    assert Settings().retranscribe_queue_timeout == 60
    path = tmp_path / "server.toml"
    path.write_text("retranscribe_queue_timeout = 42.5\n")
    assert Settings.read(path).retranscribe_queue_timeout == 42.5


@pytest.mark.parametrize("value", [0, -1, True, "60", None, float("inf"), float("nan")])
def test_invalid_retranscribe_queue_timeout(value):
    with pytest.raises(ValueError, match="retranscribe_queue_timeout"):
        Settings(retranscribe_queue_timeout=value)
