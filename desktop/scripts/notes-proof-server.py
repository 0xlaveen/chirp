"""A disposable real ONNX/GGUF server for the explicit desktop Notes smoke only."""
import os
import secrets
import tempfile
from pathlib import Path

home = Path(tempfile.mkdtemp(prefix="chirp-notes-proof-"))
for key, value in {
    "HOME": str(home),
    "XDG_CONFIG_HOME": str(home / ".config"),
    "XDG_DATA_HOME": str(home / ".local/share"),
    "XDG_CACHE_HOME": str(home / ".cache"),
    "HF_HUB_CACHE": "/models/hub",
    "HF_HUB_OFFLINE": "1",
    "TRANSFORMERS_OFFLINE": "1",
}.items():
    os.environ[key] = value

from chirp_server.app import create_app  # noqa: E402
from chirp_server.config import CorrectionConfig, Settings  # noqa: E402
from chirp_server.cleanup_models import model_spec, PORTABLE_MODEL  # noqa: E402
import uvicorn  # noqa: E402

model = model_spec(PORTABLE_MODEL)
cache = Path(os.environ["HF_HUB_CACHE"]) / ("models--" + model.repository.replace("/", "--")) / "snapshots" / model.revision / model.filename
cache.parent.mkdir(parents=True, exist_ok=True)
cache.symlink_to("/models/cleanup.gguf")
token = secrets.token_urlsafe(32)
path = Path("/tmp/chirp-notes-proof.token")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as file:
    file.write(token)
app = create_app(Settings(engine="onnx", model_dir=Path("/models/parakeet-onnx"), correction=CorrectionConfig(mode="managed", backend="llama_cpp")), token=token)
uvicorn.run(app, host="127.0.0.1", port=17992, access_log=False)
