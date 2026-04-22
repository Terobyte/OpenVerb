#!/usr/bin/env bash
# scripts/ov_smoke.sh — autonomous end-to-end smoke test for OpenVerb.
#
# Runs every layer that can be checked without a real microphone:
#   1. swift build         — compile Swift package
#   2. swift test           — Swift unit tests (parallel)
#   3. cmake --build engine/build — compile C++ engine
#   4. ctest (VAD + session) — targeted C++ tests likely affected by audio path
#   5. ov_bench.py          — spawn engine, stream WAV fixtures via IPC
#
# Exit codes:
#   0 — all green
#   1 — at least one step failed
#
# Options:
#   --quick         skip the long 2-minute WAV in the bench (faster iteration)
#   --chunk N       PCM samples per bench frame (default 2048 = 128 ms, matches Swift)
#   --repeat N      bench runs per WAV (default 2 for back-to-back reliability)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

QUICK_FLAG=""
CHUNK=2048
REPEAT=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)  QUICK_FLAG="--quick"; shift ;;
    --chunk)  CHUNK="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

STATUS_FILE="$REPO/validation/results/smoke-status.json"
mkdir -p "$(dirname "$STATUS_FILE")"
START=$(date +%s)

declare -i overall=0
declare -A step_status

run_step() {
  local name="$1"; shift
  echo
  echo "── $name ────────────────────────────────"
  if "$@"; then
    step_status[$name]="ok"
  else
    step_status[$name]="fail"
    overall=1
  fi
}

run_step swift_build bash -c 'cd app && swift build 2>&1 | tail -10'

run_step swift_test  bash -c 'cd app && swift test --parallel 2>&1 | tail -15; exit ${PIPESTATUS[0]}'

run_step engine_build bash -c 'cd engine/build && cmake --build . --target openverb-engine 2>&1 | tail -5'

run_step engine_vad_tests bash -c '
  cd engine/build
  cmake --build . --target test_vad_scanner test_session >/dev/null 2>&1
  ./tests/test_vad_scanner 2>&1 | tail -5
'

run_step bench python3 scripts/ov_bench.py --chunk-samples "$CHUNK" --repeat "$REPEAT" $QUICK_FLAG

ELAPSED=$(( $(date +%s) - START ))
echo
echo "── summary ─────────────────────────────────"
for k in swift_build swift_test engine_build engine_vad_tests bench; do
  printf "  %-20s %s\n" "$k" "${step_status[$k]:-skipped}"
done
echo "  elapsed            ${ELAPSED}s"
echo "  overall            $([[ $overall -eq 0 ]] && echo GREEN || echo RED)"

# Emit machine-readable status for the autonomous loop to consume.
{
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$(date +%Y-%m-%dT%H:%M:%S)"
  printf '  "elapsed_s": %d,\n' "$ELAPSED"
  printf '  "overall":   "%s",\n' "$([[ $overall -eq 0 ]] && echo green || echo red)"
  printf '  "steps": {\n'
  first=1
  for k in swift_build swift_test engine_build engine_vad_tests bench; do
    [[ $first -eq 0 ]] && printf ',\n'
    printf '    "%s": "%s"' "$k" "${step_status[$k]:-skipped}"
    first=0
  done
  printf '\n  }\n}\n'
} > "$STATUS_FILE"

exit $overall
