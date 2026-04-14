#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/models"

HF_REPO="unsloth/gemma-4-E2B-it-GGUF"
HF_BASE="https://huggingface.co/${HF_REPO}/resolve/main"

MODELS=(
    "gemma-4-E2B-it-Q4_K_M.gguf"
    "mmproj-BF16.gguf"
)

mkdir -p "$MODELS_DIR"

sha256_of() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null
}

expected_sha256() {
    case "$1" in
        gemma-4-E2B-it-Q4_K_M.gguf) echo "ac0069ebccd39925d836f24a88c0f0c858d20578c29b21ab7cedce66ee576845" ;;
        mmproj-BF16.gguf)            echo "5399938a59d07b2ad2c30a7e6e9e51519eab4f696f68eb7e9a0e0bc360b4af34" ;;
        # Q8_0 and BF16 SHA256 not yet verified — script will compute and print on first download
        gemma-4-E2B-it-Q8_0.gguf)   echo "" ;;
        gemma-4-E2B-it-BF16.gguf)   echo "" ;;
        *) echo "" ;;
    esac
}

remote_size() {
    curl --head --location -s "$1" 2>/dev/null \
        | { grep -i '^content-length:' || true; } \
        | tail -1 \
        | awk '{print $2}' | tr -d '\r\n'
}

download_model() {
    local filename="$1"
    local expected
    expected=$(expected_sha256 "$filename")
    local filepath="$MODELS_DIR/$filename"
    local hashfile="$MODELS_DIR/$filename.sha256"
    local url="${HF_BASE}/${filename}"
    local need_download=false

    if [ -f "$filepath" ]; then
        local lsize rsize
        lsize=$(file_size "$filepath")
        rsize=$(remote_size "$url")

        if [ -n "$rsize" ] && [ "$lsize" -lt "$rsize" ] 2>/dev/null; then
            echo "Resuming partial download: $filename ($lsize / $rsize bytes)"
            curl --fail --location -C - --progress-bar -o "$filepath" "$url"
        elif [ -n "$expected" ]; then
            local actual
            actual=$(sha256_of "$filepath")
            if [ "$actual" = "$expected" ]; then
                echo "OK: $filename (SHA256 verified)"
                return 0
            fi
            echo "SHA256 mismatch — re-downloading: $filename"
            rm -f "$filepath" "$hashfile"
            need_download=true
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
        elif [ -n "$rsize" ] && [ "$lsize" -eq "$rsize" ] 2>/dev/null; then
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
    else
        need_download=true
    fi

    if [ "$need_download" = true ]; then
        echo "Downloading: $filename"
        curl --fail --location --progress-bar -o "$filepath" "$url"
    fi

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

echo "Downloading Gemma 4 E2B GGUF models from $HF_REPO"
echo "Target: $MODELS_DIR/"
echo

for model in "${MODELS[@]}"; do
    download_model "$model"
    echo
done

echo "Done. Downloaded models:"
ls -lh "$MODELS_DIR"/*.gguf 2>/dev/null
