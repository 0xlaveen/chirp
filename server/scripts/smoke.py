"""Short-lived real uvicorn + WS simulator check; no service installation or transcript output."""

import argparse
import asyncio
import contextlib
import importlib.util
import json
import secrets
import socket
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

import uvicorn

from chirp_server.app import create_app
from chirp_server.config import Settings
from chirp_server.engine.mlx import ParakeetMLX
from chirp_server.paths import fixtures_dir

MODULE_PATH = Path(__file__).resolve().parents[1] / "tests/client_sim.py"


async def smoke():
    module_path = MODULE_PATH
    spec = importlib.util.spec_from_file_location("client_sim", module_path)
    client_sim = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client_sim)
    token = secrets.token_urlsafe(32)
    app = create_app(Settings(), ParakeetMLX(), token)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen()
    port = sock.getsockname()[1]
    server = uvicorn.Server(
        uvicorn.Config(
            app, access_log=False, log_level="warning", root_path="/chirp", proxy_headers=False
        )
    )
    started = time.perf_counter()
    task = asyncio.create_task(server.serve(sockets=[sock]))
    try:
        async with asyncio.timeout(30):
            while not server.started:
                if task.done():
                    await task
                    raise RuntimeError("Server failed to start")
                await asyncio.sleep(0.05)
        print(json.dumps({"load_and_decode_warm_seconds": time.perf_counter() - started}))
        with tempfile.TemporaryDirectory(prefix="chirp-smoke-") as directory:
            credential = Path(directory) / "token"
            credential.touch(mode=0o600)
            credential.write_text(token)
            result = await client_sim.run(
                SimpleNamespace(
                    wav=fixtures_dir() / "synthetic-5s.wav",
                    token_file=credential,
                    url=f"http://127.0.0.1:{port}",
                    correction=False,
                    show_text=False,
                    fast=False,
                )
            )
            keyword_match = "fox" in result["raw"].lower()
            assert keyword_match
            assert result["timings_ms"]["first_partial"] is not None
    finally:
        server.should_exit = True
        with contextlib.suppress(asyncio.CancelledError):
            await task
        sock.close()


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
    asyncio.run(smoke())
