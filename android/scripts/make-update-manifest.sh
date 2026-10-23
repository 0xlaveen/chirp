#!/bin/bash
# Stages a signed release APK and its update manifest for hosting at https://<mac>.<tailnet>.ts.net/chirp-apk/.
# Writes <out>/chirp-<versionName>.apk and <out>/latest.json (APK first, manifest last, so a reader never sees a
# manifest without its file). It hosts nothing: point your static file server / `tailscale serve` at <out>.
#   usage: scripts/make-update-manifest.sh [app-release.apk] [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
apk="${1:-app/build/outputs/apk/release/app-release.apk}"
out="${2:-build/chirp-apk}"
[ -f "$apk" ] || { echo "no APK at $apk (run ./gradlew assembleRelease)" >&2; exit 1; }
aapt2="$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)"
[ -n "$aapt2" ] || { echo "aapt2 not found under ANDROID_HOME/build-tools (source the toolchain env)" >&2; exit 1; }
badging="$("$aapt2" dump badging "$apk")"
field() { sed -n "s/^package: \(.* \)\{0,1\}$1='\([^']*\)'.*/\2/p" <<<"$badging" | head -1; }
package="$(field name)"; code="$(field versionCode)"; name="$(field versionName)"
[ "$package" = "dev.chirp.android" ] || { echo "unexpected package '$package'" >&2; exit 1; }
[[ "$code" =~ ^[0-9]+$ && "$name" =~ ^[0-9A-Za-z._-]+$ ]] || { echo "unreadable version in APK" >&2; exit 1; }
"$(dirname "$aapt2")/apksigner" verify "$apk" >/dev/null 2>&1 ||
    { echo "APK is not signed; sign it with the installed app's key before hosting" >&2; exit 1; }
file="chirp-$name.apk"
mkdir -p "$out"
cp "$apk" "$out/$file.tmp" && mv "$out/$file.tmp" "$out/$file"
sha="$(shasum -a 256 "$out/$file" | cut -d' ' -f1)"
size="$(wc -c <"$out/$file" | tr -d ' ')"
printf '{"version_code":%s,"version_name":"%s","file":"%s","sha256":"%s","size":%s}\n' "$code" "$name" "$file" "$sha" "$size" >"$out/latest.json.tmp"
mv "$out/latest.json.tmp" "$out/latest.json"
echo "staged $file (version $name, code $code, $size bytes) and latest.json in $out"
