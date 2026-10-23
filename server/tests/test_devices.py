import hashlib
import json
import logging
import os
import stat
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from conftest import HEADERS, START, TOKEN
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from chirp_server import cli, devices
from chirp_server.app import create_app
from chirp_server.devices import Credentials, DeviceStore


def mode(path):
    return stat.S_IMODE(path.lstat().st_mode)


def rejected(ws):
    assert ws.receive_json()["code"] == "auth"
    with pytest.raises(WebSocketDisconnect) as exc:
        ws.receive_json()
    assert exc.value.code == 4401


@pytest.fixture
def store(settings):
    return DeviceStore(settings.config_dir)


@pytest.fixture
def app_client(settings, engine):
    with TestClient(create_app(settings, engine, TOKEN)) as client:
        yield client


def test_mint_is_hashed_at_rest_with_private_modes(store):
    device, token = store.mint("  Pixel 9  ")
    assert device == {
        "id": device["id"],
        "name": "Pixel 9",
        "created": device["created"],
        "last_seen": None,
        "revoked": None,
    }
    assert len(device["id"]) == 8 and len(token) >= 43
    text = store.path.read_text()
    assert token not in text
    assert hashlib.sha256(token.encode()).hexdigest() in text
    assert mode(store.path) == 0o600 and mode(store.directory / "devices.lock") == 0o600
    assert mode(store.directory) == 0o700
    assert not [p for p in store.directory.iterdir() if p.name.endswith(".tmp")]
    other, second = store.mint("iPhone")
    assert second != token and other["id"] != device["id"]
    assert [entry["name"] for entry in store.entries()] == ["Pixel 9", "iPhone"]
    assert all("sha256" not in entry for entry in store.entries())


@pytest.mark.parametrize("name", ["", "   ", "x" * 65, "bad\nname", "tab\tname", None, 7])
def test_invalid_names(store, name):
    with pytest.raises(ValueError):
        store.mint(name)
    assert not store.path.exists()


def test_duplicate_active_name_rejected_until_revoked(store):
    first, _ = store.mint("Pixel")
    with pytest.raises(ValueError):
        store.mint("pixel")
    assert store.revoke("PIXEL")["id"] == first["id"]
    second, _ = store.mint("Pixel")
    assert [entry["id"] for entry in store.entries()] == [second["id"]]
    assert [entry["id"] for entry in store.entries(include_revoked=True)] == [
        first["id"],
        second["id"],
    ]


def test_revoke_by_id_and_unknown(store):
    device, _ = store.mint("Tablet")
    with pytest.raises(LookupError):
        store.revoke("nope")
    revoked = store.revoke(device["id"])
    assert revoked["revoked"] is not None
    with pytest.raises(LookupError):
        store.revoke(device["id"])  # already revoked


def test_insecure_or_invalid_file(store):
    store.mint("Pixel")
    store.path.chmod(0o644)
    assert store.entries() and mode(store.path) == 0o600
    store.path.write_text("{not json")
    with pytest.raises(ValueError):
        store.entries()
    store.path.write_text(json.dumps({"devices": [{"id": "x"}]}))
    with pytest.raises(ValueError):
        store.entries()
    store.path.unlink()
    target = store.directory / "elsewhere.json"
    target.write_text(json.dumps({"devices": []}))
    store.path.symlink_to(target)
    with pytest.raises(ValueError):
        store.entries()
    with pytest.raises(ValueError):
        store.mint("Other")


def test_credentials_legacy_device_and_revoked(store):
    device, token = store.mint("Pixel")
    credentials = Credentials(TOKEN, store.directory)
    assert credentials.check(TOKEN)
    assert credentials.check(token)
    for value in ("", "wrong", token + "x", token[:-1], None, 123, "\ud800", "é" * 50):
        assert not credentials.check(value)
        assert not credentials.revoked(value)
    store.revoke(device["id"])
    # A revoke from the CLI applies on the next check without a restart.
    assert not credentials.check(token)
    assert credentials.revoked(token)
    assert credentials.check(TOKEN) and not credentials.revoked(TOKEN)


