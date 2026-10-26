"""The pinned speaker-embedding model for Live Notes speaker labels (issue #187).

WeSpeaker's ResNet34-LM trained on VoxCeleb (CC-BY-4.0), as ONNX, from the WeSpeaker Hugging
Face repository at a pinned revision. Only the one ONNX file is fetched, only on an explicit
request (`chirp-server model fetch --speakers`, or a paired client's consented
`POST /v1/speakers/model`), and it is checked against its pinned size and SHA-256 before use:
a mismatch is deleted. Server startup and labelling never touch the network.
"""

import hashlib
import shutil
from pathlib import Path

from .engine.models import model_root
from .fsutil import private_mkdir

REPOSITORY = "Wespeaker/wespeaker-voxceleb-resnet34-LM"
REVISION = "f0c48c298fd835726c27956a5d617bad7115627e"
FILE = "voxceleb_resnet34_LM.onnx"
SIZE = 26_530_309
SHA256 = "7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068"
LICENSE = "cc-by-4.0"
# What a saved voice records: a voice from another model (or revision) is never compared.
MODEL_ID = f"{REPOSITORY.split('/')[1]}@{REVISION[:8]}"
# What a client's consent prompt quotes.
SIZE_TEXT = "27 MB"


def directory() -> Path:
    return model_root() / "speakers"


def path() -> Path:
    return directory() / FILE


def is_downloaded() -> bool:
    """The pinned file is on disk at its pinned size (the hash was checked when it arrived)."""
    try:
        return path().stat().st_size == SIZE
    except OSError:
        return False


def has_files() -> bool:
    return directory().is_dir() and any(directory().iterdir())


def verify(file: Path) -> bool:
    try:
        with file.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        return file.stat().st_size == SIZE and digest == SHA256
    except OSError:
        return False


def fetch() -> Path:
    """Download the pinned file (the only network use), verify it, and return its path."""
    from huggingface_hub import hf_hub_download

    if is_downloaded() and verify(path()):
        return path()
    target = directory()
    private_mkdir(target)
    downloaded = Path(hf_hub_download(REPOSITORY, FILE, revision=REVISION, local_dir=target))
    if not verify(downloaded):
        remove()
        raise ValueError("Speaker model checksum mismatch; the download was deleted")
    return downloaded


def remove() -> None:
    """Delete the model and any partial download (Remove, or a failed check)."""
    shutil.rmtree(directory(), ignore_errors=True)
