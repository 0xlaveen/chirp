"""Per-device activity: owner-only read, attribution, kinds and outcomes, bounds, refusals, the
saved file and the privacy rules. Every transcript, prompt and token here is synthetic."""

import json
import logging
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from conftest import HEADERS, PCM, START, TOKEN, has_mode
from starlette.testclient import TestClient
from test_notes import TRANSCRIPT, service
from test_protocol import final

from chirp_server import cli, devices
from chirp_server.activity import Activity
from chirp_server.app import create_app
from chirp_server.config import ActivityConfig, CorrectionConfig, Settings
from chirp_server.correction import CorrectionResult
from chirp_server.devices import DeviceStore
from chirp_server.engine import FakeEngine

URL = "/v1/devices/activity"
LOOPBACK = ("127.0.0.1", 50000)


def owner_headers(settings):
    return {"Authorization": f"Bearer {(settings.config_dir / 'owner-token').read_text().strip()}"}


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def open_app(settings, engine=None, corrector=None, client=LOOPBACK):
    return TestClient(
        create_app(settings, engine or FakeEngine(), TOKEN, corrector=corrector), client=client
    )


@pytest.fixture
def app(settings):
    with open_app(settings) as client:
        yield client


def snapshot(client, settings):
    response = client.get(URL, headers=owner_headers(settings))
    assert response.status_code == 200
    return response.json()


def settled(client, settings, count, seconds=5):
    """The snapshot once `count` events exist (a socket's last event lands after it closes)."""
    deadline = time.monotonic() + seconds
    while True:
        data = snapshot(client, settings)
        if len(data["events"]) >= count or time.monotonic() > deadline:
            return data
        time.sleep(0.02)


def dictate(http, headers=HEADERS, **start):
    with http.websocket_connect("/v1/stream", headers=headers) as ws:
        ws.send_json(START | start)
        assert ws.receive_json()["type"] == "ready"
        ws.send_bytes(PCM)
        ws.send_json({"type": "stop"})
        assert final(ws)["type"] == "final"


# --- who may read -----------------------------------------------------------------------


def test_auth_matrix(app, settings):
    device, token = DeviceStore(settings.config_dir).mint("Pixel 8")
    owner = owner_headers(settings)
    assert app.get(URL).status_code == 401
    assert app.get(URL).json()["code"] == "auth"
    assert app.get(URL, headers=bearer("wrong")).status_code == 401
    for headers in (HEADERS, bearer(token)):
        response = app.get(URL, headers=headers)
        assert response.status_code == 403
        assert response.json()["code"] == "forbidden"
    for proxy in ({"X-Forwarded-For": "100.64.0.1"}, {"Tailscale-User-Login": "someone@example"}):
        assert app.get(URL, headers=owner | proxy).status_code == 403
    assert app.get(URL, headers=owner).status_code == 200
    # A client that is not the loopback address is not "this machine" either.
    with open_app(settings, client=("100.64.0.9", 1)) as remote:
        assert remote.get(URL, headers=owner).status_code == 403
    with open_app(settings, client=("::1", 1)) as v6:
        assert v6.get(URL, headers=owner).status_code == 200


def test_owner_token_opens_nothing_else(app, settings, wav):
    owner = owner_headers(settings)
    assert app.post("/v1/transcribe", headers=owner, content=wav).status_code == 401
    assert (
        app.post("/v1/notes/structure", headers=owner, json={"transcript": "x"}).status_code == 401
    )
    assert app.post("/v1/notes/reorganize", headers=owner, json={"notes": "x"}).status_code == 401
    assert app.get("/v1/correction/settings", headers=owner).status_code == 401
    assert app.get("/v1/health", headers=owner).json() == {"ok": True}
    with app.websocket_connect("/v1/stream", headers=owner) as ws:
        assert ws.receive_json()["code"] == "auth"
    with app.websocket_connect("/v1/stream") as ws:
        ws.send_json({"type": "auth", "token": owner["Authorization"].split()[1]})
        assert ws.receive_json()["code"] == "auth"


