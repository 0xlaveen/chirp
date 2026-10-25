# Chirp on Linux

Chirp runs its speech server on a Linux PC or box and pairs with the desktop,
Android and iOS clients using the same v1 protocol. Speech and managed cleanup
stay on that machine. The shared desktop client supports dictation and a local
Live Notes library. X11 uses a single-key hold; Wayland uses an approved Global
Shortcuts portal binding. See [desktop setup and Notes](../desktop/README.md).

## Speech server

Install Python 3.13 and [uv](https://docs.astral.sh/uv/), clone this repository,
and work from `server/`:

```sh
uv sync --locked --extra onnx
uv run chirp-server model fetch
uv run chirp-server
```

Linux defaults to the quantized ONNX Parakeet model on CPU. Model acquisition is
an explicit command; starting the server never downloads weights. It binds to
loopback on port 7821. For another port use `--port 7899`.

The paths follow XDG:

| Data | Default |
|---|---|
| Preferences and token | `~/.config/chirp/` (`XDG_CONFIG_HOME/chirp`) |
| Models and server state | `~/.local/share/chirp/` (`XDG_DATA_HOME/chirp`) |
| Cache | `~/.cache/chirp/` (`XDG_CACHE_HOME/chirp`) |

Token files are private to the owner. The foreground server does not log spoken
words. Debug audio/text retention remains off unless explicitly enabled.

An optional `[onnx] providers = "cuda"` in `server.toml` opts in to CUDA when a
compatible ONNX Runtime GPU build and drivers are installed. CPU is the default
and the fallback when an accelerator is unavailable. Do not install both CPU
and GPU ONNX Runtime packages into the same environment. `chirp-server doctor`
reports the runtime, providers and model readiness.

## Cleanup and smart notes

Cleanup is off by default. Choose either the managed local model or a local
OpenAI-compatible endpoint. Both use the existing correction/Notes safety
checks; a timeout, failed generation or rejected rewrite preserves the original.

For managed CPU cleanup, install the optional runtime and explicitly fetch the
pinned Qwen3 4B Instruct GGUF:

```sh
uv sync --locked --extra onnx --extra cleanup
uv run chirp-server model fetch --cleanup qwen3-4b-instruct-2507-q4-k-m-gguf
```

Set `~/.config/chirp/server.toml`:

```toml
[correction]
mode = "managed"
backend = "llama_cpp"
model = "qwen3-4b-instruct-2507-q4-k-m-gguf"
llama_threads = 4
```

The portable default budgets are 30 seconds for dictation cleanup, 45 for Notes
segment cleanup, 90 for structuring and 120 for reorganizing. Explicit values in
`server.toml` override them. A synthetic Linux arm64 container check observed
18.8 seconds for a cold cleanup and 20.4 seconds for structuring; these are shared
host observations, not latency targets. Native Apple Silicon and endpoint budgets
keep their existing defaults.

The helper loads the local GGUF, serves dictation and Notes through private
pipes, and unloads after the configured idle time. No transcript enters its
command line. Building llama-cpp-python from source needs a C/C++ compiler and
CMake. Intel Mac and Windows use the same portable backend; native Apple Silicon
keeps the existing MLX backend and model choices.

For Ollama, LM Studio or another local OpenAI-compatible service, use the model
name exposed by that service (prefer a Qwen Instruct model):

```toml
[correction]
mode = "endpoint"
base_url = "http://127.0.0.1:11434/v1"
model = "your-local-model-name"
```

LM Studio commonly uses port 1234 instead. A non-loopback endpoint sends final
text to that host; authenticated health reports this to clients. Audio is never
sent to the cleanup endpoint.

## User service

From the installed server environment, explicitly install a systemd user unit:

```sh
uv run chirp-server service install
systemctl --user status dev.chirp.server.service
```

It starts at user login, uses a private file umask and restarts after a crash.
It preserves the selected server arguments and never rewrites `server.toml`.
It refuses to overwrite an unrelated unit at the same path. On machines without
a systemd user manager, run the server in a terminal or use your own supervisor.
To serve phones after logout, an administrator may need to enable lingering for
your account; Chirp does not change that policy.

```sh
uv run chirp-server service uninstall
```

For a service on another port, put `--port` before `service install`:
`uv run chirp-server --port 7899 service install`.

## Pair clients

Use a local desktop connection, or publish the loopback server through Tailscale
Serve for your own devices (never Funnel):

```sh
tailscale serve --bg --set-path /chirp http://127.0.0.1:7821
uv run chirp-server pair --url https://YOUR-SERVER.YOUR-TAILNET.ts.net/chirp
```

The pairing link contains a secret. Paste it directly into the client’s pairing
field. See [desktop/README.md](../desktop/README.md) for Linux build/install,
Right Alt/Right Ctrl defaults, tray controls, X11 insertion and current Wayland
limits. Phone clients keep their existing pairing flow.

## Linux validation from a Mac

With Docker, cached ONNX weights and macOS `say`/ffmpeg installed:

```sh
server/scripts/linux-container-smoke.sh
```

The harness generates synthetic English speech, snapshots source outside
Documents, copies weights into a disposable Linux arm64 container and runs the
unit suite, a real ONNX server on a free port, and real GGUF cleanup/Notes. It
retains the stopped container and prints its evidence path. It never mounts the
host home, connects to the live server, opens a microphone, or starts an emulator.
The GGUF smoke explicitly downloads the pinned public model inside the container.

Desktop checks run separately under Xvfb; see the desktop README. Headless
container tests validate systemd unit contents and command handling, not a
machine’s actual logon manager or physical microphone.
