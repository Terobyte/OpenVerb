#!/usr/bin/env bash
# benchmark-repetition.sh — Repetition artifact detection benchmark.
#
# For each (quantization, sample): runs inference, splits output into sentences,
# checks 4-gram word-level overlap between all sentence pairs.
# Flags as repetition if overlap coefficient > 60%.
#
# Overlap coefficient = |A ∩ B| / min(|A|, |B|)  (multiset intersection)
# Output: validation/results/repetition-results.csv
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$BASE_DIR/models"
AUDIO_DIR="$BASE_DIR/audio"
RESULTS_DIR="$BASE_DIR/results"
BIN_DIR="$BASE_DIR/deps/llama.cpp/build/bin"

MMPROJ="$MODELS_DIR/mmproj-BF16.gguf"
OUTPUT_CSV="$RESULTS_DIR/repetition-results.csv"
PROMPT="Transcribe this audio."
OVERLAP_THRESHOLD=0.60

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

# --- Python repetition detector ----------------------------------------------
# Accepts raw output text on stdin; prints CSV row fields to stdout.
# Fields: sentences_count,pairs_checked,pairs_flagged,repetition_rate,repetition_detected

detect_repetitions_py() {
    python3 - "$OVERLAP_THRESHOLD" <<'PYEOF'
import sys, re
from collections import Counter

threshold = float(sys.argv[1])
text = sys.stdin.read()

# Strip prompt echo and special tokens
for tok in ('<end_of_turn>', '<eos>', '<bos>', '[END]'):
    text = text.replace(tok, '')

# Split into sentences on .  !  ?
sentences = [s.strip() for s in re.split(r'[.!?]+', text) if s.strip()]

def make_4grams(sentence):
    words = re.sub(r"[^\w\s']", ' ', sentence.lower()).split()
    return Counter(tuple(words[i:i+4]) for i in range(max(0, len(words) - 3)))

ngrams = [make_4grams(s) for s in sentences]

pairs_checked = 0
pairs_flagged = 0

for i in range(len(ngrams)):
    for j in range(i + 1, len(ngrams)):
        a, b = ngrams[i], ngrams[j]
        min_size = min(sum(a.values()), sum(b.values()))
        if min_size == 0:
            continue
        # Multiset intersection size
        intersection = sum((a & b).values())
        overlap = intersection / min_size
        pairs_checked += 1
        if overlap > threshold:
            pairs_flagged += 1

rate = pairs_flagged / pairs_checked if pairs_checked > 0 else 0.0
detected = "1" if pairs_flagged > 0 else "0"
print(f"{len(sentences)},{pairs_checked},{pairs_flagged},{rate:.4f},{detected}")
PYEOF
}

# --- CSV header --------------------------------------------------------------

echo "model,filename,sentences,pairs_checked,pairs_flagged,repetition_rate,repetition_detected" \
    > "$OUTPUT_CSV"

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

    total_samples=0
    flagged_samples=0

    for wav_path in "$AUDIO_DIR"/*.wav; do
        [ -f "$wav_path" ] || continue
        wav_name="$(basename "$wav_path")"

        printf "  %-32s ... " "$wav_name"

        raw_output=$(
            _timeout 180 "$BINARY" \
                -m "$model_path" \
                --mmproj "$MMPROJ" \
                --audio "$wav_path" \
                -p "$PROMPT" \
                -sys "Output only the verbatim transcription. No thinking, no explanations." \
                -n 512 \
                --no-warmup \
                --jinja \
                2>/dev/null
        ) || raw_output=""

        # Extract from Gemma 4 thinking format and strip special tokens
        raw_output="$(echo "$raw_output" | python3 -c "
import sys
raw = sys.stdin.read()
# Gemma 4 thinking: <|channel>thought ... <channel|>ACTUAL_RESPONSE
if '<channel|>' in raw:
    raw = raw.split('<channel|>', 1)[-1]
prompt = '$PROMPT'
if raw.startswith(prompt):
    raw = raw[len(prompt):]
for tok in ('<end_of_turn>', '<eos>', '<bos>', '[END]', '<|im_end|>'):
    raw = raw.replace(tok, '')
print(raw.strip())
")"

        # Run repetition detection
        rep_fields="$(echo "$raw_output" | detect_repetitions_py)"

        repetition_detected="$(echo "$rep_fields" | cut -d',' -f5)"
        repetition_rate="$(echo "$rep_fields" | cut -d',' -f4)"

        if [ "$repetition_detected" = "1" ]; then
            echo "REPETITION DETECTED (rate=$(python3 -c "print(f'{float(\"$repetition_rate\")*100:.0f}%')"))"
            flagged_samples=$((flagged_samples + 1))
        else
            echo "clean"
        fi

        echo "$model_file,$wav_name,$rep_fields" >> "$OUTPUT_CSV"
        total_samples=$((total_samples + 1))
    done

    if [ "$total_samples" -gt 0 ]; then
        echo "  Repetition: $flagged_samples / $total_samples samples flagged"
    fi
done

# --- summary -----------------------------------------------------------------

echo ""
echo "=== Repetition Summary ==="
python3 - "$OUTPUT_CSV" "$OVERLAP_THRESHOLD" <<'PYEOF'
import sys, csv
from collections import defaultdict

csv_path = sys.argv[1]
threshold = float(sys.argv[2])

with open(csv_path) as f:
    rows = list(csv.DictReader(f))

if not rows:
    print("No results.")
    sys.exit(0)

flagged = defaultdict(int)
total   = defaultdict(int)
for row in rows:
    m = row["model"]
    total[m] += 1
    if row.get("repetition_detected") == "1":
        flagged[m] += 1

print(f"  {'Model':<42} {'Flagged':>10}  {'Rate':>8}")
print("  " + "-" * 64)
for model in sorted(total):
    n = total[model]
    f = flagged[model]
    rate = f / n if n > 0 else 0
    print(f"  {model:<42} {f:>4}/{n:<4}    {rate*100:>6.0f}%")

print()
print(f"Overlap threshold: {threshold*100:.0f}%")
print("NOTE: Check DECISION.md to assess whether prompt-based dedup is sufficient.")
PYEOF

echo ""
echo "Results: $OUTPUT_CSV"