def test_owner_token_file(settings, capsys, monkeypatch):
    with open_app(settings):
        pass
    path = settings.config_dir / "owner-token"
    assert has_mode(path, 0o600) and path.is_file() and not path.is_symlink()
    first = path.read_text()
    assert len(first.strip()) >= 43 and first.strip() != TOKEN
    with open_app(settings):
        pass
    assert path.read_text() == first  # created once, survives restarts
    monkeypatch.setattr("sys.argv", ["chirp-server", "pair", "--url", "http://127.0.0.1:7821"])
    monkeypatch.setattr(cli.Settings, "read", classmethod(lambda cls, path=None: settings))
    cli.main()
    printed = capsys.readouterr()
    shared = (settings.config_dir / "token").read_text().strip()
    assert first.strip() not in printed.out + printed.err
    assert shared in printed.out  # the pairing link holds the shared token, never the owner's


# --- attribution ------------------------------------------------------------------------


def test_attribution(app, settings):
    device, token = DeviceStore(settings.config_dir).mint("Pixel 8")
    dictate(app, bearer(token), client="android")
    dictate(app, HEADERS, client="ios")
    dictate(app, HEADERS | {"X-Forwarded-For": "100.64.0.2"}, client="desktop")
    events = settled(app, settings, 3)["events"]
    assert [event["client"] for event in events] == ["desktop", "ios", "android"]
    assert events[0]["source"] == {"kind": "shared"}
    assert events[1]["source"] == {"kind": "local"}
    assert events[2]["source"] == {
        "kind": "device",
        "id": device["id"],
        "name": "Pixel 8",
        "revoked": False,
    }


def test_names_and_revocation_are_joined_at_read_time(app, settings):
    store = DeviceStore(settings.config_dir)
    device, token = store.mint("Old Pixel")
    dictate(app, bearer(token))
    store.revoke(device["id"])
    source = settled(app, settings, 1)["events"][0]["source"]
    assert source["name"] == "Old Pixel" and source["revoked"] is True  # events stay


# --- kinds and outcomes -----------------------------------------------------------------


class Stub:
    """A corrector that always answers with `error`; the guard's verdict, never text."""

    managed = None

    def __init__(self, config, error=None):
        self.config, self.error = config, error

    async def process(self, raw, *args, **kwargs):
        return CorrectionResult(raw, corrected=self.error is None, error=self.error)


def test_dictation_notes_segment_and_cancel(settings):
    with open_app(settings) as client:
        dictate(client)
        dictate(client, correction_profile="live_notes")
        with client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
            ws.send_json(START)
            assert ws.receive_json()["type"] == "ready"
            ws.send_bytes(PCM)
            ws.send_json({"type": "cancel"})
        data = settled(client, settings, 3)
    cancelled, segment, dictation = data["events"]
    assert (dictation["kind"], dictation["outcome"]) == ("dictation", "ok")
    assert (segment["kind"], segment["outcome"]) == ("notes_segment", "ok")
    assert segment["profile"] == "live_notes"
    assert (cancelled["kind"], cancelled["outcome"]) == ("dictation", "cancelled")
    assert dictation["audio_ms"] == len(PCM) // 32 and dictation["duration_ms"] >= 0


def test_transcribe(app, settings, wav):
    assert app.post("/v1/transcribe", headers=HEADERS, content=wav).status_code == 200
    assert app.post("/v1/transcribe", headers=HEADERS, content=b"junk").status_code == 400
    bad, ok = snapshot(app, settings)["events"]
    assert (ok["kind"], ok["outcome"], ok["audio_ms"], ok["client"]) == (
        "transcribe",
        "ok",
        len(PCM) // 32,
        None,
    )
    assert bad["outcome"] == "bad_audio"


def test_guard_rejection_and_timeout(settings):
    settings.correction = CorrectionConfig(mode="endpoint")
    for error in ("rejected", "timeout"):
        with open_app(settings, corrector=Stub(settings.correction, error)) as client:
            dictate(client, correction=True, correction_profile="default")
            (event,) = settled(client, settings, 1)["events"]
        assert event["outcome"] == error and event["corrected"] is False
        (settings.state_path.with_name("device-activity.json")).unlink()


