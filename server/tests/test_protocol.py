import asyncio
import json

import pytest
from conftest import HEADERS, PCM, START, TOKEN
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from chirp_server.app import authorized, create_app
from chirp_server.audio import MAX_FRAME, MAX_PCM
from chirp_server.engine import FakeEngine
from chirp_server.profiles import BUILTINS


def final(ws):
    while True:
        message = ws.receive_json()
        if message["type"] in {"final", "error"}:
            return message


def test_health_redaction(client):
    for headers in ({}, {"Authorization": "Bearer wrong"}, {"Authorization": "Basic bad"}):
        assert client.get("/v1/health", headers=headers).json() == {"ok": True}
    health = client.get("/v1/health", headers=HEADERS).json()
    assert health == {
        "ok": True,
        "engine": "fake",
        "ready": True,
        "debug_retention": False,
        "correction": "off",
        "correction_mode": "off",
        "correction_leaves_machine": False,
        "correction_host": None,
        "correction_profiles": [profile.metadata() for profile in BUILTINS.values()],
        "correction_keep_loaded": False,
        "correction_loaded": False,
    }


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}])
def test_post_auth_before_body(client, headers):
    response = client.post("/v1/transcribe", headers=headers, content=b"not audio")
    assert response.status_code == 401
    assert response.json()["code"] == "auth"


def test_post(client, wav, engine):
    response = client.post("/v1/transcribe", headers=HEADERS, content=wav)
    assert response.status_code == 200
    assert response.json()["raw"] == engine.text
    assert response.json()["timings_ms"]["audio"] == 500
    assert len(set(engine.threads)) == 1


@pytest.mark.parametrize(
    "headers,first",
    [
        ({"Authorization": "Bearer wrong"}, None),
        ({}, {"type": "auth", "token": "wrong"}),
        ({}, START),
        ({}, None),
        ({}, b"audio-before-auth"),
        ({}, {"type": "auth", "token": 123}),
    ],
)
def test_ws_auth(client, headers, first):
    with client.websocket_connect("/v1/stream", headers=headers) as ws:
        if isinstance(first, bytes):
            ws.send_bytes(first)
        elif first:
            ws.send_json(first)
        assert ws.receive_json()["code"] == "auth"
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == 4401


@pytest.mark.parametrize("header", [True, False])
@pytest.mark.parametrize("client_name", ["mac", "android", "ios"])
def test_stream_partials_final_reuse(client, engine, header, client_name):
    with client.websocket_connect("/v1/stream", headers=HEADERS if header else {}) as ws:
        if not header:
            ws.send_json({"type": "auth", "token": TOKEN})
        for _ in range(2):
            ws.send_json({**START, "client": client_name})
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            partial = ws.receive_json()
            assert partial == {"type": "partial", "seq": 1, "text": engine.text, "stable": ""}
            ws.send_json({"type": "stop"})
            result = final(ws)
            assert result["raw"] == engine.text
            assert result["corrected"] is False
            assert result["correction_error"] is None
            assert result["timings_ms"]["first_partial"] is not None
    assert len(set(engine.threads)) == 1


def test_cancel_discard_and_reuse(client):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START)
        ws.receive_json()
        ws.send_bytes(PCM[:1600])
        ws.send_json({"type": "cancel"})
        ws.send_json(START)
        while ws.receive_json()["type"] == "partial":
            pass
        ws.send_bytes(PCM)
        ws.send_json({"type": "stop"})
        assert final(ws)["type"] == "final"


@pytest.mark.parametrize("frame", [b"x", b"x" * MAX_FRAME])
def test_frame_limits(client, frame):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START)
        ws.receive_json()
        ws.send_bytes(frame)
        assert final(ws)["code"] == "bad_audio"


