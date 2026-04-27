#!/usr/bin/env bash
# scripts/sign-build.sh — build OpenVerb with a stable personal code-signing identity
#
# WHY: macOS pins TCC permissions (Microphone, Accessibility, Input Monitoring)
# to the code signature hash. With the project's default ad-hoc signing ("-")
# those grants reset on every rebuild. A personal self-signed certificate gives
# you a stable identity, so permissions persist across rebuilds. This requires
# NO Apple Developer account.
#
# ONE-TIME SETUP:
#   Keychain Access → Certificate Assistant → Create a Certificate
#       Name:             "OpenVerb Dev"   (or whatever — see SIGN_IDENTITY below)
#       Identity Type:    Self Signed Root
#       Certificate Type: Code Signing
#       Validity:         3650 days
#
# USAGE:
#   ./scripts/sign-build.sh                  # builds Release into build/
#   SIGN_IDENTITY="My Cert" ./scripts/sign-build.sh
#
# This script does NOT modify project.pbxproj — overrides are passed to
# xcodebuild as build settings, kept local to this machine.

set -euo pipefail

SIGN_IDENTITY="${SIGN_IDENTITY:-OpenVerb Dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DERIVED="$ROOT_DIR/build"

# 1. Sanity-check that the identity exists in the keychain. We skip the -v
#    (valid only) filter because self-signed identities are flagged untrusted
#    but codesign accepts them — that's exactly what we want for local TCC
#    persistence without paying Apple $99/yr.
if ! security find-identity -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
    cat <<EOF >&2
error: code-signing identity "$SIGN_IDENTITY" not found in keychain.

Run ./scripts/setup-signing-identity.sh first (or pass SIGN_IDENTITY=...).
Available identities:
$(security find-identity -p codesigning | grep -v "Policy:\|Matching\|Valid identities\|identities found\|^\$" | sed 's/^/    /')
EOF
    exit 1
fi

echo "==> Building OpenVerb signed with: $SIGN_IDENTITY"

xcodebuild \
    -project "$ROOT_DIR/app/OpenVerb.xcodeproj" \
    -scheme OpenVerb \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    build

APP="$DERIVED/Build/Products/Release/OpenVerb.app"
if [ ! -d "$APP" ]; then
    echo "error: build succeeded but .app bundle is missing at $APP" >&2
    exit 1
fi

echo
echo "==> Built: $APP"
echo "==> Signature:"
codesign -dv --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

cat <<EOF

Done. Drag OpenVerb.app to /Applications, launch it, grant Mic/Accessibility/Input Monitoring once.
Future rebuilds with the same SIGN_IDENTITY will keep those grants.
EOF
