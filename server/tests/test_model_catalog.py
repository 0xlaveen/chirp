"""Choices are pinned, explicit, offline at startup, and do not edit managed config."""

import json
import stat
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, replace

import httpx
import pytest

from chirp_server import model_catalog as catalog
from chirp_server import setup
from chirp_server.config import Settings


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    monkeypatch.setattr(catalog, "root", lambda: tmp_path / "config")


def test_builtin_choices_are_pinned_and_include_speech_and_correction():
    models = catalog.catalog()
    assert {m.kind for m in models.values()} == {"speech", "cleanup"}
    assert len(models) >= 6
    assert models["parakeet-v3"].revision != "main"
    assert all(len(m.revision) == 40 for m in models.values())
    with pytest.raises(ValueError):
        replace(models["parakeet-v3"], revision="main")
    with pytest.raises(ValueError):
        catalog.resolve("parakeet-v3", "cleanup")


def test_status_reads_cached_catalog_without_checking_for_updates(monkeypatch, capsys):
    monkeypatch.setattr(setup.Settings, "read", lambda _: Settings())
    monkeypatch.setattr(catalog, "ready", lambda _: False)
    monkeypatch.setattr(setup, "server_running", lambda _: False)
    monkeypatch.setattr(httpx, "Client", lambda **_: pytest.fail("unexpected model network"))
    assert setup.run("status", "speech", None, 7821) == 0
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    event = next(e for e in events if e["event"] == "catalog")
    assert event["active_models"]["cleanup"] == ""  # No accidental enable on a fresh install.
    assert len(event["options"]) >= 6
    assert not (catalog.root() / "model-selection.json").exists()


def test_selection_loads_before_writing_and_preserves_previous_choice(monkeypatch):
    monkeypatch.setattr(catalog, "verify", lambda _: None)
    chosen = catalog.choose("parakeet-v2", "speech")
    state = catalog.root() / "model-selection.json"
    previous = state.read_bytes()
    assert stat.S_IMODE(state.stat().st_mode) == 0o600
    assert catalog.pending_restart()
    assert catalog.selection()["speech"] == chosen

    def fail(_):
        raise ValueError("incompatible weights")

    monkeypatch.setattr(catalog, "verify", fail)
    with pytest.raises(ValueError):
        catalog.choose("parakeet-v3", "speech")
    assert state.read_bytes() == previous


def test_concurrent_speech_and_correction_choices_preserve_each_other(monkeypatch):
    monkeypatch.setattr(catalog, "verify", lambda _: None)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [
            pool.submit(catalog.choose, "parakeet-v3", "speech"),
            pool.submit(catalog.choose, "qwen3.5-2b-4bit", "cleanup"),
        ]
        for future in futures:
            future.result()
    assert set(catalog.selection()) == {"speech", "cleanup"}