def test_notes_busy(settings):
    corrector = service("--slow-structure", "1.0", timeout=8)
    with open_app(settings, corrector=corrector) as client, ThreadPoolExecutor(1) as pool:
        body = {"transcript": TRANSCRIPT}
        first = pool.submit(lambda: client.post("/v1/notes/structure", headers=HEADERS, json=body))
        time.sleep(0.4)
        assert client.post("/v1/notes/structure", headers=HEADERS, json=body).status_code == 503
        assert first.result(timeout=10).status_code == 200
        ok, busy = snapshot(client, settings)["events"]
    assert (busy["kind"], busy["outcome"]) == ("notes_structure", "busy")
    assert ok["outcome"] == "ok" and ok["audio_ms"] is None


def test_notes_kinds(settings):
    corrector = service(
        "--reply-reorganize", "## Plan\n- Ship **Friday**", "--reply-edit", "## Plan", timeout=8
    )
    settings.correction = corrector.config
    with open_app(settings, corrector=corrector) as client:
        client.post("/v1/notes/reorganize", headers=HEADERS, json={"notes": "## Plan\n- Ship"})
        client.post("/v1/notes/structure", headers=HEADERS, json={"nope": 1})
        client.post("/v1/notes/edit", headers=HEADERS, json={"nope": 1})
        events = snapshot(client, settings)["events"]
    assert [(e["kind"], e["outcome"]) for e in events] == [
        ("notes_edit", "bad_notes"),
        ("notes_structure", "bad_notes"),
        ("notes_reorganize", events[2]["outcome"]),
    ]


def test_speaker_model_is_recorded(app, settings):
    app.post("/v1/speakers/model", headers=HEADERS, json={"nope": 1})
    (event,) = snapshot(app, settings)["events"]
    assert (event["kind"], event["outcome"]) == ("speaker_model", "bad_speakers")


def test_disconnect_mid_utterance(app, settings):
    with app.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START)
        assert ws.receive_json()["type"] == "ready"
        ws.send_bytes(PCM)
    (event,) = settled(app, settings, 1)["events"]
    assert (event["kind"], event["outcome"]) == ("dictation", "disconnected")


def test_active_between_start_and_stop(app, settings):
    with app.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START | {"client": "android"})
        assert ws.receive_json()["type"] == "ready"
        active = snapshot(app, settings)["active"]
        assert len(active) == 1
        assert active[0]["kind"] == "dictation" and active[0]["client"] == "android"
        assert active[0]["source"] == {"kind": "local"}
        ws.send_bytes(PCM)
        ws.send_json({"type": "stop"})
        assert final(ws)["type"] == "final"
    assert snapshot(app, settings)["active"] == []


def test_an_idle_socket_is_not_in_use(app, settings):
    with app.websocket_connect("/v1/stream", headers=HEADERS):
        data = snapshot(app, settings)
    assert data["active"] == [] and data["events"] == []


def test_polled_routes_are_not_recorded(app, settings):
    app.get("/v1/health", headers=HEADERS)
    app.get("/v1/correction/profiles", headers=HEADERS)
    app.get("/v1/correction/settings", headers=HEADERS)
    data = snapshot(app, settings)
    assert data["events"] == [] and data["refused"] == []


# --- bounds (fake clock) ----------------------------------------------------------------


class Clock:
    def __init__(self):
        self.mono = 0.0
        self.wall = datetime(2026, 10, 26, 9, 0, tzinfo=UTC)

    def advance(self, seconds):
        self.mono += seconds
        self.wall += timedelta(seconds=seconds)


def test_event_ring_and_age_limits():
    clock = Clock()
    log = Activity(max_events=500, max_days=7, clock=lambda: clock.mono, now=lambda: clock.wall)
    for _ in range(501):
        log.end(log.begin(("local", None), "mac", "dictation"), "ok", 1000)
        clock.advance(1)
    assert len(log.snapshot({})["events"]) == 500
    clock.advance(7 * 86400 - 500)  # the oldest kept event is now exactly 7 days old
    assert len(log.snapshot({})["events"]) == 500
    clock.advance(1)
    assert len(log.snapshot({})["events"]) == 499  # one second past: pruned
    assert Activity().snapshot({})["events"] == []  # a new one starts empty


def test_durations_use_the_monotonic_clock():
    clock = Clock()
    log = Activity(clock=lambda: clock.mono, now=lambda: clock.wall)
    token = log.begin(("shared", None), None, "transcribe")
    clock.advance(2.31)
    log.end(token, "ok", 41800)
    (event,) = log.snapshot({})["events"]
    assert event["duration_ms"] == 2310 and event["at"] == "2026-10-26T09:00:02Z"


