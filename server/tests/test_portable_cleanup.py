"""Portable cleanup framing, pinned files and real helper supervision with no model download."""

import io
import json

import pytest
from conftest import use_home

from chirp_server import cleanup_models, cleanup_worker, model_catalog, platforms
from chirp_server.config import CorrectionConfig, Settings


@pytest.fixture(autouse=True)
def isolated(monkeypatch, tmp_path):
    use_home(monkeypatch, tmp_path)


@pytest.mark.parametrize(
    "system,machine,backend",
    [
        ("darwin", "arm64", "mlx"),
        ("darwin", "x86_64", "llama_cpp"),
        ("linux", "aarch64", "llama_cpp"),
        ("win32", "AMD64", "llama_cpp"),
    ],
)
def test_default_backend_follows_hardware(monkeypatch, system, machine, backend):
    monkeypatch.setattr(platforms.sys, "platform", system)
    monkeypatch.setattr(platforms.platform, "machine", lambda: machine)
    config = CorrectionConfig()
    assert config.backend == backend and config.mode == "off"
    assert config.model == (cleanup_models.PORTABLE_MODEL if backend == "llama_cpp" else "")


@pytest.mark.parametrize(
    "values",
    [{"backend": "bad"}, {"llama_threads": True}, {"llama_threads": 0}, {"llama_threads": 257}],
)
def test_backend_limits_are_validated(values):
    with pytest.raises(ValueError):
        CorrectionConfig(**values)


def test_explicit_gguf_choice_selects_portable_backend(monkeypatch):
    monkeypatch.setattr(platforms.sys, "platform", "darwin")
    monkeypatch.setattr(platforms.platform, "machine", lambda: "arm64")
    assert CorrectionConfig(model=cleanup_models.PORTABLE_MODEL).backend == "llama_cpp"
    monkeypatch.setattr(model_catalog, "verify", lambda _: None)
    model_catalog.choose(cleanup_models.PORTABLE_MODEL, "cleanup")
    settings = Settings()
    model_catalog.apply_settings(settings)
    assert settings.correction.mode == "managed"
    assert settings.correction.backend == "llama_cpp"
    assert settings.correction.model == cleanup_models.PORTABLE_MODEL


def test_gguf_cache_lookup_and_explicit_fetch_use_one_pinned_file(monkeypatch, tmp_path):
    import huggingface_hub

    path = tmp_path / "model.gguf"
    path.write_bytes(b"GGUF" + b"\0" * 28)
    calls = []

    def download(repository, filename, **kwargs):
        calls.append((repository, filename, kwargs))
        return str(path)

    monkeypatch.setattr(huggingface_hub, "hf_hub_download", download)
    assert cleanup_models.discover(cleanup_models.PORTABLE_MODEL) == path
    assert cleanup_models.fetch(cleanup_models.PORTABLE_MODEL) == path
    assert calls[0][2]["local_files_only"] is True
    assert "local_files_only" not in calls[1][2]
    assert all(len(call[2]["revision"]) == 40 for call in calls)
    assert calls[0][1].endswith("Q4_K_M.gguf")
    path.write_bytes(b"version https://git-lfs.github.com/spec/v1")
    with pytest.raises(ValueError, match="incomplete"):
        cleanup_models.discover(cleanup_models.PORTABLE_MODEL)


class Llama:
    def __init__(self, count=50):
        self.count = count
        self.calls = []

    def tokenize(self, prompt, **kwargs):
        self.prompt = prompt.decode()
        assert kwargs == {"add_bos": False, "special": True}
        return [1] * self.count

    def create_completion(self, **kwargs):
        self.calls.append(kwargs)
        return {"choices": [{"text": " Synthetic result. ", "finish_reason": "stop"}]}


def test_llama_notes_request_uses_exact_counted_prompt_and_output_budget(monkeypatch):
    replies = []
    monkeypatch.setattr(cleanup_worker, "reply", replies.append)
    model = Llama()
    cleanup_worker.generate_llama(
        json.dumps(
            {"text": "", "system": "Structure notes", "user": "Notes JSON: {}", "max_tokens": 1024}
        ),
        model,
    )
    assert "Notes JSON: {}" in model.prompt and "Transcript JSON:" not in model.prompt
    assert model.prompt.endswith("<|im_start|>assistant\n")
    assert model.calls[0]["prompt"] == [1] * 50
    assert model.calls[0]["max_tokens"] == 1024
    assert model.calls[0]["temperature"] == 0
    assert replies == [{"ok": True, "text": "Synthetic result.", "finish_reason": "stop"}]


def test_context_overflow_fails_before_generation(monkeypatch):
    replies = []
    monkeypatch.setattr(cleanup_worker, "reply", replies.append)
    model = Llama(4000)
    cleanup_worker.generate_llama(json.dumps({"text": "synthetic", "system": "Polish"}), model)
    assert replies == [{"ok": False}] and not model.calls


def test_pipe_reader_needs_no_select_and_stops_at_eof():
    assert list(cleanup_worker.input_lines(io.StringIO("one\ntwo\n"), 0)) == ["one\n", "two\n"]


def test_portable_picker_excludes_unsupported_mlx_choices(monkeypatch):
    monkeypatch.setattr(platforms.sys, "platform", "linux")
    monkeypatch.setattr(platforms.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(model_catalog, "ready", lambda _: False)
    options = model_catalog.options(Settings())
    assert any(option["id"] == cleanup_models.PORTABLE_MODEL for option in options)
    assert any(option["engine"] == "onnx" for option in options)
    assert all(option["engine"] != "mlx" for option in options)
    assert all(
        option["kind"] != "cleanup" or option["cleanup_backend"] == "llama_cpp"
        for option in options
    )


def test_cpu_budgets_preserve_explicit_values_and_mlx_endpoint_defaults():
    cpu = CorrectionConfig(mode="managed", backend="llama_cpp")
    assert (cpu.timeout, cpu.notes_timeout, cpu.structure_timeout, cpu.reorganize_timeout) == (
        30,
        45,
        90,
        120,
    )
    mlx = CorrectionConfig(mode="managed", backend="mlx")
    endpoint = CorrectionConfig(mode="endpoint")
    assert (mlx.timeout, mlx.notes_timeout, mlx.structure_timeout, mlx.reorganize_timeout) == (
        8,
        15,
        30,
        45,
    )
    assert endpoint.timeout == 8
    assert CorrectionConfig(mode="managed", backend="llama_cpp", timeout=2.5).timeout == 2.5


def test_picker_switches_backend_defaults_but_keeps_explicit_budgets():
    config = CorrectionConfig(mode="endpoint", timeout=3.0)
    cpu = config.with_model(cleanup_models.PORTABLE_MODEL, "llama_cpp")
    assert cpu.timeout == 3 and cpu.structure_timeout == 90
    mlx = cpu.with_model(cleanup_models.DEFAULT_MODEL, "mlx")
    assert mlx.timeout == 3 and mlx.structure_timeout == 30
