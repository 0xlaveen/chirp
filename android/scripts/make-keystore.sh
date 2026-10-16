#!/bin/bash
# Local development signing only. Never use this key for Play Store distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p keystore
if [ ! -f keystore/local-debug.keystore ]; then
    keytool -genkeypair -keystore keystore/local-debug.keystore -storepass android \
        -alias androiddebugkey -keypass android -keyalg RSA -keysize 3072 -validity 10000 \
        -dname 'CN=Chirp Local Development,O=Chirp,C=US' -noprompt
fi