def test_last_seen_updates_are_throttled(store, monkeypatch):
    device, token = store.mint("Pixel")
    credentials = Credentials(TOKEN, store.directory)
    clock = [1000.0]
    monkeypatch.setattr(devices.time, "monotonic", lambda: clock[0])
    stamps = iter(["2026-10-23T10:00:00Z", "2026-10-23T10:00:30Z", "2026-10-23T10:01:05Z"])
    monkeypatch.setattr(devices, "now", lambda: next(stamps))
    assert credentials.check(token)
    assert store.entries()[0]["last_seen"] == "2026-10-23T10:00:00Z"
    clock[0] += 30
    assert credentials.check(token)
    assert store.entries()[0]["last_seen"] == "2026-10-23T10:00:00Z"  # throttled
    clock[0] += 35
    assert credentials.check(token)
    assert store.entries()[0]["last_seen"] == "2026-10-23T10:00:30Z"
    assert credentials.check(TOKEN)  # the shared token records nothing
    assert store.entries()[0]["created"] == device["created"]


def test_last_seen_never_waits_for_a_cli_writer(store):
    _, token = store.mint("Pixel")
    credentials = Credentials(TOKEN, store.directory)
    with store.locked():
        assert credentials.check(token)
    assert store.entries()[0]["last_seen"] is None
    assert credentials.check(token)  # retried once the lock is free
    assert store.entries()[0]["last_seen"] is not None


def test_last_seen_does_not_resurrect_a_revoked_device(store):
    device, token = store.mint("Pixel")
    credentials = Credentials(TOKEN, store.directory)
    store.revoke(device["id"])
    store.touch({device["id"]: "2026-10-23T10:00:00Z"})
    assert store.entries(include_revoked=True)[0]["last_seen"] is None
    assert not credentials.check(token)


def test_device_token_on_http_and_ws(app_client, store):
    _, token = store.mint("Pixel")
    headers = {"Authorization": f"Bearer {token}"}
    assert app_client.get("/v1/health", headers=headers).json()["engine"] == "fake"
    assert app_client.get("/v1/correction/profiles", headers=headers).status_code == 200
    for header in (True, False):
        with app_client.websocket_connect("/v1/stream", headers=headers if header else {}) as ws:
            if not header:
                ws.send_json({"type": "auth", "token": token})
            ws.send_json(START)
            assert ws.receive_json()["type"] == "ready"
    # The legacy shared token keeps working alongside device tokens.
    assert app_client.get("/v1/health", headers=HEADERS).json()["engine"] == "fake"
    with app_client.websocket_connect("/v1/stream", headers=HEADERS) as ws:
        ws.send_json(START)
        assert ws.receive_json()["type"] == "ready"
    assert store.entries()[0]["last_seen"] is not None


def test_revoked_token_rejected_on_ws_and_http(app_client, store, wav):
    device, token = store.mint("Lost phone")
    headers = {"Authorization": f"Bearer {token}"}
    assert app_client.get("/v1/health", headers=headers).json()["engine"] == "fake"
    store.revoke("Lost phone")
    response = app_client.get("/v1/health", headers=headers)
    assert response.status_code == 401 and response.json()["code"] == "auth"
    assert app_client.post("/v1/transcribe", headers=headers, content=wav).status_code == 401
    assert app_client.get("/v1/correction/profiles", headers=headers).status_code == 401
    with app_client.websocket_connect("/v1/stream", headers=headers) as ws:
        rejected(ws)
    with app_client.websocket_connect("/v1/stream") as ws:
        ws.send_json({"type": "auth", "token": token})
        rejected(ws)
    # Unknown credentials still see only the frozen minimal health.
    wrong = {"Authorization": "Bearer wrong"}
    assert app_client.get("/v1/health", headers=wrong).json() == {"ok": True}
    assert app_client.get("/v1/health", headers=HEADERS).json()["engine"] == "fake"


def test_unreadable_device_file_keeps_shared_token(app_client, store, caplog):
    _, token = store.mint("Pixel")
    store.path.write_text("{corrupt")
    headers = {"Authorization": f"Bearer {token}"}
    with caplog.at_level(logging.WARNING, logger="chirp"):
        assert app_client.get("/v1/health", headers=headers).json() == {"ok": True}
        assert app_client.get("/v1/health", headers=HEADERS).json()["engine"] == "fake"
    assert "only the shared token" in caplog.text and "corrupt" not in caplog.text


