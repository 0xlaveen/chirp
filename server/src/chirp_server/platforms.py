"""Hardware capabilities shared by defaults and setup; no platform side effects."""

import platform
import sys


def supports_mlx() -> bool:
    """MLX needs native Apple Silicon. An Intel/Rosetta Python must use ONNX."""
    return sys.platform == "darwin" and platform.machine().lower() in {"arm64", "aarch64"}


def default_engine() -> str:
    return "mlx" if supports_mlx() else "onnx"


def default_cleanup_backend() -> str:
    return "mlx" if supports_mlx() else "llama_cpp"
