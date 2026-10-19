"""Local, revision-pinned choices. Only explicit refresh/add/download use the network."""

import contextlib
import fcntl
import fnmatch
import json
import os
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from uuid import uuid4

from . import cleanup_models
from .engine import models as speech_models


@dataclass(frozen=True)
class Model:
    id: str
    kind: str
    title: str
    repository: str
    revision: str
    size_bytes: int = 0
    details: str = ""
    license: str = ""
    memory_mb: int = 0
    latest: bool = False

    def __post_init__(self):
        from huggingface_hub.utils import validate_repo_id

        validate_repo_id(self.repository)
        if self.kind not in {"speech", "cleanup"} or not re.fullmatch(
            r"[a-f0-9]{40}", self.revision
        ):
            raise ValueError("Invalid pinned model")
        if not self.id or len(self.id) > 200 or len(self.title) > 200 or self.size_bytes < 0:
            raise ValueError("Invalid model metadata")


def root():
    return Path.home() / ".config/chirp"


def read_json(path):
    try:
        if path.stat().st_size > 1024 * 1024:
            raise ValueError("Model state too large")
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    if not isinstance(value, dict):
        raise ValueError("Invalid model state")
    return value


def update_json(path, update):
    """Serialize concurrent CLI/UI writers and replace atomically; never edit server.toml."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        value = update(read_json(path))
        temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(value, stream)
                stream.write("\n")
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    return value


def defaults():
    result = [
        Model(
            "parakeet-v2",
            "speech",
            "Parakeet TDT v2 · English",
            speech_models.REPOSITORY,
            speech_models.REVISION,
            2472000000,
            "English · existing default",
            "cc-by-4.0",
        ),
        Model(
            "parakeet-v3",
            "speech",
            "Parakeet TDT v3 · Multilingual",
            "mlx-community/parakeet-tdt-0.6b-v3",
            "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15",
            2509044141,
            "25 languages · alternative",
            "cc-by-4.0",
        ),
    ]
    for key, spec in cleanup_models.MODELS.items():
        result.append(
            Model(
                key,
                "cleanup",
                {
                    "qwen3-4b-instruct-2507-4bit": "Qwen3 4B Instruct · 4-bit",
                    "qwen3.5-2b-4bit": "Qwen3.5 2B · 4-bit",
                    "qwen3.5-0.8b-4bit": "Qwen3.5 0.8B · 4-bit",
                }[key],
                spec.repository,
                spec.revision,
                size_bytes={
                    "qwen3-4b-instruct-2507-4bit": 2278969697,
                    "qwen3.5-2b-4bit": 1749079691,
                    "qwen3.5-0.8b-4bit": 652027143,
                }[key],
                details="Balanced default"
                if key == cleanup_models.DEFAULT_MODEL
                else "Smaller · lower correction accuracy in Chirp tests",
                memory_mb=spec.memory_mb,
            )
        )
    result.append(
        Model(
            "qwen3.5-4b-4bit",
            "cleanup",
            "Qwen3.5 4B · 4-bit",
            "mlx-community/Qwen3.5-4B-4bit",
            "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c",
            3061130647,
            "Larger alternative · not benchmarked by Chirp",
        )
    )
    return result


def catalog():
    result = {model.id: model for model in defaults()}
    for value in read_json(root() / "model-catalog.json").values():
        model = Model(**value)
        result[model.id] = model
    return result


def resolve(choice, kind=None):
    try:
        model = catalog()[choice]
    except KeyError:
        raise ValueError("Unknown model choice") from None
    if kind and model.kind != kind:
        raise ValueError("Wrong model kind")
    return model


def selection():
    data = read_json(root() / "model-selection.json")
    return {kind: Model(**data[kind]) for kind in ("speech", "cleanup") if kind in data}


def pending_restart():
    return read_json(root() / "model-selection.json").get("restart_required", False) is True


def active_ids(settings):
    chosen = selection()
    return {
        "speech": chosen["speech"].id if "speech" in chosen else "parakeet-v2",
        "cleanup": chosen["cleanup"].id
        if "cleanup" in chosen
        else (settings.correction.model or cleanup_models.DEFAULT_MODEL)
        if settings.correction.mode == "managed"
        else "",
    }


def snapshot_path(model):
    from huggingface_hub.constants import HF_HUB_CACHE

    if model.id == "parakeet-v2":
        try:
            return speech_models.discover()
        except ValueError:
            return speech_models.model_root() / "parakeet-mlx"
    return (
        Path(HF_HUB_CACHE)
        / ("models--" + model.repository.replace("/", "--"))
        / "snapshots"
        / model.revision
    )


def directory(model):
    from huggingface_hub import snapshot_download

    if model.id == "parakeet-v2":
        return speech_models.discover()
    path = Path(
        snapshot_download(
            model.repository,
            revision=model.revision,
            local_files_only=True,
            allow_patterns=speech_models.FILES
            if model.kind == "speech"
            else cleanup_models.PATTERNS,
        )
    )
    valid = (
        speech_models.valid_tdt(path) if model.kind == "speech" else cleanup_models.complete(path)
    )
    if not valid:
        raise ValueError("Model files missing or incomplete")
    return path


def ready(model):
    try:
        directory(model)
        return True
    except (OSError, ValueError):
        return False


def options(settings):
    active = active_ids(settings)
    # Keep the active pinned revision in the picker even after a catalog refresh.
    models = catalog()
    for model in selection().values():
        models.setdefault(model.id, model)
    return [
        dict(asdict(model), ready=ready(model), active=active[model.kind] == model.id)
        for model in models.values()
    ]


def validate_config(kind, config):
    if kind == "speech":
        if not (
            config.get("sample_rate") == 16000
            and config.get("decoder", {}).get("vocab_size", 0) > 0
            and config.get("model_defaults", {}).get("tdt_durations") == [0, 1, 2, 3, 4]
        ):
            raise ValueError("Use a 16 kHz Parakeet TDT MLX model")
    else:
        if not re.fullmatch(r"[a-z0-9_]+", config.get("model_type", "")):
            raise ValueError("Missing MLX language model architecture")
        from mlx_lm.utils import _get_classes

        _, arguments = _get_classes(config)  # Installed architectures only; no remote Python.
        arguments.from_dict(config)
        if not (config.get("quantization") or config.get("quantization_config")):
            raise ValueError("Use a quantized MLX language model")


def inspect_repository(kind, repository):
    """Fetch only small metadata; pin main to a commit before any weight download."""
    import httpx
    from huggingface_hub.utils import validate_repo_id

    validate_repo_id(repository)
    with httpx.Client(timeout=20, follow_redirects=True) as client:
        response = client.get(
            f"https://huggingface.co/api/models/{repository}", params={"blobs": "true"}
        )
        response.raise_for_status()
        info = response.json()
        revision = info["sha"]
        if not re.fullmatch(r"[a-f0-9]{40}", revision):
            raise ValueError("Missing immutable model revision")
        siblings = info["siblings"]
        patterns = speech_models.FILES if kind == "speech" else cleanup_models.PATTERNS
        files = [
            item
            for item in siblings
            if any(fnmatch.fnmatch(item["rfilename"], p) for p in patterns)
        ]
        names = {item["rfilename"] for item in files}
        if any("/" in name or name.startswith(".") for name in names):
            raise ValueError("Use a model with root-level files")
        required = (
            set(speech_models.FILES)
            if kind == "speech"
            else {"config.json", "tokenizer_config.json"}
        )
        if not required.issubset(names) or not any(name.endswith(".safetensors") for name in names):
            raise ValueError("Repository lacks MLX weights or tokenizer files")
        config_response = client.get(
            f"https://huggingface.co/{repository}/resolve/{revision}/config.json"
        )
        config_response.raise_for_status()
        if len(config_response.content) > 1024 * 1024:
            raise ValueError("Model config too large")
        validate_config(kind, config_response.json())
        size = sum(item.get("size", 0) for item in files)
        if size <= 0:
            raise ValueError("Model download size unavailable")
        existing = next(
            (
                m
                for m in catalog().values()
                if m.kind == kind and m.repository == repository and m.revision == revision
            ),
            None,
        )
        card = info.get("cardData") or {}
        return Model(
            existing.id if existing else f"{repository}@{revision}",
            kind,
            existing.title if existing else repository.split("/")[-1],
            repository,
            revision,
            size,
            existing.details
            if existing
            else "Loader-compatible · correction quality not benchmarked",
            str(card.get("license", ""))[:200],
            existing.memory_mb if existing else 0,
            latest=True,
        )


def add(kind, repository):
    model = inspect_repository(kind, repository)

    def update(data):
        for previous in data.values():
            if previous["repository"] == model.repository and previous["kind"] == model.kind:
                previous["latest"] = False
        return {**data, model.id: asdict(model)}

    update_json(root() / "model-catalog.json", update)
    return model


def verify(model):
    """Load before selection, in the helper process, preserving the running server on failure."""
    path = directory(model)
    with (
        open(os.devnull, "w") as sink,
        contextlib.redirect_stdout(sink),
        contextlib.redirect_stderr(sink),
    ):
        if model.kind == "speech":
            from .engine.mlx import ParakeetMLX

            engine = ParakeetMLX(path)
            engine.load()
            engine.warm()
        else:
            from mlx_lm import load

            _, tokenizer = load(str(path), trust_remote_code=False)
            tokenizer.apply_chat_template(
                [
                    {"role": "system", "content": "Polish the transcript."},
                    {"role": "user", "content": "hello"},
                ],
                tokenize=True,
                add_generation_prompt=True,
                enable_thinking=False,
            )


def choose(choice, kind):
    model = resolve(choice, kind)
    verify(model)  # No selection file is touched until this succeeds.
    update_json(
        root() / "model-selection.json",
        lambda data: {
            **data,
            kind: asdict(model),
            "restart_required": True,
            "correction_changed": kind == "cleanup" or data.get("correction_changed", False),
        },
    )
    return model


def apply_settings(settings):
    chosen = selection()
    if speech := chosen.get("speech"):
        settings.speech_model = speech.id
        settings.model_dir = snapshot_path(speech)
    if cleanup := chosen.get("cleanup"):
        from dataclasses import replace

        settings.correction = replace(settings.correction, mode="managed", model=cleanup.id)
