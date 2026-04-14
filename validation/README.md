# validation/

End-to-end validation of Gemma 4 E2B audio-native inference via llama.cpp on Apple Silicon.

This directory contains scripts, test audio, and benchmark results for MVP 0 — proving that Gemma 4 E2B works for audio transcription through llama.cpp's mmproj path. No product code lives here.

## Hardware Requirements

- Apple Silicon Mac (M1 Pro or better recommended)
- At least 8 GB unified memory (16 GB for BF16 model)
- macOS 13+ (Ventura or later for Metal 3)
- ~17 GB free disk space for models

## Directory Layout

```
validation/
  scripts/       — Shell and Python scripts (build, download, benchmark)
  results/       — CSV and log output from benchmark runs
  audio/         — Test WAV samples (16 kHz / 16-bit / mono)
  models/        — Downloaded GGUF model files (gitignored)
  deps/          — llama.cpp build tree (gitignored)
```

## How to Run

### 1. Build llama.cpp

```bash
bash validation/scripts/build-deps.sh
```

Clones llama.cpp (latest stable tag) into `validation/deps/llama.cpp/` and builds with Metal GPU acceleration. Pins the compiler to Apple clang via `xcrun` to avoid misdetected toolchains.

### 2. Download Models

```bash
bash validation/scripts/download-models.sh
```

Downloads Gemma 4 E2B GGUF files (Q4_K_M, Q8_0, BF16) from HuggingFace into `validation/models/`. Supports Range-request resume for interrupted downloads. SHA256 hashes are sourced from the HuggingFace LFS metadata and hardcoded in `expected_sha256()` — downloads are verified automatically on first run. If the upstream files change, update the hashes in that function to match.

### 3. Prepare Test Audio

Place WAV samples (16 kHz / 16-bit / mono) in `validation/audio/` with expected transcripts.

### 4. Test mmproj audio path

```bash
bash validation/scripts/test-mmproj.sh
```

Tests whether `llama-mtmd-cli` / `llama-cli` accept audio via `--mmproj`. Writes verdict
(`PASS` / `FAIL`) to `validation/results/mmproj-verdict.txt` and full log to
`validation/results/mmproj-test.log`.

### 5. Benchmark WER

```bash
bash validation/scripts/benchmark-wer.sh
```

Runs inference on all `*-en-clean.wav` samples for each quantization, computes WER against
`validation/audio/ground-truth.txt`, and writes `validation/results/wer-results.csv`.
Exits with error if ground-truth.txt is missing. Prints GO / NO-GO verdict against the
15% absolute WER threshold.

### 6. Benchmark Latency

```bash
bash validation/scripts/benchmark-latency.sh
```

Runs 5 iterations per sample per quantization, records model load time, eval time, and
wall-clock time. Writes `validation/results/latency-results.csv`. Target: < 2000 ms.

### 7. Benchmark Repetition

```bash
bash validation/scripts/benchmark-repetition.sh
```

Runs inference on all samples, splits output into sentences, checks 4-gram overlap between
all sentence pairs. Flags repetition when overlap coefficient > 60%. Writes
`validation/results/repetition-results.csv`.

### 8. Fill DECISION.md

Open `validation/DECISION.md` and fill in all sections with results from the benchmark
CSVs, then make the GO / NO-GO / CONDITIONS decision for Path A.
