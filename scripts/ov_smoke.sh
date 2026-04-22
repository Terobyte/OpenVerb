#!/usr/bin/env bash
# scripts/ov_smoke.sh — autonomous end-to-end smoke test for OpenVerb.
#
# Runs every layer that can be checked without a real microphone:
#   1. swift build          — compile Swift package
#   2. swift test           — Swift unit tests (parallel)
#   3. engine_build         — compile C++ engine
#   4. engine_vad_tests     — targeted C++ tests likely affected by audio path
#   5. bench                — spawn engine, stream WAV fixtures via IPC
#
# Exit codes:
#   0 — all green
#   1 — at least one step failed
#
# Options:
#   --quick         skip long WAVs in the bench
#   --chunk N       samples per bench frame (default 2048 = 128 ms, Swift-parity)
#   --repeat N      bench runs per WAV (default 2)

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

overall=0

s_swift_build="skipped"
s_swift_test="skipped"
s_engine_build="skipped"
s_engine_vad_tests="skipped"
s_bench="skipped"

run_step() {
  local varname="$1"; shift
  local label="$1"; shift
  echo
  echo "── $label ────────────────────────────────"
  if "$@"; then
    eval "$varname=ok"
  else
    eval "$varname=fail"
    overall=1
  fi
}

run_step s_swift_build swift_build bash -c 'cd app && swift build 2>&1 | tail -8; exit ${PIPESTATUS[0]}'

# Swift test: UI tests that touch CGS crash with signal 6 under `swift test` (no WindowServer).
# Filter them out so headless runs stay deterministic; they pass under `xcodebuild test`.
SWIFT_SKIP='--skip StatusBarItemTests --skip RecordingWindowTests.testRecordingWindowPanelProperties --skip ShortcutCaptureViewTests.testStopRecordingIfActiveIsIdempotent'
run_step s_swift_test swift_test bash -c "cd app && swift test --parallel $SWIFT_SKIP 2>&1 | tail -10; exit \${PIPESTATUS[0]}"

run_step s_engine_build engine_build bash -c 'cd engine/build && cmake --build . --target openverb-engine 2>&1 | tail -3'

run_step s_engine_vad_tests engine_vad_tests bash -c '
  cd engine/build
  cmake --build . --target test_vad_scanner >/dev/null 2>&1 || exit 1
  ./tests/test_vad_scanner 2>&1 | tail -3
'

run_step s_bench bench python3 scripts/ov_bench.py --chunk-samples "$CHUNK" --repeat "$REPEAT" $QUICK_FLAG

ELAPSED=$(( $(date +%s) - START ))
echo
echo "── summary ─────────────────────────────────"
printf "  %-20s %s\n" "swift_build"       "$s_swift_build"
printf "  %-20s %s\n" "swift_test"        "$s_swift_test"
printf "  %-20s %s\n" "engine_build"      "$s_engine_build"
printf "  %-20s %s\n" "engine_vad_tests"  "$s_engine_vad_tests"
printf "  %-20s %s\n" "bench"             "$s_bench"
printf "  %-20s %ds\n" "elapsed"          "$ELAPSED"
OVERALL=$([[ $overall -eq 0 ]] && echo green || echo red)
printf "  %-20s %s\n" "overall"           "$OVERALL"

{
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$(date +%Y-%m-%dT%H:%M:%S)"
  printf '  "elapsed_s": %d,\n' "$ELAPSED"
  printf '  "overall":   "%s",\n' "$OVERALL"
  printf '  "steps": {\n'
  printf '    "swift_build":      "%s",\n' "$s_swift_build"
  printf '    "swift_test":       "%s",\n' "$s_swift_test"
  printf '    "engine_build":     "%s",\n' "$s_engine_build"
  printf '    "engine_vad_tests": "%s",\n' "$s_engine_vad_tests"
  printf '    "bench":            "%s"\n'  "$s_bench"
  printf '  }\n}\n'
} > "$STATUS_FILE"

exit $overall
