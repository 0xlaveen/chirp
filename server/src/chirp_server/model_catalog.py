"""Local, revision-pinned choices. Only explicit refresh/add/download use the network."""

import contextlib
import fnmatch
import json
import os
import re
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from uuid import uuid4

from . import cleanup_models, paths
from .engine import models as speech_models
from .engine import sensevoice_models
from .fsutil import locked, private_mkdir

ENGINES = {"mlx", "onnx", "sensevoice"}


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
    # Speech only. Selections written before engine switching have none and keep server.toml's.
    engine: str = ""

    def __post_init__(self):
        from huggingface_hub.utils import validate_repo_id

        validate_repo_id(self.repository)
        if self.kind not in {"speech", "cleanup"} or not re.fullmatch(
            r"[a-f0-9]{40}", self.revision
        ):
            raise ValueError("Invalid pinned model")
        if not self.id or len(self.id) > 200 or len(self.title) > 200 or self.size_bytes < 0:
            raise ValueError("Invalid model metadata")
        if self.engine and (self.kind != "speech" or self.engine not in ENGINES):
            raise ValueError("Invalid model engine")


SENSEVOICE = "sensevoice-small"


def root():
    return paths.config_dir()


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
    private_mkdir(path.parent)
    with path.with_suffix(".lock").open("a") as lock, locked(lock.fileno()):
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
            speech_models.ONNX_MODEL_ID,
            "speech",
            "Parakeet TDT v2 · English · ONNX int8",
            speech_models.ONNX_REPOSITORY,
            speech_models.ONNX_REVISION,
            661331545,
            "English · CPU default on Intel Mac, Linux and Windows",
            "cc-by-4.0",
            engine="onnx",
        ),
        Model(
            "parakeet-v2",
            "speech",
            "Parakeet TDT v2 · English",
            speech_models.REPOSITORY,
            speech_models.REVISION,
            2472000000,
            "English · existing default",
            "cc-by-4.0",
            engine="mlx",
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
            engine="mlx",
        ),
        Model(
            SENSEVOICE,
            "speech",
            "SenseVoice Small · 中文 / 粵語 / English",
            sensevoice_models.REPOSITORY,
            sensevoice_models.REVISION,
            938576997,
            "Mandarin, Cantonese, English and mixed speech · CPU · "
            "adds a 12 MB runtime on first download",
            "FunASR model license",
            engine="sensevoice",
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
    speech = chosen.get("speech")
    return {
        "speech": SENSEVOICE
        if settings.engine == "sensevoice"
        else speech.id
        if speech and speech.engine != "sensevoice"
        else speech_models.ONNX_MODEL_ID
        if settings.engine == "onnx"
        else "parakeet-v2",
        "cleanup": chosen["cleanup"].id
        if "cleanup" in chosen
        else (settings.correction.model or cleanup_models.DEFAULT_MODEL)
        if settings.correction.mode == "managed"
        else "",
    }


def snapshot_path(model):
    from huggingface_hub.constants import HF_HUB_CACHE

    if model.engine == "sensevoice":
        return speech_models.model_root() / SENSEVOICE
    if model.id == speech_models.ONNX_MODEL_ID:
        try:
            return speech_models.discover_onnx()
        except ValueError:
            return speech_models.model_root() / "parakeet-onnx"
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
    if model.engine == "sensevoice":
        return sensevoice_models.discover()
    if model.id == speech_models.ONNX_MODEL_ID:
        return speech_models.discover_onnx()
    path = Path(
        snapshot_download(
            model.repository,
            revision=model.revision,
            local_files_only=True,
            allow_patterns=(
                speech_models.ONNX_FILES if model.engine == "onnx" else speech_models.FILES
            )
            if model.kind == "speech"
            else cleanup_models.PATTERNS,
        )
    )
    valid = (
        (
            speech_models.valid_onnx(path)
            if model.engine == "onnx"
            else speech_models.valid_tdt(path)
        )
        if model.kind == "speech"
        else cleanup_models.complete(path)
    )
    if not valid:
        raise ValueError("Model files missing or incomplete")
    return path


def ready(model):
    try:
        directory(model)
        return model.engine != "sensevoice" or sensevoice_models.runtime_installed()
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
        portable = next(
            (
                m
                for m in catalog().values()
                if m.kind == kind and m.repository == repository and m.engine == "onnx"
            ),
            None,
        )
        if portable:
            files = {item["rfilename"]: item.get("size", 0) for item in siblings}
            if not set(speech_models.ONNX_FILES).issubset(files):
                raise ValueError("Repository lacks portable ONNX model files")
            return replace(
                portable,
                id=f"{repository}@{revision}",
                revision=revision,
                size_bytes=sum(files[name] for name in speech_models.ONNX_FILES),
            )
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
            engine="mlx" if kind == "speech" else "",
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
        if model.engine == "sensevoice":
            from .engine.sensevoice import SenseVoice

            engine = SenseVoice(path)
            engine.load()
            engine.warm()
        elif model.engine == "onnx":
            from .engine.onnx import ParakeetONNX

            engine = ParakeetONNX(path, intra_op_num_threads=4, inter_op_num_threads=1)
            engine.load()
            engine.warm()
            engine.close()
        elif model.kind == "speech":
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
    if kind == "speech" and not model.engine:
        model = replace(model, engine="mlx")  # Added Parakeet repositories run on MLX.
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
    """The app's choices override server.toml; a speech choice also picks its engine."""
    chosen = selection()
    if speech := chosen.get("speech"):
        settings.engine = speech.engine or settings.engine
        if speech.engine != "sensevoice":
            settings.speech_model = speech.id
            settings.model_dir = snapshot_path(speech)
    if cleanup := chosen.get("cleanup"):
        settings.correction = replace(settings.correction, mode="managed", model=cleanup.id)
