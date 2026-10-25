"""Real-time v1 WS client. Text output requires explicit --show-text opt-in."""

import argparse
import asyncio
import json
import time
from pathlib import Path

import websockets

from chirp_server.audio import decode_wav
from chirp_server.paths import config_dir


async def run(args):
    pcm = decode_wav(args.wav.read_bytes())
    token = args.token_file.read_text().strip()
    url = args.url.replace("https://", "wss://").replace("http://", "ws://").rstrip("/")
    async with websockets.connect(
        url + "/v1/stream", additional_headers={"Authorization": f"Bearer {token}"}
    ) as ws:
        await ws.send(
            json.dumps(
                {
                    "type": "start",
                    "sample_rate": 16000,
                    "encoding": "pcm_s16le",
                    "client": "mac",
                    "correction": args.correction,
                }
            )
        )
        ready = json.loads(await ws.recv())
        if ready.get("type") != "ready":
            raise SystemExit(ready.get("code", "protocol error"))
        print(json.dumps(ready))

        async def receive():
            count = 0
            while True:
                message = json.loads(await ws.recv())
                if message["type"] == "partial":
                    count += 1
                    print(
                        json.dumps(
                            message
                            if args.show_text
                            else {
                                "type": "partial",
                                "seq": message["seq"],
                                "characters": len(message["text"]),
                            }
                        )
                    )
                elif message["type"] == "final":
                    result = (
                        message
                        if args.show_text
                        else {
                            "type": "final",
                            "characters": len(message["text"]),
                            "corrected": message["corrected"],
                            "timings_ms": message["timings_ms"],
                            "partials": count,
                        }
                    )
                    print(json.dumps(result))
                    return message
                elif message["type"] == "error":
                    raise SystemExit(message["code"])

        listener = asyncio.create_task(receive())
        started = time.perf_counter()
        for offset in range(0, len(pcm), 1600):  # 50 ms
            await ws.send(pcm[offset : offset + 1600])
            if not args.fast:
                await asyncio.sleep(max(0, started + (offset + 1600) / 32000 - time.perf_counter()))
        await ws.send(json.dumps({"type": "stop"}))
        return await listener


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", type=Path)
    parser.add_argument("--url", default="http://127.0.0.1:7821")
    parser.add_argument("--token-file", type=Path, default=config_dir() / "token")
    parser.add_argument("--correction", action="store_true")
    parser.add_argument("--fast", action="store_true")
    parser.add_argument(
        "--show-text",
        action="store_true",
        help="Print synthetic/test transcripts locally; never enable in recorded logs",
    )
    asyncio.run(run(parser.parse_args()))
