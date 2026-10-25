"""Private JSON-line helper. MLX loads and generates on this process's main thread."""

import contextlib
import json
import os
import select
import sys

MAX_CONTEXT = 4096
MAX_OUTPUT = 512


def measured_memory_mb() -> int:
    """Peak process RSS plus active Metal memory, rounded to MiB.

    Fallback approximation for hosts where the server cannot read the helper's
    physical footprint: ru_maxrss is reported in bytes on macOS, and Metal
    (unified-memory) allocations do not necessarily appear in RSS. The server's
    own proc_pid_rusage phys_footprint reading is preferred whenever available.
    """
    import resource

    total = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    try:
        import mlx.core as mx

        total += mx.metal.get_active_memory()
    except Exception:
        pass
    return round(total / 1048576)


def reply(payload):
    sys.__stdout__.write(json.dumps(payload) + "\n")
    sys.__stdout__.flush()


def generate(line, model, tokenizer, sampler):
    # Per-request locals (including input, tokens and generated text) die on return.
    from mlx_lm import stream_generate

    request = json.loads(line)
    max_output = request.get("max_tokens", MAX_OUTPUT)
    if (
        isinstance(max_output, bool)
        or not isinstance(max_output, int)
        or not 1 <= max_output <= 1024
    ):
        reply({"ok": False})
        return
    # `user`, when present, is the entire user message (Notes structuring); legacy
    # correction requests carry only `text` and keep the transcript wrapper.
    user = request.get("user")
    if user is None:
        user = "Transcript JSON: " + json.dumps(request["text"], ensure_ascii=False)
    elif not isinstance(user, str):
        reply({"ok": False})
        return
    messages = [
        {"role": "system", "content": request["system"]},
        {"role": "user", "content": user},
    ]
    tokens = tokenizer.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    if len(tokens) + max_output > MAX_CONTEXT:
        reply({"ok": False})
        return
    chunks = []
    last = None
    for last in stream_generate(
        model,
        tokenizer,
        prompt=tokens,
        max_tokens=max_output,
        sampler=sampler,
    ):
        chunks.append(last.text)
    reply(
        {
            "ok": True,
            "text": "".join(chunks).strip(),
            "finish_reason": last.finish_reason if last else "length",
        }
    )


def main():
    # Suppress library diagnostics: neither exception text nor generated text is a log.
    with (
        open(os.devnull, "w") as sink,
        contextlib.redirect_stdout(sink),
        contextlib.redirect_stderr(sink),
    ):
        try:
            from mlx_lm import load
            from mlx_lm.sample_utils import make_sampler

            model, tokenizer = load(sys.argv[1])
            sampler = make_sampler(temp=0)
        except Exception:
            reply({"ready": False})
            return
        reply({"ready": True, "memory_mb": measured_memory_mb()})
        # 0 disables the idle exit (keep_loaded); EOF on stdin still ends the helper.
        idle = float(sys.argv[2])
        while select.select([sys.stdin], [], [], idle + 5 if idle > 0 else None)[0]:
            line = sys.stdin.readline()
            if not line:
                return
            try:
                generate(line, model, tokenizer, sampler)
            except Exception:
                reply({"ok": False})
            finally:
                del line


if __name__ == "__main__":
    main()
