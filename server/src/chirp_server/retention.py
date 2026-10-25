"""The sole audio/transcript disk boundary, invoked only with visible debug opt-in."""

import json
import os
import time

from .audio import wav_bytes
from .config import Settings
from .fsutil import make_private, private_mkdir


class Retention:
    def __init__(self, settings: Settings):
        self.settings = settings

    def purge(self, *, all_files=False):
        directory = self.settings.debug_dir
        if not directory.exists():
            return 0
        count = 0
        cutoff = time.time() - self.settings.retain_days * 86400
        for path in directory.iterdir():
            if path.suffix in {".wav", ".json"} and path.is_file():
                if all_files or path.stat().st_mtime < cutoff:
                    path.unlink()
                    count += 1
        return count

    def save(self, session: str, pcm: bytes, final: dict):
        if not self.settings.debug_retain:
            return
        directory = self.settings.debug_dir
        private_mkdir(directory)
        make_private(directory)
        for suffix, data in [("wav", wav_bytes(pcm)), ("json", json.dumps(final).encode())]:
            fd = os.open(
                directory / f"{session}.{suffix}", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
            )
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
