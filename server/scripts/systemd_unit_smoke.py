"""Check the Linux unit parser without installing anything or starting a service."""

import subprocess
import tempfile
from pathlib import Path

from chirp_server.service import systemd

with tempfile.TemporaryDirectory(prefix="chirp-systemd-check-") as temporary:
    unit = Path(temporary) / systemd.UNIT
    unit.write_text(systemd.render(["--port", "18999", "--root-path", "/chirp"]))
    result = subprocess.run(
        ["systemd-analyze", "verify", str(unit)], capture_output=True, timeout=15
    )
    assert result.returncode == 0, "systemd rejected the generated unit"
    print("systemd: generated user unit parsed successfully; no service installed")
