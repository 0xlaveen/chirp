#!/bin/bash
# The whole iOS/iPadOS sweep with one command, ending in a pass/fail table:
#   portable checks -> for an iPhone and an iPad simulator: build, unit tests, then the full UI scheme against a
#   throwaway real chirp-server (simulator-e2e.sh) -> a per-test table, screenshots and logs under one evidence dir.
# Usage: ios/scripts/e2e-all.sh [--skip-portable] [--dark] [--phone-only|--ipad-only] [--keep-devices]
# Env:   CHIRP_E2E_IPHONE / CHIRP_E2E_IPAD   use these simulator UUIDs instead of creating (and deleting) our own
#        CHIRP_E2E_OUT                       evidence dir (default: a new /tmp/chirp-ios-e2e-all.XXXX)
#        CHIRP_TEST_DIAGNOSTICS              never (default) or on-failure; simulator.sh passes it to xcodebuild
#        CHIRP_E2E_PORT                      pin the server port (default: 7899 if free, else the next free pair; never 7821)
# It only ever touches simulators it created (or was given), never a device and never the running Chirp server.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT/ios"
portable=1; dark=0; phone=1; ipad=1; keep=0
for a in "$@"; do
  case "$a" in
    --skip-portable) portable=0 ;;
    --dark) dark=1 ;;
    --phone-only) ipad=0 ;;
    --ipad-only) phone=0 ;;
    --keep-devices) keep=1 ;;
    *) echo "unknown option $a" >&2; sed -n 2,9p "$0" >&2; exit 2 ;;
  esac
done
OUT=${CHIRP_E2E_OUT:-$(mktemp -d /tmp/chirp-ios-e2e-all.XXXX)}
mkdir -p "$OUT"
RESULTS="$OUT/results.tsv"; : > "$RESULTS"
CREATED=""; DEVICE=""; PINNED_PORT=${CHIRP_E2E_PORT:-}
echo "evidence dir: $OUT"
# Build products outside the (possibly TCC-protected) checkout; see simulator.sh.
CHIRP_DERIVED_DATA=${CHIRP_DERIVED_DATA:-${TMPDIR:-/tmp}/chirp-ios-derived-$(printf %s "$ROOT" | cksum | cut -d' ' -f1)}
export CHIRP_DERIVED_DATA
echo "derived data: $CHIRP_DERIVED_DATA"

./scripts/toolchain.sh > "$OUT/toolchain.log" 2>&1 || { cat "$OUT/toolchain.log" >&2; echo "e2e-all: BLOCKED (no full Xcode)" >&2; exit 2; }

# Other agents share this Mac: take 7899 (and 7898 for the clean-up stand-in) when free, else the next free pair.
# Called right before each live stage, not once at the start: another worker can grab the port in between.
pick_port() {
  [ -n "$PINNED_PORT" ] && { CHIRP_E2E_PORT=$PINNED_PORT; export CHIRP_E2E_PORT; return; }
  CHIRP_E2E_PORT=7899
  while lsof -nP -iTCP:"$CHIRP_E2E_PORT" -sTCP:LISTEN >/dev/null 2>&1 || lsof -nP -iTCP:$((CHIRP_E2E_PORT - 1)) -sTCP:LISTEN >/dev/null 2>&1; do
    CHIRP_E2E_PORT=$((CHIRP_E2E_PORT - 10)); [ "$CHIRP_E2E_PORT" -gt 7822 ] || { echo "no free port pair" >&2; return 1; }
  done
  export CHIRP_E2E_PORT
}

# stage NAME CMD...: run, log to $OUT/NAME.log, record PASS/FAIL, keep going.
stage() {
  local name=$1; shift
  printf '== %s\n' "$name"
  # Headless simulator runs flake ("test runner hung before establishing connection"): one retry, noted in the table.
  if "$@" > "$OUT/$name.log" 2>&1; then echo "$name	PASS" >> "$RESULTS"
  elif cp "$OUT/$name.log" "$OUT/$name.try1.log"; rm -rf "$OUT/${name%-live}".xcresult; "$@" > "$OUT/$name.log" 2>&1; then
    echo "$name	PASS (on retry; first try in $name.try1.log)" >> "$RESULTS"
  else echo "$name	FAIL (see $name.log)" >> "$RESULTS"; fi
}

cleanup() {
  [ "$keep" = 1 ] && return
  for d in $CREATED; do xcrun simctl shutdown "$d" >/dev/null 2>&1; xcrun simctl delete "$d" >/dev/null 2>&1; done
}
trap cleanup EXIT INT TERM

# make_device KIND(iPhone|iPad): newest matching device type paired with the newest runtime that supports it.
make_device() {
  local kind=$1; DEVICE=""
  pick=$(python3 - "$kind" <<'PY'
import json, re, subprocess, sys
kind = sys.argv[1]
j = lambda *a: json.loads(subprocess.check_output(["xcrun", "simctl", "list", *a, "--json"]))
types = {t["identifier"]: t["name"] for t in j("devicetypes")["devicetypes"]}
runtimes = [r for r in j("runtimes")["runtimes"] if r.get("isAvailable") and r["identifier"].split(".")[-1].startswith("iOS")]
def ver(r): return tuple(int(x) for x in re.findall(r"\d+", r["version"]))
runtimes.sort(key=ver, reverse=True)
want = r"^iPhone (\d+) Pro$" if kind == "iPhone" else r"^iPad Pro 13-inch \(M(\d+)\)$"
best = None
for r in runtimes:
    cands = [(int(re.match(want, types[t["identifier"]]).group(1)), t["identifier"]) for t in r.get("supportedDeviceTypes", [])
             if t["identifier"] in types and re.match(want, types[t["identifier"]])]
    if cands:
        best = (r["identifier"], max(cands)[1]); break
print(*best) if best else sys.exit("no %s simulator type/runtime" % kind)
PY
  ) || return 1
  # shellcheck disable=SC2086
  set -- $pick
  uuid=$(xcrun simctl create "$kind chirp-e2e-$$" "$2" "$1") || return 1
  CREATED="$CREATED $uuid"
  echo "$kind simulator $uuid: $2 on $1" | tee -a "$OUT/devices.txt"
  DEVICE=$uuid   # a global, not stdout: a $(...) subshell would lose CREATED and leak the simulator
}

