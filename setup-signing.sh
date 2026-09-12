#!/bin/bash
# Gives Ward a stable code identity, so rebuilding stops revoking its permissions.
#
# THE PROBLEM
#   An ad-hoc signature's designated requirement is the cdhash — a hash of the code
#   itself:
#       # designated => cdhash H"8d22d1ce..."
#   Change one byte and macOS considers it a different application. The Accessibility
#   permission you granted no longer applies, while System Settings keeps showing
#   "Ward" switched on, because that entry belongs to the build you granted.
#
# THE FIX
#   Sign with a certificate instead. The requirement becomes "this bundle id, signed
#   by this certificate", which survives rebuilds. The certificate is self-signed and
#   lives in its own keychain with a generated password.
#
#   macOS will not sign with an untrusted certificate, and marking one trusted needs
#   an administrator. That is the one step that asks for your password, and it happens
#   once. Everything else here is unattended.
set -euo pipefail
cd "$(dirname "$0")"

DIR=.signing
KEYCHAIN=ward-signing.keychain
NAME="Ward Local Signing"
PWFILE="$DIR/keychain-password"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "==> Already set up."
    security find-identity -v -p codesigning | grep "$NAME"
    echo
    echo "Rebuild with ./build.sh --install; permissions will survive from now on."
    exit 0
fi

mkdir -p "$DIR"; chmod 700 "$DIR"
[[ -f "$PWFILE" ]] || { openssl rand -hex 24 > "$PWFILE"; chmod 600 "$PWFILE"; }
PW=$(cat "$PWFILE")

echo "==> Generating a self-signed code-signing certificate"
cat > "$DIR/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Ward Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -config "$DIR/openssl.cnf" -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -out "$DIR/identity.p12" \
    -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -passout "pass:$PW" 2>/dev/null

echo "==> Creating a dedicated keychain"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$PW" "$KEYCHAIN"
security set-keychain-settings -lut 100000 "$KEYCHAIN"
security unlock-keychain -p "$PW" "$KEYCHAIN"
security import "$DIR/identity.p12" -k "$KEYCHAIN" -P "$PW" -T /usr/bin/codesign -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null 2>&1 || true

# codesign only searches the keychains on the user's search list.
CURRENT=$(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')
if [[ "$CURRENT" != *"$KEYCHAIN"* ]]; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $CURRENT "$KEYCHAIN"
fi

echo
echo "==> One administrator step: marking the certificate trusted for code signing."
echo "    macOS refuses to sign with an untrusted certificate. Your password is"
echo "    handled by sudo and never seen by this script."
echo
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$DIR/cert.pem"

rm -f "$DIR/key.pem" "$DIR/identity.p12" "$DIR/openssl.cnf"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "==> Done."
    security find-identity -v -p codesigning | grep "$NAME"
    echo
    echo "Now run ./build.sh --install and grant Accessibility one final time."
    echo "Rebuilds after that keep the permission."
else
    echo "==> The identity still isn't usable for signing. Ward will fall back to"
    echo "    ad-hoc signing, which works but needs Accessibility re-granted after"
    echo "    each rebuild."
    exit 1
fi
