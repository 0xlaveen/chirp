"""Synthetic helper exercising real pipe supervision without MLX."""

import json
import sys
import time

args = sys.argv[1:]
if "--fail" in args:
    # Mimic a helper whose model fails to load: no ready, process exits.
    print(json.dumps({"ready": False}), flush=True)
    raise SystemExit(0)
if "--delay" in args:
    time.sleep(float(args[args.index("--delay") + 1]))
print(json.dumps({"ready": True, "memory_mb": 12}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    text = request["text"]
    if text == "hang":
        sys.stdin.read()
        break
    if text == "crash":
        raise SystemExit(1)
    if text == "invalid":
        print("[]", flush=True)
        continue
    reply = args[args.index("--reply") + 1] if "--reply" in args else text.capitalize() + "."
    print(
        json.dumps({"ok": True, "text": reply, "finish_reason": "stop"}),
        flush=True,
    )
