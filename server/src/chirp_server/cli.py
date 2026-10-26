"""Local CLI. Pairing is the only command that deliberately prints a credential."""

import argparse
import json
import logging
import os
import plistlib
import subprocess
import sys
import time
from dataclasses import replace
from pathlib import Path
from urllib.parse import urlencode, urlsplit

from .config import Settings, load_token
from .devices import DeviceStore
from .retention import Retention

LABEL = "dev.chirp.server"


def onnx_thread_count(value):
    value = int(value)
    if not 0 <= value <= 2**31 - 1:
        raise argparse.ArgumentTypeError("must be an integer between 0 and 2147483647")
    return value


def service(action, arguments=()):
    destination = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
    target = f"gui/{os.getuid()}"
    if action == "uninstall":
        subprocess.run(
            ["launchctl", "bootout", target + "/" + LABEL],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        destination.unlink(missing_ok=True)
        return
    # Explicit user command only; never called on server startup.
    executable = str(Path(sys.executable).absolute())
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as stream:
        plistlib.dump(
            {
                "Label": LABEL,
                "ProgramArguments": [executable, "-m", "chirp_server", *arguments],
                "RunAtLoad": True,
                "KeepAlive": True,
                "EnvironmentVariables": {"PYTHONUNBUFFERED": "1"},
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": "/dev/null",
            },
            stream,
        )
    # bootstrap fails when the label is already loaded. Boot out first so re-running install
    # updates an existing agent instead of failing; launchd may briefly reject the new
    # bootstrap while the bootout settles, so retry as setup.restart does.
    subprocess.run(
        ["launchctl", "bootout", target + "/" + LABEL],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    for attempt in range(3):
        result = subprocess.run(
            ["launchctl", "bootstrap", target, str(destination)],
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            break
        if attempt == 2:
            raise SystemExit("Could not install the LaunchAgent; check Console for launchd errors")
        time.sleep(0.5)


def pair_uri(url, token):
    parts = urlsplit(url)
    if (
        parts.scheme not in {"http", "https"}
        or not parts.hostname
        or parts.username
        or parts.password
    ):
        raise ValueError("Pair URL must be an HTTP(S) base URL without credentials")
    return "chirp://pair?" + urlencode({"url": url, "token": token})


def devices(store, args):
    if args.action == "revoke":
        try:
            device = store.revoke(args.device)
        except LookupError as exc:
            raise SystemExit(str(exc)) from None
        print(f"Revoked {device['name']} ({device['id']})")
        return
    entries = store.entries(args.all)
    if args.json:
        print(json.dumps({"devices": entries}, ensure_ascii=False))
        return
    if not entries:
        print("No paired devices; the shared token is accepted until rotated")
        return
    columns = ["id", "name", "created", "last_seen"] + (["revoked"] if args.all else [])
    rows = [[c.upper().replace("_", " ") for c in columns]]
    rows += [
        [(entry[c] or "never") if c == "last_seen" else (entry[c] or "") for c in columns]
        for entry in entries
    ]
    widths = [max(len(row[i]) for row in rows) for i in range(len(columns))]
    for row in rows:
        print(
            "  ".join(cell.ljust(width) for cell, width in zip(row, widths, strict=True)).rstrip()
        )


def voices(library, args):
    """Saved voices for a user at this machine: names print here, never into a log."""
    from .voices import VoiceError

    if args.action in {"list", "forget-all", "off", "on"} and args.voice is not None:
        raise SystemExit(f"voices {args.action} takes no name")
    if args.action == "forget":
        if args.voice is None:
            raise SystemExit("voices forget needs a name or id")
        listed = library.listing()["voices"]
        key = args.voice.strip()
        found = [v for v in listed if v["id"] == key] or [
            v for v in listed if v["name"].casefold() == key.casefold()
        ]
        if not found:
            raise SystemExit("No saved voice has that name or id")
        if len(found) > 1:
            raise SystemExit("Several saved voices have that name; forget one by its id")
        try:
            library.forget(found[0]["id"])
        except VoiceError:
            raise SystemExit("No saved voice has that name or id") from None
        print(f"Forgot {found[0]['name']} ({found[0]['id']})")
        return
    if args.action == "forget-all":
        library.forget_all()
        print("Forgot all saved voices")
        return
    if args.action == "off":
        library.disable(args.forget)
        print("Remember voices is off" + ("; saved voices forgotten" if args.forget else ""))
        return
    if args.action == "on":
        library.enable()
        print("Remember voices is on")
        return
    listing = library.listing()
    if args.json:
        print(json.dumps(listing, ensure_ascii=False))
        return
    print(f"Remember voices: {'on' if listing['enabled'] else 'off'} ({library.store.path})")
    if not listing["voices"]:
        print("No saved voices")
        return
    rows = [["ID", "NAME", "SECONDS", "CREATED", "UPDATED", ""]]
    rows += [
        [
            v["id"],
            v["name"],
            f"{v['seconds']:.0f}",
            v["created"],
            v["updated"],
            "" if v["compatible"] else "other model: name them again",
        ]
        for v in listing["voices"]
    ]
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    for row in rows:
        print(
            "  ".join(cell.ljust(width) for cell, width in zip(row, widths, strict=True)).rstrip()
        )


def parser():
    result = argparse.ArgumentParser(description="Private local streaming dictation")
    result.add_argument("--config", type=Path)
    result.add_argument("--model-dir", type=Path)
    result.add_argument("--engine", choices=["mlx", "onnx", "sensevoice"], default=None)
    result.add_argument("--sensevoice-num-threads", type=int, default=None)
    for kind in ("intra", "inter"):
        result.add_argument(
            f"--onnx-{kind}-op-num-threads",
            type=onnx_thread_count,
            default=None,
            help=f"Parakeet ONNX {kind}-op threads: 0=automatic; omitted=use config/default",
        )
    result.add_argument(
        "--precision", choices=["float32", "float16", "bfloat16"], default="float32"
    )
    result.add_argument("--streaming", choices=["incremental", "rolling"], default="rolling")
    result.add_argument("--finalization", choices=["full", "segments"], default="full")
    result.add_argument("--debug-retain", action="store_true")
    result.add_argument("--port", type=int, default=7821)
    result.add_argument("--root-path", default="")
    commands = result.add_subparsers(dest="command")
    pair = commands.add_parser("pair")
    pair.add_argument("--url", default="http://127.0.0.1:7821")
    pair.add_argument("--name", help="mint a revocable token for this device (else the shared one)")
    paired = commands.add_parser("devices", help="list or revoke device tokens")
    paired.add_argument("action", choices=["list", "revoke"])
    paired.add_argument("device", nargs="?", help="name or id to revoke")
    paired.add_argument("--all", action="store_true", help="include revoked devices")
    paired.add_argument("--json", action="store_true")
    saved = commands.add_parser("voices", help="list or forget saved voices, or turn them off")
    saved.add_argument("action", choices=["list", "forget", "forget-all", "off", "on"])
    saved.add_argument("voice", nargs="?", help="name or id to forget")
    saved.add_argument("--forget", action="store_true", help="with off: also forget every voice")
    saved.add_argument("--json", action="store_true")
    model = commands.add_parser("model")
    model.add_argument("action", choices=["fetch"])
    model.add_argument("--engine", choices=["mlx", "onnx", "sensevoice"], default=argparse.SUPPRESS)
    model.add_argument("--cleanup", nargs="?", const="", default=None, metavar="ID")
    model.add_argument(
        "--speakers", action="store_true", help="the Live Notes speaker-label model (27 MB)"
    )
    debug = commands.add_parser("debug")
    debug.add_argument("action", choices=["purge"])
    check = commands.add_parser("doctor")
    check.add_argument("--quick", action="store_true", help="skip the real model load and decode")
    launch = commands.add_parser("service")
    launch.add_argument("action", choices=["install", "uninstall"])
    setup = commands.add_parser("setup", help="local Mac setup with JSON progress")
    setup.add_argument(
        "action",
        choices=["status", "download", "start", "refresh", "add", "select", "restart", "replace"],
    )
    setup.add_argument("--model", choices=["speech", "cleanup"], default="speech")
    setup.add_argument("--choice", help="catalog id (including its pinned revision)")
    setup.add_argument("--repository", help="Hugging Face owner/repository for add")
    return result


def main():
    args = parser().parse_args()
    if args.command == "setup":
        from .setup import run

        raise SystemExit(
            run(args.action, args.model, args.config, args.port, args.choice, args.repository)
        )
    if args.command == "doctor":
        from .doctor import doctor

        # Read-only diagnostics run before config parsing so a broken config is reported,
        # not raised.
        raise SystemExit(doctor(args))
    settings = Settings.read(args.config)
    if args.command == "pair":
        import segno

        try:
            pair_uri(args.url, "")  # validate before minting anything
            if args.name is None:
                token = load_token(settings.config_dir)
            else:
                device, token = DeviceStore(settings.config_dir).mint(args.name)
        except ValueError as exc:
            raise SystemExit(str(exc)) from None
        uri = pair_uri(args.url, token)
        print(uri)
        segno.make(uri).terminal(compact=True)
        if args.name is not None:
            print(
                f"Paired {device['name']} ({device['id']}); "
                f"revoke with: chirp-server devices revoke {device['id']}",
                file=sys.stderr,
            )
    elif args.command == "devices":
        if (args.action == "revoke") != (args.device is not None):
            raise SystemExit("devices revoke needs exactly one name or id; list takes none")
        try:
            devices(DeviceStore(settings.config_dir), args)
        except ValueError as exc:
            raise SystemExit(str(exc)) from None
    elif args.command == "voices":
        from .voices import VoiceLibrary

        try:
            voices(VoiceLibrary(), args)
        except ValueError as exc:
            raise SystemExit(f"{exc}; `chirp-server voices forget-all` deletes it") from None
    elif args.command == "model":
        if args.speakers:
            from .speakers_model import fetch

            print(fetch())
        elif args.cleanup is not None:
            from .cleanup_models import fetch

            print(fetch(args.cleanup or settings.correction.model))
        else:
            from .engine.models import fetch

            print(fetch(args.engine or settings.engine))
    elif args.command == "debug":
        print(f"Purged {Retention(settings).purge(all_files=True)} debug files")
    elif args.command == "service":
        forwarded = ["--port", str(args.port)] if args.port != 7821 else []
        forwarded += ["--root-path", args.root_path] if args.root_path else []
        from .service import backend

        if args.action == "install":
            backend().install(forwarded)
        else:
            backend().uninstall()
    else:
        import uvicorn

        from .app import accept_prefix, create_app

        if args.engine is not None:
            if settings.engine == "sensevoice" and args.engine != "sensevoice":
                from .model_catalog import apply_settings

                settings.speech_model = "parakeet-v2"
                apply_settings(settings)
            settings.engine = args.engine
        if settings.engine == "sensevoice":
            settings.model_dir = None
            settings.speech_model = "sensevoice-small"
        if args.model_dir is not None:
            settings.model_dir = args.model_dir
        if args.sensevoice_num_threads is not None:
            settings.sensevoice_num_threads = args.sensevoice_num_threads
        settings.precision = args.precision
        settings.streaming = args.streaming
        settings.finalization = args.finalization
        settings.onnx = replace(
            settings.onnx,
            **{
                f"{kind}_op_num_threads": value
                for kind in ("intra", "inter")
                if (value := getattr(args, f"onnx_{kind}_op_num_threads")) is not None
            },
        )
        settings.debug_retain |= args.debug_retain
        logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
        # httpx logs can contain endpoint queries/credentials; library logs are not diagnostics.
        logging.getLogger("httpx").setLevel(logging.WARNING)
        logging.getLogger("httpcore").setLevel(logging.WARNING)
        try:
            uvicorn.run(
                accept_prefix(create_app(settings), args.root_path),
                host="127.0.0.1",
                port=args.port,
                root_path=args.root_path,
                access_log=False,
                ws_max_size=999999,
                proxy_headers=False,
            )
        except Exception:
            # Model/config exceptions may contain paths or data; print only a safe diagnosis.
            raise SystemExit(
                "Server startup failed; check configuration and cached model"
            ) from None
