#!/bin/sh
# Only explicit, available simulator UUIDs are accepted. Never installs on devices.
set -eu
cd "$(dirname "$0")/.."
action="${1:-}"
device="${2:-}"
case "$action" in build|test|ui) ;; *) echo 'Usage: simulator.sh build|test|ui SIMULATOR-UUID' >&2; exit 2;; esac
./scripts/toolchain.sh >/dev/null
CHIRP_SIMULATOR_UUID="$device" xcrun simctl list devices available --json | CHIRP_SIMULATOR_UUID="$device" python3 -c '
import json,os,re,sys
uid=os.environ["CHIRP_SIMULATOR_UUID"]
if not re.fullmatch(r"[A-Fa-f0-9-]{36}",uid): sys.exit("Explicit simulator UUID required")
matches=[d for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["udid"]==uid and d.get("isAvailable")]
if len(matches)!=1 or not matches[0]["name"].startswith(("iPhone", "iPad")): sys.exit("Choose an available iPhone or iPad simulator UUID")
'
python3 scripts/generate-project.py
scheme=ChirpIOS
operation=build
if [ "$action" = test ]; then operation=test; fi
if [ "$action" = ui ]; then operation=test; scheme=ChirpIOS-UI; fi
# Simulator-only ad-hoc signing retains App Group/shared-Keychain entitlements.
# No development team, Apple ID, provisioning update or physical device is used.
# Compare with CHIRP_SIMULATOR_SIGNING=unsigned to diagnose entitlement failures;
# the host fixture reports a precise skip if shared storage cannot be opened.
case "${CHIRP_SIMULATOR_SIGNING:-adhoc}" in
  adhoc) set -- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ;;
  unsigned) set -- CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ;;
  *) echo 'CHIRP_SIMULATOR_SIGNING must be adhoc or unsigned' >&2; exit 2 ;;
esac
exec xcodebuild -project Chirp.xcodeproj -scheme "$scheme" -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$device" \
  -parallel-testing-enabled NO \
  -derivedDataPath DerivedData "$@" \
  "$operation"
