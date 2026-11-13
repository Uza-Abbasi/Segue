#!/bin/bash
# Creates a self-signed code-signing certificate named "Segue Local Signing" in your login
# keychain, so macOS keeps Segue's permissions across rebuilds. Run once. macOS may ask for
# your login password, and will ask again the first time codesign uses the key.
set -euo pipefail

IDENTITY="Segue Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "\"$IDENTITY\" already exists."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -out "$WORK/identity.p12" -passout pass:segue
security import "$WORK/identity.p12" -k ~/Library/Keychains/login.keychain-db \
    -P segue -T /usr/bin/codesign

echo "Created \"$IDENTITY\". Rebuild with scripts/build-app.sh."
