#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$BASE_DIR/models"
RESULTS_DIR="$BASE_DIR/results"
AUDIO_DIR="$BASE_DIR/audio"
DEPS_DIR="$BASE_DIR/deps/llama.cpp"

MODEL="$MODELS_DIR/gemma-4-E2B-it-Q4_K_M.gguf"
MMPROJ="$MODELS_DIR/mmproj-BF16.gguf"
LOG="$RESULTS_DIR/mmproj-test.log"

mkdir -p "$RESULTS_DIR"

BIN_DIR="$DEPS_DIR/build/bin"

# macOS-compatible timeout: GNU `timeout` is not available on macOS by default.
# Spawns cmd in background, kills it after N seconds if still running.
_timeout() {
    local secs=$1; shift
    "$@" &
    local pid=$!
    local timed_out=0
    ( sleep "$secs" && kill "$pid" 2>/dev/null && echo "TIMEOUT" > /tmp/_timeout_marker_$$ ) &
    local watchdog=$!
    if wait "$pid" 2>/dev/null; then
        kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
        # Check if process was killed by watchdog but exited 0 (e.g. SIGTERM trap)
        if [ -f /tmp/_timeout_marker_$$ ]; then
            rm -f /tmp/_timeout_marker_$$
            return 124  # GNU timeout convention: 124 = timed out
        fi
        rm -f /tmp/_timeout_marker_$$
        return 0
    else
        local rc=$?
        kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
        rm -f /tmp/_timeout_marker_$$
        return "$rc"
    fi
}

VERDICT="FAIL"
WORKING_CMD=""

log() { echo "$@" | tee -a "$LOG"; }
log_section() { echo "" | tee -a "$LOG"; echo "=== $1 ===" | tee -a "$LOG"; echo "" | tee -a "$LOG"; }

echo "mmproj audio inference test — $(date)" > "$LOG"
echo "Model: $MODEL" >> "$LOG"
echo "mmproj: $MMPROJ" >> "$LOG"
echo "" >> "$LOG"

if [ ! -f "$MODEL" ]; then
    log "ERROR: Model file not found: $MODEL"
    log "Run bash validation/scripts/download-models.sh first"
    log ""
    log "VERDICT: FAIL — model files missing"
    echo "$VERDICT" > "$RESULTS_DIR/mmproj-verdict.txt"
    exit 1
fi

if [ ! -f "$MMPROJ" ]; then
    log "ERROR: mmproj file not found: $MMPROJ"
    log "Run bash validation/scripts/download-models.sh first"
    log ""
    log "VERDICT: FAIL — mmproj file missing"
    echo "$VERDICT" > "$RESULTS_DIR/mmproj-verdict.txt"
    exit 1
fi

if [ ! -f "$AUDIO_DIR/short-en-clean.wav" ]; then
    log "ERROR: Test audio not found: $AUDIO_DIR/short-en-clean.wav"
    log "Run bash validation/scripts/generate-test-audio.sh first"
    log ""
    log "VERDICT: FAIL — test audio missing"
    echo "$VERDICT" > "$RESULTS_DIR/mmproj-verdict.txt"
    exit 1
fi

log_section "1. Check available binaries"
for bin in llama-mtmd-cli llama-cli llama-server; do
    if [ -x "$BIN_DIR/$bin" ]; then
        log "FOUND: $bin"
    else
        log "MISSING: $bin"
    fi
done

log_section "2. Probe llama-mtmd-cli --help for --audio flag"
if [ -x "$BIN_DIR/llama-mtmd-cli" ]; then
    if "$BIN_DIR/llama-mtmd-cli" --help 2>&1 | grep -q '\-\-audio'; then
        log "PASS: llama-mtmd-cli supports --audio flag"
    else
        log "INFO: --audio not found in llama-mtmd-cli --help (may still work)"
    fi
else
    log "SKIP: llama-mtmd-cli not built"
fi

log_section "3. Probe llama-cli --help for --audio flag"
if [ -x "$BIN_DIR/llama-cli" ]; then
    if "$BIN_DIR/llama-cli" --help 2>&1 | grep -q '\-\-audio'; then
        log "PASS: llama-cli supports --audio flag"
    else
        log "INFO: --audio not found in llama-cli --help"
    fi
else
    log "SKIP: llama-cli not built"
fi

