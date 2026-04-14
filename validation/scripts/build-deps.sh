#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/ggml-org/llama.cpp"
STABLE_TAG="b8779"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/deps"
LLAMA_DIR="$DEPS_DIR/llama.cpp"

if [ -d "$LLAMA_DIR/.git" ]; then
    echo "llama.cpp already cloned at $LLAMA_DIR"
    echo "Checking out $STABLE_TAG..."
    git -C "$LLAMA_DIR" fetch --tags origin
    git -C "$LLAMA_DIR" checkout "$STABLE_TAG"
else
    echo "Cloning llama.cpp ($STABLE_TAG) into $LLAMA_DIR..."
    mkdir -p "$DEPS_DIR"
    git clone --branch "$STABLE_TAG" --depth 1 "$REPO_URL" "$LLAMA_DIR"
fi

CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
if [ ! -x "$CC" ] || [ ! -x "$CXX" ]; then
    echo "ERROR: Apple clang not found via xcrun. Install Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi
echo "Using CC=$CC CXX=$CXX"

echo "Building llama.cpp with Metal..."
cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" \
    -DGGML_METAL=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX"
cmake --build "$LLAMA_DIR/build" \
    -j"$(sysctl -n hw.ncpu)"

echo "Build complete. Binaries at $LLAMA_DIR/build/bin/"
ls "$LLAMA_DIR/build/bin/" 2>/dev/null || true
