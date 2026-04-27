#!/usr/bin/env bash
# scripts/setup-signing-identity.sh — create a free, stable code-signing identity for OpenVerb.
#
# Generates a self-signed RSA key + X.509 certificate with the codeSigning EKU,
# bundles it as PKCS#12, and imports it into the user's login keychain so that
# `codesign` can use it without prompting.
#
# WHY:
#   - macOS pins TCC grants (Microphone/Accessibility/Input Monitoring) to the
#     code-signature hash. The project's default ad-hoc signing ("-") rotates
#     that hash on every rebuild, dropping all permissions.
#   - With a stable personal identity, permissions persist across rebuilds.
#   - This requires NO Apple Developer Program membership and NO sudo. It runs
#     entirely against the user's login keychain.
#
# USAGE:
#   ./scripts/setup-signing-identity.sh              # default identity name "OpenVerb Dev"
#   ./scripts/setup-signing-identity.sh "My Cert"    # custom name
#
# Once this finishes, build with:
#   ./scripts/sign-build.sh

set -euo pipefail

NAME="${1:-OpenVerb Dev}"
DAYS=3650
P12_PASSWORD="openverb-dev-$(date +%s)"  # ephemeral, only used during import
TMPDIR="$(mktemp -d)"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

trap 'rm -rf "$TMPDIR"' EXIT

# Note: -v (valid only) filters out untrusted self-signed certs, so we use
# the unfiltered list. codesign accepts untrusted self-signed identities for
# local builds — the TCC stable-hash use-case doesn't require root trust.
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "==> Identity \"$NAME\" already exists in login keychain."
    security find-identity -p codesigning | grep "$NAME" | sed 's/^/    /'
    echo
    echo "Nothing to do. To create a different identity, pass a different name:"
    echo "    $0 \"My Other Name\""
    exit 0
fi

echo "==> Creating self-signed code-signing identity: $NAME"

cd "$TMPDIR"

cat > cert.cnf <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_codesign

[ dn ]
CN = $NAME

[ v3_codesign ]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

# 1. Self-signed cert with codeSigning EKU
openssl req -x509 -newkey rsa:2048 -keyout signing.key -out signing.crt \
    -days "$DAYS" -nodes -config cert.cnf 2>/dev/null

# 2. Bundle as PKCS#12 for keychain import.
#    OpenSSL 3.x defaults to AES-256-CBC + SHA-256 MAC; macOS `security` can't
#    verify those, and -legacy alone still drops the private key in some
#    versions. Pin the algorithms explicitly to PBE-SHA1-3DES + SHA1 MAC,
#    which Keychain has supported for ~20 years.
openssl pkcs12 -export -out signing.p12 \
    -inkey signing.key -in signing.crt \
    -name "$NAME" \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg SHA1 \
    -passout "pass:$P12_PASSWORD"

# 3. Import. -T whitelists codesign and security so they can use the key
#    without an interactive Keychain Access permission prompt on first use.
security import signing.p12 \
    -k "$LOGIN_KEYCHAIN" \
    -P "$P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild >/dev/null

# 4. Allow codesign to use the private key partition without nagging.
#    Best-effort: this command needs the keychain unlocked (it usually is).
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -k "" \
    "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true

# 5. Verify by signing a throwaway file with the new identity. This is the
#    only test that actually matters — `find-identity -v` filters out
#    untrusted self-signed certs even when codesign happily uses them.
TEST_BIN="$TMPDIR/test-sign"
echo "verify" > "$TEST_BIN"
if ! codesign --sign "$NAME" "$TEST_BIN" 2>/dev/null; then
    echo "error: identity imported but codesign couldn't use it." >&2
    echo "Run \`security find-identity -p codesigning | grep '$NAME'\` to inspect." >&2
    exit 1
fi

echo
echo "==> Created. Available code-signing identities (incl. self-signed):"
security find-identity -p codesigning | awk '/Matching identities/{f=1;next} /Valid identities only/{f=0} f && NF' | sed 's/^/    /'

cat <<EOF

Done. Next:
  SIGN_IDENTITY="$NAME" ./scripts/sign-build.sh

Then launch the resulting OpenVerb.app once and grant Microphone, Accessibility,
and Input Monitoring. From now on, rebuilds with the same identity will keep
those grants — TCC won't reset.
EOF
