#!/usr/bin/env bash
# scripts/install.sh — one-shot installer for OpenVerb
#
# Run from anywhere on a fresh Apple Silicon Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/<owner>/OpenVerb/main/scripts/install.sh | bash
#
# What it does:
#   1. clones (or updates) the repo into ~/.openverb/source
#   2. builds the C++ engine (llama.cpp + audio pipeline)
#   3. downloads Gemma 4 E2B weights into ~/.openverb/models  (~5 GB, one-time)
#   4. creates a free, stable, self-signed code-signing identity in your login keychain
#      (so macOS keeps your Microphone / Accessibility / Input Monitoring grants
#       across rebuilds — no Apple Developer account needed)
#   5. builds a signed OpenVerb.app and copies it to /Applications
#
# Re-running this script updates an existing install. Total time on a clean
# machine: ~5–10 minutes, mostly model download.
#
# Overrides (all optional):
#   OPENVERB_REPO=https://github.com/your/fork.git
#   OPENVERB_REF=main                # branch or tag
#   OPENVERB_DIR=/custom/source/dir
#   SIGN_IDENTITY="My Cert"
#   OPENVERB_SKIP_INSTALL=1          # build but don't copy to /Applications

set -euo pipefail

REPO_URL="${OPENVERB_REPO:-https://github.com/openverb/OpenVerb.git}"
REF="${OPENVERB_REF:-main}"
INSTALL_DIR="${OPENVERB_DIR:-$HOME/.openverb/source}"
SIGN_IDENTITY="${SIGN_IDENTITY:-OpenVerb Dev}"

step() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Sanity checks ------------------------------------------------------------
[[ "$(uname)" == "Darwin" ]]      || fail "OpenVerb is macOS-only (got $(uname))."
[[ "$(uname -m)" == "arm64" ]]    || fail "OpenVerb requires Apple Silicon (got $(uname -m))."

OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[[ "$OS_MAJOR" -ge 13 ]] || fail "OpenVerb requires macOS 13 (Ventura) or newer."

for cmd in git cmake swift xcodebuild openssl security codesign curl; do
    command -v "$cmd" >/dev/null 2>&1 || fail "missing prerequisite: $cmd"
done

# 2. Source checkout ----------------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
    step "Updating existing checkout in $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --tags --recurse-submodules
    git -C "$INSTALL_DIR" checkout "$REF"
    git -C "$INSTALL_DIR" pull --recurse-submodules --ff-only || \
        warn "could not fast-forward; assuming detached/tag checkout"
    git -C "$INSTALL_DIR" submodule update --init --recursive
else
    step "Cloning OpenVerb to $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --recurse-submodules --branch "$REF" "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

# 3. Engine build -------------------------------------------------------------
step "Building C++ engine (Release)"
cmake -S engine -B engine/build-release -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build-release -j"$(sysctl -n hw.ncpu)"

# 4. Model weights ------------------------------------------------------------
step "Fetching Gemma 4 E2B weights (skipped if already present)"
./scripts/download-model.sh

# 5. Code-signing identity ----------------------------------------------------
step "Ensuring code-signing identity '$SIGN_IDENTITY' exists"
./scripts/setup-signing-identity.sh "$SIGN_IDENTITY"

# 6. Signed .app build --------------------------------------------------------
step "Building signed OpenVerb.app"
SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/sign-build.sh

APP_SRC="$INSTALL_DIR/build/Build/Products/Release/OpenVerb.app"
[[ -d "$APP_SRC" ]] || fail "build finished but $APP_SRC is missing"

# 7. Install into /Applications ----------------------------------------------
if [[ -n "${OPENVERB_SKIP_INSTALL:-}" ]]; then
    step "OPENVERB_SKIP_INSTALL set — leaving .app in $APP_SRC"
else
    APP_DST="/Applications/OpenVerb.app"
    if [[ -d "$APP_DST" ]]; then
        step "Replacing existing $APP_DST"
        rm -rf "$APP_DST"
    fi
    cp -R "$APP_SRC" "$APP_DST"
    step "Installed to $APP_DST"
fi

cat <<EOF

────────────────────────────────────────────────────────────────────────────
  Done.

  Launch OpenVerb (Cmd-Space → "OpenVerb") and grant:
      Microphone, Accessibility, Input Monitoring

  Default hotkey: ⌥Space (rebindable in Settings).

  Update later by running this same command — it's idempotent.
────────────────────────────────────────────────────────────────────────────
EOF
