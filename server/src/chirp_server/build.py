"""What this server is: version, commit, API level and capabilities.

Clients compare it with what they expect, to tell when the process on the port is older than they
are. Metadata only: no text, audio, tokens or URLs.
"""

import functools
import os
import subprocess
import time
from importlib import metadata
from pathlib import Path

# Bump when a client starts needing something an older server lacks (the Mac app compares it).
API_LEVEL = 2
# Authenticated-health feature flags a client may require (each also stays a boolean `notes_*` key).
CAPABILITIES = (
    "notes_structure",
    "notes_correction",
    "notes_reorganize",
    "notes_context",
    "notes_retranscribe",
    "notes_edit",
    "notes_speakers",
    # `GET/POST /v1/speakers/voices` and `final.speakers.matches` (saved voices, #247).
    "speaker_voices",
)
# Written next to the code by scripts/install-mac.sh, whose copy has no .git to ask.
COMMIT_FILE = "BUILD_COMMIT"

PACKAGE = Path(__file__).resolve().parent
STARTED_AT = int(time.time())


def version() -> str:
    try:
        return metadata.version("chirp-server")
    except metadata.PackageNotFoundError:
        return "0.0.0"


@functools.cache
def commit() -> str | None:
    """Short commit of the code this process runs: the installer's file, else git HEAD."""
    try:
        written = (PACKAGE / COMMIT_FILE).read_text().strip()
        if written:
            return written[:12]
    except OSError:
        pass
    try:
        result = subprocess.run(
            ["git", "-C", str(PACKAGE), "rev-parse", "--short=12", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    out = result.stdout.strip()
    return out if result.returncode == 0 and out else None


def source() -> str:
    """The server directory this process runs from, with the home folder shortened to ~."""
    path = str(PACKAGE.parents[1])
    home = str(Path.home())
    return "~" + path[len(home) :] if path == home or path.startswith(home + os.sep) else path


def info() -> dict:
    return {
        "version": version(),
        "commit": commit(),
        "api": API_LEVEL,
        "capabilities": list(CAPABILITIES),
        "started_at": STARTED_AT,
        "pid": os.getpid(),
        "source": source(),
    }
