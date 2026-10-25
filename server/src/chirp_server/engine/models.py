"""Explicit model acquisition. Server startup never downloads anything."""

import json
from pathlib import Path

from chirp_server import paths

REPOSITORY = "mlx-community/parakeet-tdt-0.6b-v2"
REVISION = "8ae155301e23d820d82aa60d24817c900e69e487"
FILES = ["config.json", "model.safetensors", "tokenizer.model", "vocab.txt"]
ONNX_REPOSITORY = "istupakov/parakeet-tdt-0.6b-v2-onnx"
ONNX_REVISION = "0bbb45a3365852604aef28b538a8f066f4ccaa85"
ONNX_FILES = [
    "config.json",
    "vocab.txt",
    "encoder-model.int8.onnx",
    "decoder_joint-model.int8.onnx",
    "nemo128.onnx",
]
ONNX_MODEL_ID = "parakeet-v2-onnx"


def model_root() -> Path:
    return paths.model_root()


def valid_tdt(directory: Path) -> bool:
    try:
        config = json.loads((directory / "config.json").read_text())
        # Both English v2 and multilingual v3 use this TDT interface.
        return (
            all((directory / name).is_file() for name in FILES)
            and config["sample_rate"] == 16000
            and config["decoder"]["vocab_size"] > 0
            and config["model_defaults"]["tdt_durations"] == [0, 1, 2, 3, 4]
        )
    except (OSError, ValueError, KeyError, TypeError):
        return False


def valid_v2(directory: Path) -> bool:
    return (
        valid_tdt(directory)
        and json.loads((directory / "config.json").read_text())["decoder"]["vocab_size"] == 1024
    )


def discover(explicit: Path | None = None) -> Path:
    candidates = (
        [explicit]
        if explicit
        else [
            Path.home() / ".koi/voice-models/parakeet-mlx",
            model_root() / "parakeet-mlx",
        ]
    )
    for directory in candidates:
        if directory and (valid_tdt(directory) if explicit else valid_v2(directory)):
            return directory
    raise ValueError("English Parakeet v2 model missing; run chirp-server model fetch")


def valid_onnx(directory: Path) -> bool:
    return all((directory / name).is_file() for name in ONNX_FILES)


def discover_onnx(explicit: Path | None = None) -> Path:
    candidates = (
        [explicit]
        if explicit
        else [Path.home() / ".koi/voice-models/parakeet-onnx", model_root() / "parakeet-onnx"]
    )
    for directory in candidates:
        if directory and valid_onnx(directory):
            return directory
    raise ValueError("ONNX model missing or incomplete; run chirp-server model fetch --engine onnx")


def fetch(engine: str | None = None) -> Path:
    from ..platforms import default_engine

    engine = engine or default_engine()
    if engine == "sensevoice":
        from .sensevoice_models import fetch as fetch_sensevoice

        return fetch_sensevoice()
    from huggingface_hub import snapshot_download

    directory = model_root() / f"parakeet-{engine}"
    if engine == "onnx":
        snapshot_download(
            ONNX_REPOSITORY,
            revision=ONNX_REVISION,
            local_dir=directory,
            allow_patterns=ONNX_FILES,
        )
    else:
        snapshot_download(REPOSITORY, revision=REVISION, local_dir=directory, allow_patterns=FILES)
    return directory
