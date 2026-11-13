#!/bin/bash
# Creates a self-signed code-signing certificate named "Segue Local Signing" in your login
# keychain, so macOS keeps Segue's permissions across rebuilds. Run once. macOS may ask for
# your login password, and will ask again the first time codesign uses the key.
#
# Not yet tested end to end. If it fails, Segue still builds and runs with ad hoc signing.
set -euo pipefail

IDENTITY="Segue Local Signing"
# The system OpenSSL (LibreSSL) writes a .p12 that `security import` accepts; OpenSSL 3's default does not.
OPENSSL=/usr/bin/openssl

IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if [[ "$IDENTITIES" == *"$IDENTITY"* ]]; then
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

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -out "$WORK/identity.p12" -passout pass:segue
security import "$WORK/identity.p12" -k ~/Library/Keychains/login.keychain-db \
    -P segue -T /usr/bin/codesign

# Prove the identity can actually sign before claiming success.
cp /usr/bin/true "$WORK/selftest"
if codesign --force --sign "$IDENTITY" "$WORK/selftest" 2>/dev/null; then
    echo "Created \"$IDENTITY\". Rebuild with scripts/build-app.sh."
else
    echo "The certificate was imported, but codesign can't use it yet." >&2
    echo "Open Keychain Access, find \"$IDENTITY\", and set Trust > Code Signing to Always Trust." >&2
    exit 1
fi
