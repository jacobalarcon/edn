#!/bin/bash
set -euo pipefail

IDENTITY_NAME="EDN Local Development"
LOGIN_KEYCHAIN="$(security default-keychain -d user | tr -d ' "')"

if security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "$IDENTITY_NAME is already available."
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
P12_PASSWORD="$(openssl rand -hex 24)"

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -subj "/CN=$IDENTITY_NAME/O=EDN Local Development" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$WORK_DIR/key.pem" \
    -out "$WORK_DIR/certificate.pem" >/dev/null 2>&1

openssl pkcs12 -export \
    -legacy \
    -inkey "$WORK_DIR/key.pem" \
    -in "$WORK_DIR/certificate.pem" \
    -name "$IDENTITY_NAME" \
    -passout "pass:$P12_PASSWORD" \
    -out "$WORK_DIR/identity.p12"

security import "$WORK_DIR/identity.p12" \
    -k "$LOGIN_KEYCHAIN" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign >/dev/null
security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$LOGIN_KEYCHAIN" \
    "$WORK_DIR/certificate.pem"

security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" | grep -F "$IDENTITY_NAME" >/dev/null
echo "Created $IDENTITY_NAME in $LOGIN_KEYCHAIN."