def test_total_limit(client):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START)
        ws.receive_json()
        for _ in range(MAX_PCM // 64000 + 1):
            ws.send_bytes(b"\0" * 64000)
        assert final(ws)["code"] == "too_long"


@pytest.mark.parametrize("value", ["[]", "{", json.dumps({"type": "stop"})])
def test_bad_controls(client, value):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_text(value)
        assert final(ws)["code"] == "bad_audio"


def test_audio_before_start(client):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_bytes(PCM)
        assert ws.receive_json()["code"] == "bad_audio"


def test_idle_close(client):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()


def test_busy_and_disconnect_release(client):
    with client.websocket_connect("/v1/stream", headers=HEADERS) as first:
        first.send_json(START)
        first.receive_json()
        with client.websocket_connect("/v1/stream", headers=HEADERS) as second:
            second.send_json(START)
            assert second.receive_json()["code"] == "busy"
    with client.websocket_connect("/v1/stream", headers=HEADERS) as third:
        third.send_json(START)
        assert third.receive_json()["type"] == "ready"


def test_engine_failure_sanitized(settings):
    class Failed(FakeEngine):
        def open_stream(self):
            raise ValueError("sensitive internal text")

    with TestClient(create_app(settings, Failed(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            result = ws.receive_json()
            assert result["code"] == "engine"
            assert "sensitive" not in str(result)


def test_unicode_auth():
    assert not authorized(TOKEN, "😀")
    assert not authorized(TOKEN, None)


async def test_worker_single_thread_and_queue():
    from chirp_server.engine import EngineWorker

    engine = FakeEngine()
    worker = EngineWorker(engine)
    await worker.start()
    try:
        await asyncio.gather(*(worker.call(engine.transcribe, None) for _ in range(10)))
        assert len(set(engine.threads)) == 1
    finally:
        await worker.close()


def test_auth_deadline_independent_of_idle(settings):
    settings.idle_seconds = 60
    settings.auth_seconds = 0.02
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream") as ws:
            assert ws.receive_json()["code"] == "auth"


def test_bounded_pending_auth(settings):
    settings.auth_seconds = 5
    settings.max_pending_auth = 1
    with TestClient(create_app(settings, FakeEngine(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream"):
            with client.websocket_connect("/v1/stream") as excess:
                assert excess.receive_json()["code"] == "auth"
            # Authenticated clients do not wait behind unauthenticated sockets.
            assert client.get("/v1/health", headers=HEADERS).json()["ready"]


def test_slow_engine_coalesces_frames(settings):
    import threading

    from chirp_server.engine.fake import FakeStream

    entered, release = threading.Event(), threading.Event()
    coalesced = threading.Event()
    sizes = []

    class SlowStream(FakeStream):
        def feed(self, pcm):
            sizes.append(len(pcm))
            if len(sizes) == 1:
                entered.set()
                assert release.wait(timeout=5)
            else:
                coalesced.set()
            return super().feed(pcm)

    class SlowEngine(FakeEngine):
        def open_stream(self):
            return SlowStream(self)

    settings.idle_seconds = 10
    with TestClient(create_app(settings, SlowEngine(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            ws.receive_json()
            ws.send_bytes(PCM[:6400])
            assert entered.wait(timeout=5)
            # 50 x 20 ms frames arrive while inference is blocked.
            for _ in range(50):
                ws.send_bytes(PCM[:640])
            # HTTP health traverses the same event loop and confirms it remains responsive.
            assert client.get("/v1/health", headers=HEADERS).json()["ready"]
            release.set()
            assert coalesced.wait(timeout=5)
            ws.send_json({"type": "stop"})
            assert final(ws)["type"] == "final"
    assert sum(sizes) == 3200 + 50 * 320
    assert len(sizes) < 10
    assert max(sizes) > 3200


def test_root_path_proxy(settings):
    with TestClient(create_app(settings, FakeEngine(), TOKEN), root_path="/chirp") as client:
        assert client.get("/v1/health", headers=HEADERS).json()["ready"]


def test_prefix_accepted_stripped_or_not(settings):
    from chirp_server.app import accept_prefix

    app = accept_prefix(create_app(settings, FakeEngine(), TOKEN), "/chirp")
    with TestClient(app) as client:
        for path in ("/v1/health", "/chirp/v1/health"):
            assert client.get(path, headers=HEADERS).json()["ready"]
        assert client.get("/chirp/v1/health").json() == {"ok": True}
        assert client.get("/chirpx/v1/health").status_code == 404
        for path in ("/v1/stream", "/chirp/v1/stream"):
            with client.websocket_connect(path, headers=HEADERS) as ws:
                ws.send_json(START)
                assert ws.receive_json()["type"] == "ready"


def test_transcribe_limits(client):
    from chirp_server.audio import wav_bytes

    response = client.post(
        "/v1/transcribe", headers=HEADERS, content=wav_bytes(b"\0" * (MAX_PCM + 2))
    )
    assert response.status_code == 413
    assert response.json()["code"] == "too_long"


def test_missing_model_fails_with_explicit_fetch_hint(tmp_path):
    from chirp_server.engine.models import discover

    with pytest.raises(ValueError, match="chirp-server model fetch"):
        discover(tmp_path / "missing")


def test_stop_discards_pending_partial_inference(settings):
    import threading

    from chirp_server.engine.fake import FakeStream

    entered, release = threading.Event(), threading.Event()
    feeds, buffered = [], []

    class BlockedStream(FakeStream):
        def feed(self, pcm):
            feeds.append(len(pcm))
            entered.set()
            assert release.wait(5)
            return super().feed(pcm)

        def buffer(self, pcm):
            buffered.append(len(pcm))
            return super().buffer(pcm)

    class BlockedEngine(FakeEngine):
        def open_stream(self):
            return BlockedStream(self)

    settings.idle_seconds = 10
    with TestClient(create_app(settings, BlockedEngine(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            ws.receive_json()
            ws.send_bytes(PCM[:6400])
            assert entered.wait(5)
            ws.send_bytes(PCM)
            ws.send_json({"type": "stop"})
            # Barrier: the event loop has received stop while engine inference remains blocked.
            assert client.get("/v1/health", headers=HEADERS).json()["ready"]
            release.set()
            assert final(ws)["type"] == "final"
    assert feeds == [3200]
    assert buffered == [8000]


def test_stable_prefix_update_emits_during_pause(settings):
    from chirp_server.engine.base import Partial
    from chirp_server.engine.fake import FakeStream

    class StableStream(FakeStream):
        count = 0

        def feed(self, pcm):
            self.count += 1
            return Partial(self.engine.text, self.engine.text if self.count > 1 else "")

    class StableEngine(FakeEngine):
        def open_stream(self):
            return StableStream(self)

    with TestClient(create_app(settings, StableEngine(), TOKEN)) as client:
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            ws.receive_json()
            ws.send_bytes(PCM)
            assert ws.receive_json()["stable"] == ""
            ws.send_bytes(b"\0" * 6400)
            frozen = ws.receive_json()
            assert frozen["stable"] == frozen["text"]
            ws.send_json({"type": "stop"})
            assert final(ws)["raw"].startswith(frozen["stable"])


def test_stop_before_any_audio_returns_empty_final_and_socket_stays_usable(client):
    # A quick tap can release the hotkey before the first PCM frame is sent.
    with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START)
        assert ws.receive_json()["type"] == "ready"
        ws.send_json({"type": "stop"})
        final = ws.receive_json()
        assert final["type"] == "final"
        assert final["text"] == "" and final["raw"] == ""
        ws.send_json(START)
        assert ws.receive_json()["type"] == "ready"