# --- refusals ---------------------------------------------------------------------------


def test_refusals(app, settings):
    store = DeviceStore(settings.config_dir)
    device, token = store.mint("Old Pixel")
    store.revoke(device["id"])
    app.post("/v1/notes/structure", headers=bearer("wrong"), json={})
    app.post("/v1/notes/structure", headers=bearer("again"), json={})
    app.post("/v1/transcribe", json={})
    app.get("/v1/correction/settings", headers=bearer(token))
    app.get("/v1/correction/settings", headers=bearer(token))
    app.get("/v1/health")  # unauthenticated liveness: normal
    app.get("/v1/health", headers=bearer("wrong"))  # also liveness
    with app.websocket_connect("/v1/stream", headers=bearer("wrong")) as ws:
        assert ws.receive_json()["code"] == "auth"
    app.get(URL, headers=bearer("wrong"))
    counts = {
        (item["reason"], item.get("device", {}).get("id")): item["count"]
        for item in snapshot(app, settings)["refused"]
    }
    assert counts == {
        ("unknown_token", None): 4,
        ("no_token", None): 1,
        ("revoked", device["id"]): 2,
    }
    revoked = next(i for i in snapshot(app, settings)["refused"] if i["reason"] == "revoked")
    assert revoked["device"] == {"id": device["id"], "name": "Old Pixel"}
    assert revoked["last"].endswith("Z")


def test_websocket_auth_frame_failures_and_cap(settings):
    settings.max_pending_auth = 0
    with open_app(settings) as client:
        with client.websocket_connect("/v1/stream") as ws:
            assert ws.receive_json()["code"] == "auth"
        (item,) = snapshot(client, settings)["refused"]
    assert (item["reason"], item["count"]) == ("no_token", 1)


# --- the saved file ---------------------------------------------------------------------


def test_activity_survives_a_restart(settings):
    with open_app(settings) as client:
        dictate(client, client="android", correction_profile="default")
        client.get("/v1/correction/settings", headers=bearer("wrong"))
        before = snapshot(client, settings)
    path = settings.activity_path
    assert has_mode(path, 0o600)
    with open_app(settings) as client:
        after = snapshot(client, settings)
    assert after["events"] == before["events"] and after["refused"] == before["refused"]
    assert after["events"][0]["profile"] == "default"
    assert not [p for p in path.parent.iterdir() if p.name.endswith(".tmp")]


def test_saving_happens_in_the_background(settings, monkeypatch):
    monkeypatch.setattr("chirp_server.app.FLUSH_SECONDS", 0.05)
    with open_app(settings) as client:
        dictate(client)
        deadline = time.monotonic() + 5
        while not settings.activity_path.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert settings.activity_path.exists()  # before shutdown


def test_turning_it_off_clears_everything(settings):
    with open_app(settings) as client:
        dictate(client)
        client.get("/v1/correction/settings", headers=bearer("wrong"))
        settled(client, settings, 1)
        assert (
            client.put(URL + "/settings", headers=HEADERS, json={"keep": False}).status_code == 403
        )
        assert client.put(URL + "/settings", json={"keep": False}).status_code == 401
        bad = client.put(URL + "/settings", headers=owner_headers(settings), json={"keep": "no"})
        assert bad.status_code == 400 and bad.json()["code"] == "bad_activity"
        reply = client.put(URL + "/settings", headers=owner_headers(settings), json={"keep": False})
        assert reply.json() == {"keep": False}
        saved = json.loads(settings.activity_path.read_text())
        assert saved == {"version": 1, "keep": False}
        dictate(client)
        client.get("/v1/correction/settings", headers=bearer("wrong"))
        data = snapshot(client, settings)
        assert data["keep"] is False
        assert data["events"] == data["refused"] == data["active"] == []
    # The choice survives a restart, over server.toml's default of on.
    with open_app(settings) as client:
        dictate(client)
        data = snapshot(client, settings)
        assert data["keep"] is False and data["events"] == []
        client.put(URL + "/settings", headers=owner_headers(settings), json={"keep": True})
        dictate(client)
        assert len(snapshot(client, settings)["events"]) == 1


