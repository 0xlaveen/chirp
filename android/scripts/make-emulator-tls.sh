#!/bin/sh
# An ephemeral test CA/server key, generated only under debug build output.
set -eu
cd "$(dirname "$0")/.."
target=app/build/generated/chirp-debug-res/raw
key=app/build/emulator-tls/key.pem
mkdir -p "$target" app/build/emulator-tls
if [ ! -s "$target/emulator_ca.pem" ] || [ ! -s "$key" ] || ! openssl x509 -checkend 3600 -noout -in "$target/emulator_ca.pem" >/dev/null 2>&1; then
    umask 077
    cat > app/build/emulator-tls/openssl.cnf <<'CONFIG'
[req]
distinguished_name = dn
x509_extensions = extensions
prompt = no
[dn]
CN = Chirp disposable emulator
[extensions]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = IP:10.0.2.2,IP:127.0.0.1
CONFIG
    openssl req -x509 -newkey rsa:2048 -nodes -days 7 -config app/build/emulator-tls/openssl.cnf \
        -keyout "$key" -out "$target/emulator_ca.pem" >/dev/null 2>&1
fi
