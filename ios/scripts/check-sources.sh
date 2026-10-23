#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/generate-project.py
python3 scripts/check-project.py
plutil -lint Config/*.plist Config/*.entitlements Chirp.xcodeproj/project.pbxproj
python3 - <<'PY'
import json,subprocess
from pathlib import Path
membership=json.loads(Path('Chirp.xcodeproj/source-membership.json').read_text())
for target,files in membership.items():
    subprocess.run(['swiftc','-frontend','-parse',*files],check=True)
    print(f'PASS: Swift syntax for {target} ({len(files)} sources); no iOS typechecking claimed')
PY
for f in scripts/toolchain.sh scripts/simulator.sh scripts/simulator-e2e.sh scripts/check-sources.sh; do sh -n "$f"; done
python3 -m py_compile scripts/generate-project.py scripts/check-project.py scripts/fake-cleanup.py
