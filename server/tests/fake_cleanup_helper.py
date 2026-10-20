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


def option(name):
    return args[args.index(name) + 1] if name in args else None


for line in sys.stdin:
    request = json.loads(line)
    text = request["text"]
    # Live Notes segment correction sends its own `Transcript JSON:` user message.
    notes_correction = str(request.get("user", "")).startswith("Transcript JSON: ")
    if notes_correction:
        text = json.loads(request["user"].removeprefix("Transcript JSON: "))
    structure = "user" in request and not notes_correction
    # Reorganize sends `Notes JSON: {"outline": ..., "notes": ...}`; structure has "transcript".
    try:
        payload = json.loads(request["user"].removeprefix("Notes JSON: ")) if structure else {}
    except ValueError:
        payload = {}
    reorganize = isinstance(payload, dict) and "notes" in payload
    trigger = "notes" if reorganize else "transcript"
    if option("--log"):
        # Synthetic request log for tests: which kind arrived, with the notes keys echoed.
        with open(option("--log"), "a") as log:
            entry = {
                "kind": "reorganize"
                if reorganize
                else "structure"
                if structure
                else "notes_correction"
                if notes_correction
                else "correction",
                "user": request.get("user"),
                "max_tokens": request.get("max_tokens"),
                "keys": sorted(request),
                "at": time.monotonic(),
            }
            log.write(json.dumps(entry) + "\n")
    if structure:
        if f'"{trigger}": "hang"' in request["user"]:
            sys.stdin.read()
            break
        if f'"{trigger}": "crash"' in request["user"]:
            raise SystemExit(1)
        if f'"{trigger}": "fail"' in request["user"]:
            print(json.dumps({"ok": False}), flush=True)
            continue
        if f'"{trigger}": "invalid"' in request["user"]:
            print("[]", flush=True)
            continue
        if option("--slow-structure"):
            time.sleep(float(option("--slow-structure")))
        if reorganize:
            reply = option("--reply-reorganize") or "## Notes\n- Done"
        else:
            reply = option("--reply-structure") or "## Notes\n- Done"
        print(json.dumps({"ok": True, "text": reply, "finish_reason": "stop"}), flush=True)
        continue
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
