"""Pinned cleanup catalog. Only the explicit CLI fetch may acquire weights."""

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CleanupModel:
    repository: str
    revision: str


MODELS = {
    "qwen3-4b-instruct-2507-4bit": CleanupModel(
        "mlx-community/Qwen3-4B-Instruct-2507-4bit", "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
    ),
    "qwen3.5-2b-4bit": CleanupModel(
        "mlx-community/Qwen3.5-2B-4bit", "674aaa7240b91e8012fcad5d791b7dfe5ba90207"
    ),
    "qwen3.5-0.8b-4bit": CleanupModel(
        "mlx-community/Qwen3.5-0.8B-4bit", "da28692b5f139cb0ec58a356b437486b7dac7462"
    ),
}
DEFAULT_MODEL = "qwen3-4b-instruct-2507-4bit"
PATTERNS = ["*.json", "*.safetensors", "*.jinja", "*.model", "merges.txt"]


def model_spec(model_id: str = "") -> CleanupModel:
    try:
        return MODELS[model_id or DEFAULT_MODEL]
    except KeyError:
        raise ValueError("Unknown cleanup model; use a catalog id") from None


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


def discover(model_id: str = "") -> Path:
    from huggingface_hub import snapshot_download

    model = model_spec(model_id)
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
