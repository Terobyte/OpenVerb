# MVP 0: Gemma 4 E2B Validation

**Goal:** Prove Gemma 4 E2B audio-native works end-to-end via llama.cpp on Apple Silicon. Measure WER, latency, repetition artifacts. Validate mmproj audio embedding path. Produce decision document. **No product code.**

**Spec:** `docs/superpowers/specs/2026-04-13-openverb-architecture-design.md` — MVP 0 section

**Output:** `validation/` directory with scripts, benchmark results, and `DECISION.md`

---

## Setup

- [x] Create `validation/` tree: `validation/scripts/`, `validation/results/`, `validation/audio/`, `validation/models/` (gitignored), `validation/deps/` (gitignored)
- [x] Add `validation/models/` and `validation/deps/` to `.gitignore`
- [x] Write `validation/README.md`: what this directory is, hardware requirements, how to run each script
- [x] Write `validation/scripts/build-deps.sh`: clone llama.cpp (latest stable tag) to `validation/deps/llama.cpp/`, build with Metal (`cmake -B build -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release && cmake --build build -j$(sysctl -n hw.ncpu)`)
- [x] Write `validation/scripts/download-models.sh`: download from HuggingFace with Range-request resume + SHA256 verify — Gemma 4 E2B GGUF Q4_K_M (~1.5 GB), Q8_0 (~3 GB), BF16 (~5 GB); target `validation/models/`

## Test Audio

- [x] Write `validation/audio/README.md` documenting required samples: `short-en-clean.wav` (2s baseline), `short-en-noisy.wav` (2s noise), `medium-en-clean.wav` (15s multi-sentence), `long-en-clean.wav` (60s paragraph), `short-ru-clean.wav` (2s Russian), `filler-en.wav` (5s filler words), `repeat-en.wav` (5s repetition), `silence.wav` (3s silence edge case) — all 16kHz/16-bit/mono WAV
- [x] Write `validation/scripts/generate-test-audio.sh`: use macOS `say` to generate synthetic samples where possible, document which need manual recording

## Benchmark Scripts

- [x] Write `validation/scripts/test-mmproj.sh`: investigate llama.cpp mmproj API for audio support; document commands in `mmproj-test.log` with PASS/FAIL verdict
- [x] Write `validation/scripts/test-litert.sh` (contingency): only needed if mmproj fails
- [x] Write `validation/scripts/benchmark-wer.sh`: for each quantization (Q4_K_M, Q8_0, BF16) run inference on all `*-en-clean.wav`, compare to ground truth; exit with error if ground-truth.txt absent; WER via Levenshtein; output `wer-results.csv`; thresholds: NO-GO if best WER > 15%, recommend Q8_0 if Q4_K_M >5pp worse than BF16
- [x] Write `validation/scripts/wer.py`: Python WER helper (rolling-array Levenshtein, O(m) space)
- [x] Write `validation/scripts/benchmark-latency.sh`: 5 iterations per sample, measure load/eval/wall clock, target <2.0s, output `latency-results.csv`
- [x] Write `validation/scripts/benchmark-repetition.sh`: 4-gram overlap between sentence pairs (overlap coefficient >60% = repetition), output `repetition-results.csv`

## Decision Template

- [x] Write `validation/DECISION.md` template: mmproj status, quant comparison table, repetition section, WER threshold check, Path A verdict (GO/NO-GO/CONDITIONS), next steps

## Human: Record + Run + Decide

- [x] Write ground truth in `validation/audio/ground-truth.txt` (6 of 8 samples; short-ru-clean + short-en-noisy pending manual recording)
- [x] Run `bash validation/scripts/build-deps.sh` — llama.cpp built with Metal ✓
- [x] Q8_0 and BF16 removed from plan — Q4_K_M quality confirmed acceptable; Q4_K_M + mmproj ✓
- [x] Run `bash validation/scripts/test-mmproj.sh` — **PASS** (llama-cli with --mmproj --audio, llama-mtmd-cli also built)
- [x] Record `validation/audio/short-ru-clean.wav` (macOS `say` Milena) and `short-en-noisy.wav` (real human voice via yt-dlp + pink noise)
- [x] Run `bash validation/scripts/benchmark-wer.sh` — avg WER 13.9%, **GO** (threshold 15%)
- [x] Run `bash validation/scripts/benchmark-latency.sh` — cold-start 11.7s avg, eval-only ~6s; **CONDITIONS** (persistent process required for <2s)
- [x] Run `bash validation/scripts/benchmark-repetition.sh` — 0/11 flagged, **GO**
- [x] Fill all sections of `validation/DECISION.md` — **Path A: CONDITIONS** (GO on accuracy + repetition, latency requires persistent model)
