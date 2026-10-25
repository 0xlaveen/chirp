"""Pinned cleanup catalog. Only the explicit CLI fetch may acquire weights."""

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CleanupModel:
    repository: str
    revision: str
    # Measured physical-footprint MiB (steady state after one generation; see
    # docs/bench.md) on the reference M5 Pro; the estimate reported before this
    # server has measured one of its own loads.
    memory_mb: int
    backend: str = "mlx"
    filename: str = ""
    size_bytes: int = 0


MODELS = {
    "qwen3-4b-instruct-2507-4bit": CleanupModel(
        "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        2563,
    ),
    "qwen3.5-2b-4bit": CleanupModel(
        "mlx-community/Qwen3.5-2B-4bit",
        "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
        1607,
    ),
    "qwen3.5-0.8b-4bit": CleanupModel(
        "mlx-community/Qwen3.5-0.8B-4bit",
        "da28692b5f139cb0ec58a356b437486b7dac7462",
        1011,
    ),
}
DEFAULT_MODEL = "qwen3-4b-instruct-2507-4bit"
PORTABLE_MODEL = "qwen3-4b-instruct-2507-q4-k-m-gguf"
GGUF_MODELS = {
    PORTABLE_MODEL: CleanupModel(
        "lmstudio-community/Qwen3-4B-Instruct-2507-GGUF",
        "4edb920b6f14e3b9284d4502a6485103d72cde05",
        3200,  # Estimate including context; measured RSS replaces it after loading.
        "llama_cpp",
        "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        2497280448,
    ),
}
PATTERNS = ["*.json", "*.safetensors", "*.jinja", "*.model", "merges.txt"]


def model_spec(model_id: str = "") -> CleanupModel:
    try:
        return (MODELS | GGUF_MODELS)[model_id or DEFAULT_MODEL]
    except KeyError:
        from .model_catalog import resolve, selection

        selected = selection().get("cleanup")
        model = selected if selected and selected.id == model_id else resolve(model_id, "cleanup")
        return CleanupModel(
            model.repository,
            model.revision,
            model.memory_mb or round(model.size_bytes / 1048576 * 1.25),
            model.cleanup_backend or "mlx",
            model.filename,
            model.size_bytes,
        )


def complete(path: Path) -> bool:
    try:
        if not all((path / name).is_file() for name in ("config.json", "tokenizer_config.json")):
            return False
        if (path / "model.safetensors").is_file():
            return True
        index = json.loads((path / "model.safetensors.index.json").read_text())
        return bool(index["weight_map"]) and all(
            (path / name).is_file() for name in set(index["weight_map"].values())
        )
    except (OSError, ValueError, KeyError, TypeError):
        return False


def complete_gguf(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return path.stat().st_size >= 16 and stream.read(4) == b"GGUF"
    except OSError:
        return False


def _gguf(model, *, cached):
    from huggingface_hub import hf_hub_download

    options = {"local_files_only": True} if cached else {}
    try:
        path = Path(
            hf_hub_download(model.repository, model.filename, revision=model.revision, **options)
        )
    except OSError:
        raise ValueError(
            "GGUF cleanup model missing; run chirp-server model fetch --cleanup " + PORTABLE_MODEL
        ) from None
    if not complete_gguf(path):
        raise ValueError("GGUF cleanup model incomplete; fetch it again")
    return path


def discover(model_id: str = "") -> Path:
    from huggingface_hub import snapshot_download

    model = model_spec(model_id)
    if model.backend == "llama_cpp":
        return _gguf(model, cached=True)
    try:
        directory = Path(
            snapshot_download(
                model.repository,
                revision=model.revision,
                local_files_only=True,
                allow_patterns=PATTERNS,
            )
        )
    except OSError:
        raise ValueError("Cleanup model missing; run chirp-server model fetch --cleanup") from None
    if not complete(directory):
        raise ValueError("Cleanup model incomplete; run chirp-server model fetch --cleanup")
    return directory


def fetch(model_id: str = "") -> Path:
    from huggingface_hub import snapshot_download

    model = model_spec(model_id)
    if model.backend == "llama_cpp":
        return _gguf(model, cached=False)
    # Shared HF snapshots avoid duplicating already cached weights. No server call reaches here.
    directory = Path(
        snapshot_download(
            model.repository,
            revision=model.revision,
            allow_patterns=PATTERNS,
        )
    )
    if not complete(directory):
        raise ValueError("Cleanup model download incomplete")
    return directory
