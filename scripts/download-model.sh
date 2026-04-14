#!/usr/bin/env bash
# download-model.sh — download Gemma 4 E2B GGUF + mmproj to ~/.openverb/models/
#
# Features:
#   - Range-request resume: interrupted downloads continue where they left off
#   - SHA256 verification: file integrity checked against known-good hashes
#   - First-run guidance: prints usage instructions after a successful download
#
# Usage:
#   ./scripts/download-model.sh
#   OPENVERB_MODELS_DIR=/custom/path ./scripts/download-model.sh
set -euo pipefail

MODELS_DIR="${OPENVERB_MODELS_DIR:-$HOME/.openverb/models}"

HF_REPO="unsloth/gemma-4-E2B-it-GGUF"
HF_BASE="https://huggingface.co/${HF_REPO}/resolve/main"

MODELS=(
    "gemma-4-E2B-it-Q4_K_M.gguf"
    "mmproj-BF16.gguf"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sha256_of() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null
}

# Known-good SHA256 hashes — add new variants here as they are verified.
expected_sha256() {
    case "$1" in
        gemma-4-E2B-it-Q4_K_M.gguf) echo "ac0069ebccd39925d836f24a88c0f0c858d20578c29b21ab7cedce66ee576845" ;;
        mmproj-BF16.gguf)            echo "5399938a59d07b2ad2c30a7e6e9e51519eab4f696f68eb7e9a0e0bc360b4af34" ;;
        *) echo "" ;;
    esac
}

# Fetch the remote Content-Length without downloading the body.
# Returns an empty string on any curl failure (offline, DNS error, HEAD blocked)
# so callers always receive a defined value and the script does not abort.
remote_size() {
    { curl --head --location -s "$1" 2>/dev/null || true; } \
        | { grep -i '^content-length:' || true; } \
        | tail -1 \
        | awk '{print $2}' | tr -d '\r\n'
}

# ---------------------------------------------------------------------------
# Per-file download with resume + verification
# ---------------------------------------------------------------------------

download_model() {
    local filename="$1"
    local expected
    expected=$(expected_sha256 "$filename")
    local filepath="$MODELS_DIR/$filename"
    local hashfile="$MODELS_DIR/$filename.sha256"
    local url="${HF_BASE}/${filename}"
    local need_download=false

    if [ -f "$filepath" ]; then
        # ── Local integrity check first (fully offline, fast) ──────────────
        # For files with a known SHA256 or a stored hash, verify before ever
        # touching the network.  A passing check means we are done.
        if [ -n "$expected" ]; then
            local actual
            actual=$(sha256_of "$filepath")
            if [ "$actual" = "$expected" ]; then
                echo "OK: $filename (SHA256 verified)"
                return 0
            fi
            # Hash mismatch: could be a partial/corrupt download.
            # Fall through to remote probe to decide whether to resume or retry.
        elif [ -f "$hashfile" ]; then
            local stored actual
            stored=$(cat "$hashfile")
            actual=$(sha256_of "$filepath")
            if [ "$actual" = "$stored" ]; then
                echo "OK: $filename (SHA256 verified against stored hash)"
                return 0
            fi
            echo "SHA256 mismatch vs stored hash — re-downloading: $filename"
            rm -f "$filepath" "$hashfile"
            need_download=true
        fi

        # ── Remote probe (only reached when local check was inconclusive) ──
        # remote_size() is safe to call offline — returns "" on curl failure.
        if [ "$need_download" = false ]; then
            local lsize rsize
            lsize=$(file_size "$filepath")
            rsize=$(remote_size "$url")

            if [ -n "$rsize" ] && [ "$lsize" -lt "$rsize" ] 2>/dev/null; then
                # Partial file — resume with HTTP Range request.
                echo "Resuming partial download: $filename ($lsize / $rsize bytes)"
                curl --fail --location -C - --progress-bar -o "$filepath" "$url"
            elif [ -n "$expected" ]; then
                # Local SHA256 already checked above and failed.
                echo "SHA256 mismatch — re-downloading: $filename"
                rm -f "$filepath" "$hashfile"
                need_download=true
            elif [ -n "$rsize" ] && [ "$lsize" -eq "$rsize" ] 2>/dev/null; then
                # Size matches but no trusted hash — compute and advise.
                echo "UNVERIFIED: $filename — size matches remote ($lsize bytes) but no trusted SHA256."
                local actual
                actual=$(sha256_of "$filepath")
                echo "  SHA256: $actual"
                echo "  Add this value to expected_sha256() in the script for trusted verification."
                return 0
            else
                echo "UNVERIFIED: $filename — cannot confirm integrity (remote size unavailable, no trusted hash)."
                echo "  Re-downloading to ensure a complete file."
                rm -f "$filepath"
                need_download=true
            fi
        fi
    else
        need_download=true
    fi

    if [ "$need_download" = true ]; then
        echo "Downloading: $filename"
        curl --fail --location --progress-bar -o "$filepath" "$url"
    fi

    # Post-download verification.
    echo "Verifying: $filename"
    local actual
    actual=$(sha256_of "$filepath")

    if [ -n "$expected" ]; then
        if [ "$actual" = "$expected" ]; then
            echo "OK: $filename (SHA256 verified)"
            echo "$actual" > "$hashfile"
        else
            echo "ERROR: SHA256 mismatch for $filename" >&2
            echo "  expected: $expected" >&2
            echo "  actual:   $actual" >&2
            rm -f "$filepath" "$hashfile"
            exit 1
        fi
    else
        echo "UNVERIFIED: $filename — no trusted SHA256 configured."
        echo "  Downloaded hash: $actual"
        echo "  Add this value to expected_sha256() in the script for trusted verification."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

is_first_run=false
[ -d "$MODELS_DIR" ] || is_first_run=true

mkdir -p "$MODELS_DIR"

echo "OpenVerb model downloader"
echo "  Repository : $HF_REPO"
echo "  Destination: $MODELS_DIR"
echo

for model in "${MODELS[@]}"; do
    download_model "$model"
    echo
done

echo "Done. Models in $MODELS_DIR:"
ls -lh "$MODELS_DIR"/*.gguf 2>/dev/null

# ---------------------------------------------------------------------------
# First-run instructions
# ---------------------------------------------------------------------------

if [ "$is_first_run" = true ]; then
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  First run: models saved to $MODELS_DIR"
    echo
    echo "  Next steps:"
    echo "    1. Build the engine (from the repo root):"
    echo "         cmake -B engine/build -S engine -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON"
    echo "         cmake --build engine/build -j\$(sysctl -n hw.ncpu)"
    echo
    echo "    2. Run inference:"
    echo "         ./engine/build/openverb-engine --file your_audio.wav --context '{\"app\":\"Slack\"}'"
    echo
    echo "    3. The engine auto-detects models in $MODELS_DIR"
    echo "       Override with: --model /path/to/model.gguf --mmproj /path/to/mmproj.gguf"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
