#!/bin/zsh
# Creates a local self-signed codesigning identity ("Auralink Dev Signing")
# and trusts it for code signing in YOUR login keychain.
#
# Why: ad-hoc signatures change on every build, so macOS resets the app's
# microphone (TCC) permission each time. A stable identity keeps the grant.
#
# Run this yourself in Terminal:   ./scripts/setup-dev-signing.sh
# (macOS may ask for your login password once to update trust settings,
#  and once more the first time codesign uses the key — choose "Always Allow".)
set -e

# Use the SYSTEM LibreSSL: Homebrew's OpenSSL 3 writes PKCS#12 files with
# modern ciphers (AES + SHA-256 MAC) that `security import` cannot parse —
# the import fails with "MAC verification failed (wrong password?)".
OPENSSL=/usr/bin/openssl

IDENTITY="Auralink Dev Signing"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if security find-identity -v -p codesigning | grep -q "${IDENTITY}"; then
  echo "'${IDENTITY}' already exists — nothing to do."
  exit 0
fi

echo "==> Generating self-signed codesigning certificate (10 years)…"
cat > "${WORK}/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${IDENTITY}
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:FALSE
CNF
"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
  -config "${WORK}/req.cnf"

"${OPENSSL}" pkcs12 -export -out "${WORK}/identity.p12" \
  -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" -passout pass:auralink

echo "==> Importing into your login keychain…"
security import "${WORK}/identity.p12" \
  -k "${HOME}/Library/Keychains/login.keychain-db" \
  -P auralink -T /usr/bin/codesign

echo "==> Trusting the certificate for code signing (password prompt expected)…"
security add-trusted-cert -r trustRoot -p codeSign \
  -k "${HOME}/Library/Keychains/login.keychain-db" "${WORK}/cert.pem"

echo "==> Done. Identities now available:"
security find-identity -v -p codesigning

echo
echo "Next: rebuild the app (scripts/bundle-app.sh picks the identity up"
echo "automatically). The NEXT launch asks for the microphone permission one"
echo "final time; after that it sticks across rebuilds."
