"""Private JSON-line helper. MLX loads and generates on this process's main thread."""

import contextlib
import json
import select
import sys

MAX_CONTEXT = 4096
MAX_OUTPUT = 512


def reply(payload):
    sys.__stdout__.write(json.dumps(payload) + "\n")
    sys.__stdout__.flush()


def generate(line, model, tokenizer, sampler):
    # Per-request locals (including input, tokens and generated text) die on return.
    from mlx_lm import stream_generate

    request = json.loads(line)
    messages = [
        {"role": "system", "content": request["system"]},
        {"role": "user", "content": "Transcript JSON: " + json.dumps(request["text"])},
    ]
    tokens = tokenizer.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    if len(tokens) + MAX_OUTPUT > MAX_CONTEXT:
        reply({"ok": False})
        return
    chunks = []
    last = None
    for last in stream_generate(
        model,
        tokenizer,
        prompt=tokens,
        max_tokens=MAX_OUTPUT,
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
        open("/dev/null", "w") as sink,
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
        reply({"ready": True})
        while select.select([sys.stdin], [], [], float(sys.argv[2]) + 5)[0]:
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
