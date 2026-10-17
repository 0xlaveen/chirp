"""Synthetic helper exercising real pipe supervision without MLX."""

import json
import sys

print(json.dumps({"ready": True}), flush=True)
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
    print(
        json.dumps({"ok": True, "text": text.capitalize() + ".", "finish_reason": "stop"}),
        flush=True,
    )
