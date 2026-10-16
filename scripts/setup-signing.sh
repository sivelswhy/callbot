#!/bin/bash
# Create a local, self-signed code signing identity ("PhoneBT Local Signing") in the login
# keychain. build-app.sh signs with it when present: macOS then keeps the app's permissions
# (Accessibility, microphone…) across rebuilds, instead of revoking them after each ad hoc build.
# Run once; macOS asks for your password to trust the certificate for code signing.
set -euo pipefail

NAME="PhoneBT Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✅ \"$NAME\" already exists"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:phonebt 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:phonebt

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P phonebt -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "✅ \"$NAME\" created — rebuild with ./scripts/build-app.sh, then grant the permissions one last time"
