#!/bin/sh
# Build the stable public candidate outside the repository; no git remote is created.
set -eu
CHIRP_FLUID_CACHE="$HOME/Library/Caches/Chirp/FluidAudio-0.17.7"
mkdir -p "$CHIRP_FLUID_CACHE"
curl -fsSL https://codeload.github.com/FluidInference/FluidAudio/tar.gz/refs/tags/v0.17.7 -o "$CHIRP_FLUID_CACHE/source.tar.gz"
tar -xzf "$CHIRP_FLUID_CACHE/source.tar.gz" -C "$CHIRP_FLUID_CACHE" --strip-components=1
swift build --package-path "$CHIRP_FLUID_CACHE" --disable-default-traits -c release --product fluidaudiocli