def test_no_token_or_digest_in_logs(app_client, store, caplog, capfd, wav):
    with caplog.at_level(logging.DEBUG):
        device, token = store.mint("Pixel")
        headers = {"Authorization": f"Bearer {token}"}
        app_client.get("/v1/health", headers=headers)
        app_client.post("/v1/transcribe", headers=headers, content=wav)
        with app_client.websocket_connect("/v1/stream") as ws:
            ws.send_json({"type": "auth", "token": token})
            ws.send_json(START)
            ws.receive_json()
        store.revoke(device["id"])
        app_client.get("/v1/health", headers=headers)
        with app_client.websocket_connect("/v1/stream", headers=headers) as ws:
            rejected(ws)
    out, err = capfd.readouterr()
    secret = hashlib.sha256(token.encode()).hexdigest()
    for text in (caplog.text, out, err):
        assert token not in text and secret not in text and TOKEN not in text


def run(monkeypatch, capsys, *argv):
    monkeypatch.setattr(sys, "argv", ["chirp-server", *argv])
    cli.main()
    return capsys.readouterr()


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    return tmp_path / ".config/chirp"


def token_of(uri):
    parts = urlsplit(uri)
    assert parts.scheme == "chirp" and parts.netloc == "pair"
    return parse_qs(parts.query)["token"][0]


def test_cli_pair_legacy_output_unchanged(home, monkeypatch, capsys):
    result = run(monkeypatch, capsys, "pair", "--url", "https://mac.example.ts.net/chirp")
    uri = result.out.splitlines()[0]
    assert uri.startswith("chirp://pair?url=https%3A%2F%2Fmac.example.ts.net%2Fchirp&token=")
    assert token_of(uri) == (home / "token").read_text().strip()
    assert result.err == "" and not (home / "devices.json").exists()


def test_cli_pair_name_list_revoke(home, monkeypatch, capsys):
    result = run(monkeypatch, capsys, "pair", "--name", "Pixel", "--url", "http://127.0.0.1:7821")
    uri = result.out.splitlines()[0]
    assert uri.startswith("chirp://pair?url=http%3A%2F%2F127.0.0.1%3A7821&token=")
    token = token_of(uri)
    store = DeviceStore(home)
    (device,) = store.entries()
    assert device["name"] == "Pixel" and device["id"] in result.err and token not in result.err
    assert token not in store.path.read_text()
    assert not (home / "token").exists()  # minting a device token never needs the shared one
    listing = run(monkeypatch, capsys, "devices", "list").out
    assert listing.splitlines()[0].split() == ["ID", "NAME", "CREATED", "LAST", "SEEN"]
    assert device["id"] in listing and "never" in listing and token not in listing
    data = json.loads(run(monkeypatch, capsys, "devices", "list", "--json").out)
    assert data == {"devices": [device]}
    assert "Revoked Pixel" in run(monkeypatch, capsys, "devices", "revoke", "Pixel").out
    assert "No paired devices" in run(monkeypatch, capsys, "devices", "list").out
    assert device["id"] in run(monkeypatch, capsys, "devices", "list", "--all").out
    with pytest.raises(SystemExit) as exc:
        run(monkeypatch, capsys, "devices", "revoke", "Pixel")
    assert "No paired device" in str(exc.value)
    with pytest.raises(SystemExit):
        run(monkeypatch, capsys, "devices", "revoke")
    run(monkeypatch, capsys, "pair", "--name", "Pixel")  # a revoked name is reusable
    assert [entry["name"] for entry in store.entries()] == ["Pixel"]


def test_cli_pair_rejects_bad_url_before_minting(home, monkeypatch, capsys):
    for url in ("ftp://mac/chirp", "https://user:pw@mac/chirp", "not a url"):
        with pytest.raises(SystemExit) as exc:
            run(monkeypatch, capsys, "pair", "--name", "Pixel", "--url", url)
        assert "Pair URL" in str(exc.value)
    assert not (home / "devices.json").exists() and not (home / "token").exists()
    run(monkeypatch, capsys, "pair", "--name", "Pixel")
    with pytest.raises(SystemExit) as exc:
        run(monkeypatch, capsys, "pair", "--name", "pixel")
    assert "already paired" in str(exc.value)
    assert len(DeviceStore(home).entries()) == 1
    assert os.stat(home / "devices.json").st_mode & 0o077 == 0