def test_selection_survives_catalog_changes_and_missing_cache_without_editing_toml(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(catalog, "verify", lambda _: None)
    chosen = catalog.choose("parakeet-v3", "speech")
    cleanup = catalog.choose("qwen3.5-2b-4bit", "cleanup")
    config = tmp_path / "managed.toml"
    config.write_text('[correction]\nmode = "off"\ntimeout = 12.0\n')
    original = config.read_bytes()
    settings = Settings.read(config)
    assert settings.model_dir.name == chosen.revision
    assert settings.speech_model == chosen.id
    assert settings.correction.mode == "managed"
    assert settings.correction.model == cleanup.id
    assert settings.correction.timeout == 12
    assert config.read_bytes() == original
    assert catalog.selection()["speech"].revision == chosen.revision


def test_add_pins_latest_metadata_without_downloading_weights(monkeypatch):
    model = catalog.resolve("parakeet-v3")
    config = {
        "sample_rate": 16000,
        "decoder": {"vocab_size": 8192},
        "model_defaults": {"tdt_durations": [0, 1, 2, 3, 4]},
    }
    calls = []

    def respond(request):
        calls.append(str(request.url))
        if "/api/models/" in request.url.path:
            return httpx.Response(
                200,
                json={
                    "sha": "c" * 40,
                    "siblings": [
                        {"rfilename": name, "size": 100} for name in setup.speech_models.FILES
                    ],
                },
            )
        assert "/resolve/" + "c" * 40 + "/config.json" in request.url.path
        return httpx.Response(200, json=config)

    client_type = httpx.Client
    monkeypatch.setattr(
        httpx,
        "Client",
        lambda **kwargs: client_type(transport=httpx.MockTransport(respond), **kwargs),
    )
    added = catalog.add("speech", model.repository)
    assert added.revision == "c" * 40
    assert added.id.endswith("@" + "c" * 40)
    assert len(calls) == 2  # API metadata and small config only.
    assert not catalog.selection()
    assert catalog.resolve(added.id) == added
    assert catalog.resolve("parakeet-v3").revision == model.revision  # Rollback remains available.


def test_refresh_does_not_change_active_revision_or_download(monkeypatch, capsys):
    monkeypatch.setattr(catalog, "verify", lambda _: None)
    old = catalog.choose("parakeet-v3", "speech")
    monkeypatch.setattr(catalog, "ready", lambda _: False)
    monkeypatch.setattr(
        catalog,
        "inspect_repository",
        lambda kind, repo: replace(
            next(m for m in catalog.catalog().values() if m.repository == repo),
            id=repo + "@" + "d" * 40,
            revision="d" * 40,
        ),
    )
    assert setup.run("refresh", "speech", None, 7821) == 0
    assert catalog.selection()["speech"] == old
    assert any(m.revision == "d" * 40 for m in catalog.catalog().values())
    assert "Models are up to date" in capsys.readouterr().out


def test_incompatible_model_metadata_is_rejected_before_any_selection():
    with pytest.raises(ValueError):
        catalog.validate_config("speech", {"sample_rate": 44100})
    with pytest.raises(ValueError):
        catalog.validate_config("cleanup", {"model_type": "../../custom_code"})
    assert not catalog.selection()


def test_failed_add_and_select_do_not_leak_urls(monkeypatch, capsys):
    def fail(*_):
        raise ValueError("https://private.invalid/?token=hidden")

    monkeypatch.setattr(catalog, "add", fail)
    monkeypatch.setattr(catalog, "choose", fail)
    for action in ("add", "select"):
        assert setup.run(action, "cleanup", None, 7821, "example", "org/model") == 1
        output = capsys.readouterr().out
        assert "hidden" not in output and "private.invalid" not in output
    assert not catalog.selection()


def test_cached_model_discovery_ignores_optional_repository_files(monkeypatch, tmp_path):
    import huggingface_hub

    model = catalog.resolve("qwen3-4b-instruct-2507-4bit")
    for name in ("config.json", "tokenizer_config.json", "model.safetensors"):
        (tmp_path / name).write_text("{}")

    def cached(repo, **kwargs):
        assert kwargs["local_files_only"] is True
        assert kwargs["allow_patterns"] == setup.cleanup_models.PATTERNS
        return str(tmp_path)

    monkeypatch.setattr(huggingface_hub, "snapshot_download", cached)
    assert catalog.directory(model) == tmp_path


def test_started_model_must_match_selected_local_models(monkeypatch):
    chosen = catalog.resolve("qwen3.5-2b-4bit")
    catalog.root().mkdir(parents=True)
    (catalog.root() / "token").write_text("synthetic-only")
    wanted = {"cleanup": asdict(chosen)}
    health = {
        "ready": True,
        "correction_model": chosen.id,
        "correction_mode": "endpoint",
        "correction_leaves_machine": True,
    }

    def get(url, **kwargs):
        assert kwargs["headers"]["Authorization"] == "Bearer synthetic-only"
        assert kwargs["trust_env"] is False
        return httpx.Response(200, json=health, request=httpx.Request("GET", url))

    monkeypatch.setattr(httpx, "get", get)
    assert not setup.server_matches(
        7821, wanted
    )  # Never enable local cleanup on an old remote server.
    health.update(correction_mode="managed", correction_leaves_machine=False)
    assert setup.server_matches(7821, wanted)
    health["correction_model"] = "wrong"
    assert not setup.server_matches(7821, wanted)