def test_server_toml_can_turn_it_off(settings, tmp_path):
    with open_app(settings) as client:
        dictate(client)
        settled(client, settings, 1)
    assert settings.activity_path.exists()
    settings.activity = ActivityConfig(keep=False)
    with open_app(settings) as client:
        dictate(client)
        assert snapshot(client, settings)["keep"] is False
    assert not settings.activity_path.exists()  # what an earlier run saved is deleted


def test_config_options(tmp_path):
    path = tmp_path / "server.toml"
    assert Settings.read(path).activity == ActivityConfig(True, 5000, 30)
    path.write_text("[activity]\nkeep = false\nmax_events = 100\nmax_days = 2\n")
    assert Settings.read(path).activity == ActivityConfig(False, 100, 2)
    for bad in ('keep = "yes"', "max_events = 0", "max_days = 400", "max_days = 1.5"):
        path.write_text(f"[activity]\n{bad}\n")
        with pytest.raises(ValueError):
            Settings.read(path)


def test_a_damaged_file_starts_empty(settings):
    settings.activity_path.parent.mkdir(parents=True)
    for text in ("{not json", "[]", json.dumps({"events": [["x"], 7, None], "refused": "no"})):
        settings.activity_path.write_text(text)
        with open_app(settings) as client:
            data = snapshot(client, settings)
        assert data["events"] == [] and data["refused"] == []


def test_a_foreign_event_in_the_file_is_skipped(settings):
    good = ["2999-01-01T00:00:00Z", "local", None, "mac", "dictation", 5, 100, "ok", None, None]
    odd = ["2999-01-01T00:00:00Z", "local", None, "mac", "dictation", 5, 100, "ok", "has space", 1]
    settings.activity_path.parent.mkdir(parents=True)
    settings.activity_path.write_text(json.dumps({"version": 1, "events": [odd, good]}))
    with open_app(settings) as client:
        assert len(snapshot(client, settings)["events"]) == 1


def test_retention_follows_the_config(settings):
    settings.activity = ActivityConfig(max_events=3)
    with open_app(settings) as client:
        for _ in range(5):
            dictate(client)
        data = settled(client, settings, 3)
    assert data["retention"] == {"max_events": 3, "max_age_days": 30}
    assert len(data["events"]) == 3


# --- privacy ----------------------------------------------------------------------------


def test_nothing_private_is_recorded(settings, caplog, wav):
    secrets_ = (
        "zyxwvu transcript",
        "secret correction prompt",
        "learned-sentinel",
        "outline-sentinel",
    )
    settings.correction = CorrectionConfig(mode="endpoint")
    device, token = DeviceStore(settings.config_dir).mint("Pixel 8")
    caplog.set_level(logging.DEBUG)
    corrector = Stub(settings.correction)
    with open_app(settings, FakeEngine(secrets_[0]), corrector) as client:
        dictate(
            client,
            bearer(token),
            correction=True,
            correction_prompt=secrets_[1],
            learned={"v": 1, "terms": [{"term": secrets_[2], "heard": []}], "style": []},
        )
        client.post("/v1/transcribe", headers=bearer(token), content=wav)
        client.post(
            "/v1/notes/structure",
            headers=bearer(token),
            json={"transcript": secrets_[0], "outline": [secrets_[3]]},
        )
        client.get("/v1/correction/settings", headers=bearer("secret-bad-token"))
        data = settled(client, settings, 2)
    text = json.dumps(data) + settings.activity_path.read_text()
    for value in (*secrets_, token, TOKEN, "secret-bad-token", devices.digest(token).hex()):
        assert value not in text
    assert (settings.config_dir / "owner-token").read_text().strip() not in text
    assert "testclient" not in text and "127.0.0.1" not in text
    # No activity line, device id or name reaches the log.
    assert device["id"] not in caplog.text and "Pixel 8" not in caplog.text


def test_session_files_are_only_the_activity_file(settings, tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    with open_app(settings) as client:
        dictate(client)
    assert not list(home.rglob("*"))
    written = {p.relative_to(tmp_path) for p in tmp_path.rglob("*") if p.is_file()}
    names = {p.name for p in written}
    assert "device-activity.json" in names
    assert not [n for n in names if n.endswith(".tmp")]
    assert not [p for p in written if "debug" in p.parts]
