#!/bin/sh
# CI entry point on GitHub's hosted macOS runners: the portable checks, then build + unit tests of the app
# (which embeds the keyboard and widgets) on one iPhone simulator. Live-server e2e and the UI schemes stay on
# the reference Mac (`simulator-e2e.sh`): they need `say`, ffmpeg, the cached model and a real keyboard setup.
set -eu
cd "$(dirname "$0")/.."
./scripts/check-sources.sh
./Shared/scripts/test.sh
swift test --package-path Keyboard/Policy
# An explicit owned simulator can be supplied for shared-host runs; otherwise use the newest available iPhone.
# Create one for the newest runtime if the image has none.
device=${CHIRP_CI_SIMULATOR:-$(xcrun simctl list devices available --json | python3 -c '
import json,sys
ds=[(r,d["udid"]) for r,l in json.load(sys.stdin)["devices"].items() for d in l if d["name"].startswith("iPhone") and d.get("isAvailable")]
print(sorted(ds)[-1][1] if ds else "")')}
if [ -z "$device" ]; then
    runtime=$(xcrun simctl list runtimes available --json | python3 -c '
import json,sys
print([r["identifier"] for r in json.load(sys.stdin)["runtimes"] if r["identifier"].split(".")[-1].startswith("iOS")][-1])')
    type=$(xcrun simctl list devicetypes --json | python3 -c '
import json,sys
print([t["identifier"] for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("iPhone")][-1])')
    device=$(xcrun simctl create chirp-ci "$type" "$runtime")
fi
echo "Simulator: $device"
./scripts/simulator.sh test "$device" -skipPackagePluginValidation -skipMacroValidation "$@"
