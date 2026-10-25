"""Private JSON-line helper. Model work stays on this process's main thread."""

import argparse
import contextlib
import json
import os
import queue
import sys
import threading

MAX_CONTEXT = 4096
MAX_OUTPUT = 512


def measured_memory_mb() -> int | None:
    """RSS estimate: bytes on Darwin, KiB on Linux. Windows keeps the catalog estimate."""
    try:
        import resource
    except ImportError:
        return None
    total = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform != "darwin":
        total *= 1024
    try:
        import mlx.core as mx

        total += mx.metal.get_active_memory()
    except Exception:
        pass
    return round(total / 1048576)


def reply(payload):
    sys.__stdout__.write(json.dumps(payload) + "\n")
    sys.__stdout__.flush()


def request_fields(line):
    request = json.loads(line)
    maximum = request.get("max_tokens", MAX_OUTPUT)
    if type(maximum) is not int or not 1 <= maximum <= 1024:
        raise ValueError("Invalid output limit")
    user = request.get("user")
    if user is None:
        user = "Transcript JSON: " + json.dumps(request["text"], ensure_ascii=False)
    if not isinstance(user, str) or not isinstance(request["system"], str):
        raise ValueError("Invalid request")
    return maximum, [
        {"role": "system", "content": request["system"]},
        {"role": "user", "content": user},
    ]


def generate(line, model, tokenizer, sampler):
    """Existing MLX generation contract, including its exact token/context budget."""
    from mlx_lm import stream_generate

    try:
        maximum, messages = request_fields(line)
    except (ValueError, TypeError, KeyError):
        reply({"ok": False})
        return
    tokens = tokenizer.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    if len(tokens) + maximum > MAX_CONTEXT:
        reply({"ok": False})
        return
    chunks = []
    last = None
    for last in stream_generate(
        model, tokenizer, prompt=tokens, max_tokens=maximum, sampler=sampler
    ):
        chunks.append(last.text)
    reply(
        {
            "ok": True,
            "text": "".join(chunks).strip(),
            "finish_reason": last.finish_reason if last else "length",
        }
    )


def generate_llama(line, model):
    maximum, messages = request_fields(line)
    # The pinned Qwen Instruct GGUF uses ChatML. Build the exact prompt so token
    # counting and generation use the same framing and cannot silently truncate Notes.
    prompt = "".join(f"<|im_start|>{m['role']}\n{m['content']}<|im_end|>\n" for m in messages)
    prompt += "<|im_start|>assistant\n"
    tokens = model.tokenize(prompt.encode(), add_bos=False, special=True)
    if len(tokens) + maximum > MAX_CONTEXT:
        reply({"ok": False})
        return
    result = model.create_completion(
        prompt=tokens, max_tokens=maximum, temperature=0, stop=["<|im_end|>"], echo=False
    )
    choice = result["choices"][0]
    reply({"ok": True, "text": choice["text"].strip(), "finish_reason": choice["finish_reason"]})


def input_lines(stream, idle):
    """Anonymous pipes work on Windows too; select() there accepts only sockets."""
    pending = queue.Queue(maxsize=1)

    def read():
        while True:
            line = stream.readline(256 * 1024 + 1)
            pending.put(line)
            if not line:
                return

    threading.Thread(target=read, daemon=True).start()
    while True:
        try:
            line = pending.get(timeout=idle + 5 if idle > 0 else None)
        except queue.Empty:
            return
        if not line:
            return
        if len(line) > 256 * 1024:
            raise ValueError("Request too large")
        yield line


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=["mlx", "llama_cpp"], default="mlx")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("model")
    parser.add_argument("idle", type=float)
    args = parser.parse_args()
    # Suppress library diagnostics: neither exception text nor generated text is a log.
    with (
        open(os.devnull, "w") as sink,
        contextlib.redirect_stdout(sink),
        contextlib.redirect_stderr(sink),
    ):
        try:
            if args.backend == "llama_cpp":
                from llama_cpp import Llama

                model = Llama(
                    model_path=args.model,
                    n_ctx=MAX_CONTEXT,
                    n_threads=args.threads,
                    n_gpu_layers=0,
                    verbose=False,
                )

                def run(line):
                    generate_llama(line, model)
            else:
                from mlx_lm import load
                from mlx_lm.sample_utils import make_sampler

                model, tokenizer = load(args.model)
                sampler = make_sampler(temp=0)

                def run(line):
                    generate(line, model, tokenizer, sampler)
        except Exception:
            reply({"ready": False})
            return
        reply({"ready": True, "memory_mb": measured_memory_mb()})
        for line in input_lines(sys.stdin, args.idle):
            try:
                run(line)
            except Exception:
                reply({"ok": False})
            finally:
                del line


if __name__ == "__main__":
    main()