log_section "4. Test llama-mtmd-cli with Gemma 4 E2B + mmproj + audio"
if [ -x "$BIN_DIR/llama-mtmd-cli" ]; then
    log "Command:"
    log "  $BIN_DIR/llama-mtmd-cli \\"
    log "    -m $MODEL \\"
    log "    --mmproj $MMPROJ \\"
    log "    --audio $AUDIO_DIR/short-en-clean.wav \\"
    log "    -p \"Transcribe this audio.\" \\"
    log "    -n 128 --no-warmup --jinja"
    log ""
    log "Output:"
    if _timeout 120 "$BIN_DIR/llama-mtmd-cli" \
        -m "$MODEL" \
        --mmproj "$MMPROJ" \
        --audio "$AUDIO_DIR/short-en-clean.wav" \
        -p "Transcribe this audio." \
        -n 128 \
        --no-warmup \
        --jinja \
        2>&1 | tee -a "$LOG"; then
        VERDICT="PASS"
        WORKING_CMD="$BIN_DIR/llama-mtmd-cli -m $MODEL --mmproj $MMPROJ --audio <wav> -p <prompt> -n <tokens> --jinja"
        log ""
        log "SUCCESS: llama-mtmd-cli completed without error"
    else
        log ""
        log "FAILED: llama-mtmd-cli exited with error (see output above)"
    fi
else
    log "SKIP: llama-mtmd-cli not available"
fi

if [ "$VERDICT" = "FAIL" ]; then
    log_section "5. Test llama-cli with --mmproj + --audio (fallback)"
    if [ -x "$BIN_DIR/llama-cli" ]; then
        log "Command:"
        log "  $BIN_DIR/llama-cli \\"
        log "    -m $MODEL \\"
        log "    --mmproj $MMPROJ \\"
        log "    --audio $AUDIO_DIR/short-en-clean.wav \\"
        log "    -p \"Transcribe this audio.\" \\"
        log "    -n 128 --no-warmup --jinja"
        log ""
        log "Output:"
        if _timeout 120 "$BIN_DIR/llama-cli" \
            -m "$MODEL" \
            --mmproj "$MMPROJ" \
            --audio "$AUDIO_DIR/short-en-clean.wav" \
            -p "Transcribe this audio." \
            -n 128 \
            --no-warmup \
            --jinja \
            2>&1 | tee -a "$LOG"; then
            VERDICT="PASS"
            WORKING_CMD="$BIN_DIR/llama-cli -m $MODEL --mmproj $MMPROJ --audio <wav> -p <prompt> -n <tokens> --jinja"
            log ""
            log "SUCCESS: llama-cli completed without error"
        else
            log ""
            log "FAILED: llama-cli also exited with error"
        fi
    else
        log "SKIP: llama-cli not available"
    fi
fi

if [ "$VERDICT" = "FAIL" ]; then
    log_section "6. Test llama-server with mmproj (HTTP API test)"
    if [ -x "$BIN_DIR/llama-server" ]; then
        PORT=18877
        log "Starting llama-server on port $PORT..."
        "$BIN_DIR/llama-server" \
            -m "$MODEL" \
            --mmproj "$MMPROJ" \
            --port "$PORT" \
            -c 4096 \
            --no-warmup \
            2>&1 &
        SERVER_PID=$!
        sleep 10

        log "Checking /health endpoint..."
        if curl -s "http://localhost:$PORT/health" | tee -a "$LOG"; then
            log ""
            log "Server is running. Checking model props..."
            curl -s "http://localhost:$PORT/props" | python3 -m json.tool 2>/dev/null | tee -a "$LOG" || true

            AUDIO_B64="$(base64 -i "$AUDIO_DIR/short-en-clean.wav")"
            log ""
            log "Sending audio transcription request via OpenAI-compatible API..."
            CHAT_RESP="$(curl -s "http://localhost:$PORT/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"messages\": [{
                        \"role\": \"user\",
                        \"content\": [
                            {\"type\": \"text\", \"text\": \"Transcribe this audio.\"},
                            {\"type\": \"input_audio\", \"input_audio\": {\"data\": \"$AUDIO_B64\", \"format\": \"wav\"}}
                        ]
                    }],
                    \"max_tokens\": 128
                }" 2>&1)"
            echo "$CHAT_RESP" | tee -a "$LOG"
            log ""

            if echo "$CHAT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'choices' in d else 1)" 2>/dev/null; then
                VERDICT="PASS"
                WORKING_CMD="llama-server -m $MODEL --mmproj $MMPROJ --port $PORT && curl http://localhost:$PORT/v1/chat/completions with input_audio content block"
                log "SUCCESS: llama-server HTTP API accepted audio and returned choices"
            else
                log "WARN: Response did not contain 'choices' — audio API may not be supported"
            fi

            if kill "$SERVER_PID" 2>/dev/null; then
                log "Server stopped (PID $SERVER_PID)"
            fi
        else
            log "Server did not start successfully"
            kill "$SERVER_PID" 2>/dev/null || true
        fi
    else
        log "SKIP: llama-server not available"
    fi
fi

log_section "RESULT"
log "Verdict: $VERDICT"
if [ -n "$WORKING_CMD" ]; then
    log "Working invocation:"
    log "  $WORKING_CMD"
fi
log ""
log "Full log: $LOG"

echo "$VERDICT" > "$RESULTS_DIR/mmproj-verdict.txt"
if [ "$VERDICT" = "FAIL" ]; then
    echo ""
    echo "mmproj audio inference FAILED."
    echo "Next step: run bash validation/scripts/test-litert.sh"
    exit 1
fi