# Failing tests, one flow per row, from the xcresult (skips carry their reason).
summarize_bundle() {
  local label=$1 bundle=$2
  [ -d "$bundle" ] || { echo "$label	(no result bundle)" >> "$OUT/tests.tsv"; return; }
  xcrun xcresulttool get test-results tests --path "$bundle" 2>/dev/null > "$OUT/$label-tests.json" || true
  python3 -I - "$label" "$OUT/$label-tests.json" "$bundle" >> "$OUT/tests.tsv" <<'PY'
import json, subprocess, sys
label, path, bundle = sys.argv[1:4]
def skip_reason(ident):
    try:
        out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "test-details", "--path", bundle, "--test-id", ident],
                             capture_output=True, text=True, timeout=60).stdout
        for n in json.loads(out).get("testRuns", []):
            stack = [n]
            while stack:
                x = stack.pop(); stack += x.get("children", [])
                if x.get("name", "").startswith("Test skipped"): return x["name"].split(" - ", 1)[-1]
    except Exception: pass
    return "no reason recorded"
try: data = json.load(open(path))
except Exception: sys.exit(0)
def walk(n, trail):
    t = n.get("nodeType")
    if t == "Test Case":
        res = n.get("result", "?")
        if res == "Skipped": res = "Skipped: " + skip_reason(n.get("nodeIdentifier", ""))
        yield trail[-1] if trail else "", n["name"].rstrip("()"), res
    for c in n.get("children", []):
        yield from walk(c, trail + ([n["name"]] if t in ("Test Suite", "Unit test bundle", "UI test bundle") else []))
for n in data.get("testNodes", []):
    for suite, name, res in walk(n, []): print(f"{label}\t{suite}.{name}\t{res}")
PY
}

run_device() {
  local label=$1 uuid=$2
  xcrun simctl boot "$uuid" 2>/dev/null || true
  xcrun simctl bootstatus "$uuid" -b > "$OUT/$label-boot.log" 2>&1   # a fresh simulator's first boot is slow; do not race it
  stage "$label-build" ./scripts/simulator.sh build "$uuid"
  stage "$label-unit" ./scripts/simulator.sh test "$uuid" -resultBundlePath "$OUT/$label-unit.xcresult"
  summarize_bundle "$label-unit" "$OUT/$label-unit.xcresult"
  pick_port; echo "server port: $CHIRP_E2E_PORT" >> "$OUT/devices.txt"
  CHIRP_E2E_APPEARANCE=$([ "$dark" = 1 ] && echo dark || echo light) \
    stage "$label-ui-live" ./scripts/simulator-e2e.sh "$uuid" -resultBundlePath "$OUT/$label-ui.xcresult"
  summarize_bundle "$label-ui" "$OUT/$label-ui.xcresult"
  if [ -d "$OUT/$label-ui.xcresult" ]; then
    xcrun xcresulttool export attachments --path "$OUT/$label-ui.xcresult" --output-path "$OUT/$label-attachments" >/dev/null 2>&1 || true
  fi
  # simulator-e2e.sh's own verdict includes the "server log has no transcript" privacy check.
  grep -E "privacy: transcript|^[0-9]+$|iOS E2E:" "$OUT/$label-ui-live.log" | tail -3 > "$OUT/$label-privacy.txt" || true
  xcrun simctl shutdown "$uuid" >/dev/null 2>&1 || true
}

: > "$OUT/tests.tsv"
if [ "$portable" = 1 ]; then
  stage portable-check-sources ./scripts/check-sources.sh
  stage portable-shared-tests ./Shared/scripts/test.sh
  stage portable-keyboard-policy swift test --package-path Keyboard/Policy
fi
if [ "$phone" = 1 ]; then
  if [ -n "${CHIRP_E2E_IPHONE:-}" ]; then DEVICE=$CHIRP_E2E_IPHONE; else make_device iPhone; fi
  [ -n "$DEVICE" ] && run_device iphone "$DEVICE" || echo "iphone	FAIL (no simulator)" >> "$RESULTS"
fi
if [ "$ipad" = 1 ]; then
  if [ -n "${CHIRP_E2E_IPAD:-}" ]; then DEVICE=$CHIRP_E2E_IPAD; else make_device iPad; fi
  [ -n "$DEVICE" ] && run_device ipad "$DEVICE" || echo "ipad	FAIL (no simulator)" >> "$RESULTS"
fi

echo; echo "================ iOS E2E sweep ================"
column -t -s "$(printf '\t')" "$RESULTS"
echo; echo "---- per test (PASS / SKIP with reason in the xcresult / FAIL) ----"
column -t -s "$(printf '\t')" "$OUT/tests.tsv"
echo; echo "evidence: $OUT  (*.log, *.xcresult, *-attachments/ screenshots, *-tests.json)"
if grep -q "FAIL" "$RESULTS" || grep -q "Failed" "$OUT/tests.tsv"; then echo "iOS E2E SWEEP: FAIL"; exit 1; fi
echo "iOS E2E SWEEP: PASS"
