#!/usr/bin/env bash
# benchmark-latency.sh — End-to-end latency benchmark across quantizations.
#
# For each quantization: runs ITERATIONS passes per sample and records:
#   - wall_ms    — total process wall-clock time (python time.time)
#   - load_ms    — model load time from llama.cpp perf output
#   - eval_ms    — token generation time from llama.cpp perf output
#
# Target: < 2000 ms end-to-end (M3 Pro baseline).
# Output: validation/results/latency-results.csv
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$BASE_DIR/models"
AUDIO_DIR="$BASE_DIR/audio"
RESULTS_DIR="$BASE_DIR/results"
BIN_DIR="$BASE_DIR/deps/llama.cpp/build/bin"

MMPROJ="$MODELS_DIR/mmproj-BF16.gguf"
OUTPUT_CSV="$RESULTS_DIR/latency-results.csv"
PROMPT="Transcribe this audio."
ITERATIONS=5
TARGET_MS=2000

MODELS=(
    "gemma-4-E2B-it-Q4_K_M.gguf"
)

mkdir -p "$RESULTS_DIR"

# --- guards ------------------------------------------------------------------

if [ ! -f "$MMPROJ" ]; then
    echo "ERROR: mmproj file not found: $MMPROJ" >&2
    exit 1
fi

BINARY=""
for candidate in llama-mtmd-cli llama-cli; do
    if [ -x "$BIN_DIR/$candidate" ]; then
        BINARY="$BIN_DIR/$candidate"
        break
    fi
done
if [ -z "$BINARY" ]; then
    echo "ERROR: No inference binary in $BIN_DIR — run build-deps.sh first" >&2
    exit 1
fi
echo "Using binary: $BINARY"
echo "Iterations per sample: $ITERATIONS"
echo "Target: ${TARGET_MS}ms"

# --- macOS-safe timeout ------------------------------------------------------

_timeout() {
    local secs=$1; shift
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local watchdog=$!
    if wait "$pid" 2>/dev/null; then
        kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
        return 0
    else
        local rc=$?
        kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
        return "$rc"
    fi
}

# Parse a llama.cpp perf line from a log file.
# Usage: parse_perf_ms <logfile> <pattern>
# e.g.:  parse_perf_ms /tmp/x.log "load time"
parse_perf_ms() {
    grep -i "$2" "$1" 2>/dev/null \
        | tail -1 \
        | python3 -c "
import sys, re
m = re.search(r'=\s*([\d.]+)\s*ms', sys.stdin.read())
print(m.group(1) if m else '0')
"
}

# --- CSV header --------------------------------------------------------------

echo "model,filename,iteration,load_ms,eval_ms,wall_ms" > "$OUTPUT_CSV"

# --- tmp file (cleaned up on exit) -------------------------------------------

PERF_TMP="$(mktemp /tmp/benchmark-latency.XXXXXX.log)"
trap 'rm -f "$PERF_TMP"' EXIT

# --- main loop ---------------------------------------------------------------

for model_file in "${MODELS[@]}"; do
    model_path="$MODELS_DIR/$model_file"
    if [ ! -f "$model_path" ]; then
        echo ""
        echo "SKIP: $model_file — not downloaded"
        continue
    fi

    echo ""
    echo "=== $model_file ==="

    for wav_path in "$AUDIO_DIR"/*.wav; do
        [ -f "$wav_path" ] || continue
        wav_name="$(basename "$wav_path")"

        printf "  %-32s  iters: " "$wav_name"

        wall_sum=0
        count=0

        for iter in $(seq 1 "$ITERATIONS"); do
            # Timing: python3 for cross-platform millisecond accuracy on macOS
            start_ms="$(python3 -c 'import time; print(int(time.perf_counter()*1000))')"

            _timeout 180 "$BINARY" \
                -m "$model_path" \
                --mmproj "$MMPROJ" \
                --audio "$wav_path" \
                -p "$PROMPT" \
                -sys "Output only the verbatim transcription." \
                -n 128 \
                --no-warmup \
                --jinja \
                > /dev/null \
                2>"$PERF_TMP" || true

            end_ms="$(python3 -c 'import time; print(int(time.perf_counter()*1000))')"
            wall_ms=$((end_ms - start_ms))

            load_ms="$(parse_perf_ms "$PERF_TMP" "load time")"
            eval_ms="$(parse_perf_ms "$PERF_TMP" "eval time")"

            echo "$model_file,$wav_name,$iter,$load_ms,$eval_ms,$wall_ms" >> "$OUTPUT_CSV"

            wall_sum=$((wall_sum + wall_ms))
            count=$((count + 1))

            printf "%d " "$iter"
        done

        avg_wall=$((wall_sum / count))
        flag=""
        [ "$avg_wall" -gt "$TARGET_MS" ] && flag=" ← SLOW (>${TARGET_MS}ms)"
        echo " — avg ${avg_wall}ms${flag}"
    done
done

# --- summary & threshold check -----------------------------------------------

echo ""
echo "=== Latency Summary ==="
python3 - "$OUTPUT_CSV" "$TARGET_MS" <<'PYEOF'
import sys, csv
from collections import defaultdict

csv_path = sys.argv[1]
target = float(sys.argv[2])

with open(csv_path) as f:
    rows = list(csv.DictReader(f))

if not rows:
    print("No results.")
    sys.exit(0)

# Per-model average wall_ms across all (sample, iteration) pairs
walls = defaultdict(list)
for row in rows:
    try:
        walls[row["model"]].append(float(row["wall_ms"]))
    except (ValueError, KeyError):
        pass

print(f"  {'Model':<42} {'Avg Wall':>10}  {'Status':>6}")
print("  " + "-" * 62)
any_slow = False
for model in sorted(walls):
    vals = walls[model]
    avg = sum(vals) / len(vals)
    status = "GO" if avg < target else "SLOW"
    if avg >= target:
        any_slow = True
    print(f"  {model:<42} {avg:>8.0f}ms  {status:>6}")

print()
if any_slow:
    print(f"WARNING: one or more models exceed {target:.0f}ms end-to-end target")
else:
    all_vals = [v for vs in walls.values() for v in vs]
    if all_vals:
        print(f"VERDICT: GO — all models under {target:.0f}ms (slowest: {max(all_vals):.0f}ms)")
PYEOF

echo ""
echo "Results: $OUTPUT_CSV"
