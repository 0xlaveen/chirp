#!/bin/sh
# Creates a self-signed code-signing identity "Chirp Local Dev" in your login keychain.
# Signing every build with the same identity keeps macOS Microphone/Accessibility (TCC) grants
# across rebuilds; an ad-hoc signature changes on every build and resets them.
#
# Operator steps: run this once. macOS may ask for your login password when the certificate is
# imported and trusted for code signing. Nothing leaves your machine and nothing is written to the repo.
set -eu

NAME="Chirp Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SSL=/usr/bin/openssl   # LibreSSL: its .p12 files import cleanly (OpenSSL 3 needs -legacy)

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "Identity \"$NAME\" already exists:"
    security find-identity -p codesigning | grep "\"$NAME\""
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=$(uuidgen)

cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$SSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
"$SSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
    -out "$tmp/id.p12" -passout "pass:$pass"

security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign
# Trust the certificate for code signing (shows a macOS authentication prompt).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"

echo
echo "Created \"$NAME\":"
security find-identity -p codesigning | grep "\"$NAME\"" || true
echo "The first codesign may ask to allow keychain access: choose \"Always Allow\"."
