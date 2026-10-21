#!/bin/bash
# Optional, one-time. Creates a local code-signing certificate ("ScreenLocalizer Local Signing") so
# macOS keeps ScreenLocalizer's Accessibility and Screen Recording approvals (and Keychain access)
# when you install a new build. Without it, every update is ad-hoc signed and macOS asks again.
#
# macOS asks for your password once, because trusting a certificate changes your security settings.
# Not needed for apps signed with an Apple Developer ID.
set -euo pipefail

NAME="ScreenLocalizer Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✓ \"$NAME\" is already set up."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" << EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/cert.cnf" 2>/dev/null
LEGACY=()
openssl version | grep -q "^OpenSSL 3" && LEGACY=(-legacy)
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:screenlocalizer

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P screenlocalizer -T /usr/bin/codesign
echo "→ macOS will now ask for your password to trust the certificate for code signing…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "✓ Done. Run scripts/build-app.sh --install, then approve Accessibility and Screen Recording"
echo "  one last time; future updates will keep those approvals."
