#!/usr/bin/env bash
# scripts/build-release.sh — build universal binary + signed DMG
set -euo pipefail

VERSION="${1:?Usage: build-release.sh <version>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build-release"

echo "=== Building OpenVerb $VERSION ==="

# 0. Pin model SHA256 BEFORE building the app so the compile-time constant
#    is baked into the binary. MODEL_PATH defaults to $ROOT_DIR/models/ but
#    can be overridden: MODEL_PATH=/path/to/model.gguf ./build-release.sh 1.0.0
MODEL_PATH="${MODEL_PATH:-$ROOT_DIR/models/gemma-4-E2B-it-Q4_K_M.gguf}"
if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: Model file not found at $MODEL_PATH"
    echo "Set MODEL_PATH env var or place the file at the default location:"
    echo "  $ROOT_DIR/models/gemma-4-E2B-it-Q4_K_M.gguf"
    exit 1
fi
MODEL_SHA=$(shasum -a 256 "$MODEL_PATH" | cut -d' ' -f1)
echo "Model SHA256: $MODEL_SHA"
# Pin into source before compiling — the app binary will contain the real hash.
sed -i '' "s/static let expectedSHA256 = \".*\"/static let expectedSHA256 = \"$MODEL_SHA\"/" \
    "$ROOT_DIR/app/OpenVerb/Model/ModelDownloader.swift"
echo "Pinned model SHA256 in ModelDownloader.swift"

# 1. Build engine — two separate cmake builds then lipo-merge.
# Metal (GGML_METAL) only runs on Apple Silicon; a single cmake invocation
# with arm64+x86_64 architectures and GGML_METAL=ON fails to compile the
# x86_64 slice because Metal is unavailable on Intel.
cd "$ROOT_DIR/engine"
cmake -B build-arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DCMAKE_OSX_ARCHITECTURES="arm64"
cmake --build build-arm64 -j"$(sysctl -n hw.ncpu)"

cmake -B build-x86 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=OFF \
    -DCMAKE_OSX_ARCHITECTURES="x86_64"
cmake --build build-x86 -j"$(sysctl -n hw.ncpu)"

mkdir -p build-release
lipo -create build-arm64/openverb-engine build-x86/openverb-engine \
    -output build-release/openverb-engine

# 2. Build app universal binary (SHA256 is now compiled in from step 0).
# ONLY_ACTIVE_ARCH=NO is required — without it Xcode builds only the
# architecture of the current machine regardless of the ARCHS setting.
cd "$ROOT_DIR/app"
xcodebuild -scheme OpenVerb \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

# 3. Copy engine binary into app bundle
APP_PATH="$BUILD_DIR/derived/Build/Products/Release/OpenVerb.app"
cp "$ROOT_DIR/engine/build-release/openverb-engine" \
   "$APP_PATH/Contents/MacOS/openverb-engine"

# 3b. Code-sign the app bundle (required for Gatekeeper — unsigned apps are
#     blocked by default on macOS. DEVELOPER_ID must be set in the environment:
#       export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#     The --deep flag signs embedded binaries (openverb-engine) in one pass.
#     --options runtime enables the hardened runtime required for notarization.
if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --deep \
             --force \
             --verify \
             --sign "$DEVELOPER_ID" \
             --options runtime \
             --entitlements "$ROOT_DIR/app/OpenVerb.entitlements" \
             "$APP_PATH"
    echo "Code-signed: $APP_PATH"
else
    echo "WARNING: DEVELOPER_ID not set — skipping code signing. DMG will be blocked by Gatekeeper."
fi

# 4. Create DMG
DMG_PATH="$BUILD_DIR/OpenVerb-$VERSION.dmg"
hdiutil create -volname "OpenVerb" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

# 4b. Notarize DMG (required for distribution outside Mac App Store / Homebrew).
#     Without notarization, Gatekeeper shows a "malicious software" warning on
#     first launch. Requires Apple ID credentials stored in keychain:
#       xcrun notarytool store-credentials "notarytool-profile" \
#           --apple-id your@email.com --team-id TEAMID --password app-specific-password
if [ -n "${DEVELOPER_ID:-}" ]; then
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "notarytool-profile" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    echo "Notarized and stapled: $DMG_PATH"
else
    echo "WARNING: DEVELOPER_ID not set — skipping notarization."
fi

# 5. Update Homebrew cask SHA + version
DMG_SHA=$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)
sed -i '' "s/sha256 \".*\"/sha256 \"$DMG_SHA\"/" "$ROOT_DIR/homebrew/Casks/openverb.rb"
sed -i '' "s/version \".*\"/version \"$VERSION\"/" "$ROOT_DIR/homebrew/Casks/openverb.rb"

# 6. Copy cask to homebrew-tap repo (required by Homebrew conventions)
TAP_REPO="$ROOT_DIR/../homebrew-tap"
if [ -d "$TAP_REPO" ]; then
    cp "$ROOT_DIR/homebrew/Casks/openverb.rb" "$TAP_REPO/Casks/openverb.rb"
    echo "Copied cask to homebrew-tap repo at $TAP_REPO"
else
    echo "WARNING: homebrew-tap repo not found at $TAP_REPO — copy manually"
fi

echo "=== Done: $DMG_PATH ==="
echo "DMG SHA256: $DMG_SHA"
