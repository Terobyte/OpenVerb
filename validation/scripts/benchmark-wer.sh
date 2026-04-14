#!/usr/bin/env bash
# benchmark-wer.sh — Word Error Rate benchmark across quantizations.
#
# Runs Gemma 4 E2B on all *-en-clean.wav samples and writes wer-results.csv.
#
# Decision thresholds (from requirements):
#   Absolute NO-GO:  best WER > 15%
#   Relative:        recommend Q8_0 if Q4_K_M WER > 5pp worse than BF16
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$BASE_DIR/models"
AUDIO_DIR="$BASE_DIR/audio"
RESULTS_DIR="$BASE_DIR/results"
DEPS_DIR="$BASE_DIR/deps/llama.cpp"
BIN_DIR="$DEPS_DIR/build/bin"

MMPROJ="$MODELS_DIR/mmproj-BF16.gguf"
GROUND_TRUTH="$AUDIO_DIR/ground-truth.txt"
OUTPUT_CSV="$RESULTS_DIR/wer-results.csv"
PROMPT="Transcribe this audio."

MODELS=(
    "gemma-4-E2B-it-Q4_K_M.gguf"
)

mkdir -p "$RESULTS_DIR"

# --- guards ------------------------------------------------------------------

if [ ! -f "$GROUND_TRUTH" ]; then
    echo "ERROR: ground-truth.txt not found: $GROUND_TRUTH" >&2
    echo "       Create validation/audio/ground-truth.txt (format: filename|expected text)" >&2
    exit 1
fi

if [ ! -f "$MMPROJ" ]; then
    echo "ERROR: mmproj file not found: $MMPROJ" >&2
    echo "       Run bash validation/scripts/download-models.sh first" >&2
    exit 1
fi

# --- binary discovery --------------------------------------------------------

BINARY=""
for candidate in llama-mtmd-cli llama-cli; do
    if [ -x "$BIN_DIR/$candidate" ]; then
        BINARY="$BIN_DIR/$candidate"
        break
    fi
done

if [ -z "$BINARY" ]; then
    echo "ERROR: No inference binary found in $BIN_DIR" >&2
    echo "       Run bash validation/scripts/build-deps.sh first" >&2
    exit 1
fi
echo "Using binary: $BINARY"

# --- macOS-safe timeout (GNU timeout is not available on macOS) ---------------

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

# --- inference helper --------------------------------------------------------
# run_inference <model_path> <wav_path>
# Prints extracted model response text (prompt stripped, EOS tokens removed).

run_inference() {
    local model_path="$1"
    local wav_path="$2"
    local raw_output

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

    echo "$raw_output" | python3 -c "
import sys
raw = sys.stdin.read()
# Gemma 4 thinking format: <|channel>thought ... <channel|>ACTUAL_RESPONSE
if '<channel|>' in raw:
    raw = raw.split('<channel|>', 1)[-1]
# Strip prompt echo if model repeats it
prompt = '$PROMPT'
if raw.startswith(prompt):
    raw = raw[len(prompt):]
# Remove remaining special tokens
for tok in ('<end_of_turn>', '<eos>', '<bos>', '[END]', '<|im_end|>'):
    raw = raw.replace(tok, '')
print(raw.strip())
"
}

# --- CSV header --------------------------------------------------------------

echo "model,filename,reference,hypothesis,wer" > "$OUTPUT_CSV"

# --- main loop ---------------------------------------------------------------

for model_file in "${MODELS[@]}"; do
    model_path="$MODELS_DIR/$model_file"

    if [ ! -f "$model_path" ]; then
        echo ""
        echo "SKIP: $model_file — not found in $MODELS_DIR"
        continue
    fi

    echo ""
    echo "=== $model_file ==="

    for wav_path in "$AUDIO_DIR"/*-en-clean.wav; do
        [ -f "$wav_path" ] || continue
        wav_name="$(basename "$wav_path")"

        reference="$(grep "^${wav_name}|" "$GROUND_TRUTH" | cut -d'|' -f2- || true)"
        if [ -z "$reference" ]; then
            echo "  WARN: no ground truth for $wav_name — skipping"
            continue
        fi

        printf "  %-32s ... " "$wav_name"
        hypothesis="$(run_inference "$model_path" "$wav_path")"

        if [ -z "$hypothesis" ]; then
            wer_val="1.0000"
            echo "EMPTY OUTPUT (WER=100%)"
        else
            wer_val="$(python3 "$SCRIPT_DIR/wer.py" "$reference" "$hypothesis")"
            wer_pct="$(python3 -c "print(f'{float(\"$wer_val\")*100:.1f}%')")"
            echo "WER=$wer_pct"
        fi

        # Escape commas to keep CSV valid
        ref_csv="${reference//,/;}"
        hyp_csv="${hypothesis//,/;}"
        echo "$model_file,$wav_name,$ref_csv,$hyp_csv,$wer_val" >> "$OUTPUT_CSV"
    done
done

# --- threshold analysis ------------------------------------------------------

echo ""
echo "=== Threshold Analysis ==="
python3 - "$OUTPUT_CSV" <<'PYEOF'
import sys, csv
from collections import defaultdict

csv_path = sys.argv[1]
with open(csv_path) as f:
    rows = list(csv.DictReader(f))

if not rows:
    print("No results — all models skipped or no *-en-clean.wav files found.")
    sys.exit(0)

wer_sums = defaultdict(float)
wer_counts = defaultdict(int)
for row in rows:
    try:
        wer_sums[row["model"]] += float(row["wer"])
        wer_counts[row["model"]] += 1
    except (ValueError, KeyError):
        pass

avgs = {m: wer_sums[m] / wer_counts[m] for m in wer_sums if wer_counts[m] > 0}

print(f"  {'Model':<42} {'Avg WER':>8}")
print("  " + "-" * 52)
for model in sorted(avgs):
    avg = avgs[model]
    flag = "  ← EXCEEDS 15%" if avg > 0.15 else ""
    print(f"  {model:<42} {avg*100:>7.1f}%{flag}")

best_wer = min(avgs.values())
print()

if best_wer > 0.15:
    print(f"VERDICT: NO-GO — best WER {best_wer*100:.1f}% exceeds 15% absolute threshold")
    sys.exit(1)

q4  = avgs.get("gemma-4-E2B-it-Q4_K_M.gguf")
bf16 = avgs.get("gemma-4-E2B-it-BF16.gguf")
if q4 is not None and bf16 is not None:
    delta = (q4 - bf16) * 100
    if delta > 5.0:
        print(f"RECOMMENDATION: use Q8_0 — Q4_K_M is {delta:.1f}pp worse than BF16 (> 5pp threshold)")
    else:
        print(f"Q4_K_M vs BF16 delta: {delta:+.1f}pp — within tolerance, Q4_K_M acceptable")

print(f"VERDICT: GO — best WER {best_wer*100:.1f}% is within 15% threshold")
PYEOF

echo ""
echo "Results: $OUTPUT_CSV"
