#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$BASE_DIR/models"
RESULTS_DIR="$BASE_DIR/results"
AUDIO_DIR="$BASE_DIR/audio"
DEPS_DIR="$BASE_DIR/deps"

MODEL="$MODELS_DIR/gemma-4-E2B-it-Q4_K_M.gguf"
MMPROJ="$MODELS_DIR/mmproj-BF16.gguf"
LOG="$RESULTS_DIR/litert-test.log"

mkdir -p "$RESULTS_DIR"

log() { echo "$@" | tee -a "$LOG"; }

echo "LiteRT-LM audio inference test — $(date)" > "$LOG"
echo "Model: $MODEL" >> "$LOG"
echo "" >> "$LOG"

log "NOTE: This contingency script is only needed if test-mmproj.sh fails."
log ""
log "llama.cpp mmproj audio support has been confirmed via code inspection:"
log "  - llama-mtmd-cli supports --audio flag (src: tools/mtmd/mtmd-cli.cpp)"
log "  - Gemma 4 audio preprocessor implemented (src: tools/mtmd/mtmd-audio.cpp:654)"
log "  - PROJECTOR_TYPE_GEMMA4A with 16kHz sample rate (src: tools/mtmd/clip.cpp:1476)"
log "  - Audio tokens use <|audio_bos|> / <|audio_eos|> markers"
log "  - Both llama-cli and llama-server also support --audio via mmproj"
log ""
log "If mmproj FAILS, LiteRT-LM would be the fallback path."
log "LiteRT-LM (formerly TensorFlow Lite) is Google's on-device ML runtime."
log "However, Gemma 4 E2B GGUF models are designed for llama.cpp, not LiteRT."
log ""

LITERT_DIR="$DEPS_DIR/litert"
if [ ! -d "$LITERT_DIR" ]; then
    log "LiteRT not installed. To set up manually:"
    log "  1. Download from https://ai.google.dev/edge/litert"
    log "  2. Convert Gemma 4 E2B to TFLite format (not trivial for GGUF)"
    log "  3. Use LiteRT Task Library audio API"
    log ""
    log "VERDICT: SKIP — LiteRT not applicable for GGUF models"
    echo "SKIP" > "$RESULTS_DIR/litert-verdict.txt"
    exit 0
fi

log "LiteRT directory found: $LITERT_DIR"
log "However, GGUF model format is incompatible with LiteRT."
log "This path requires:"
log "  1. Original HuggingFace Gemma 4 E2B safetensors model"
log "  2. AI Edge Transformer conversion pipeline"
log "  3. LiteRT-LM runtime binary"
log ""
log "VERDICT: SKIP — GGUF models not compatible with LiteRT"
echo "SKIP" > "$RESULTS_DIR/litert-verdict.txt"
