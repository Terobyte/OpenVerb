# validation/audio/

Test WAV samples for Gemma 4 E2B audio inference benchmarks.

All files must be **16 kHz / 16-bit signed PCM / mono** WAV. This matches the sample rate
Gemma 4 audio is configured for (16 kHz) and ensures that any resampling is done
explicitly by the caller, not implicitly inside the decoder, so benchmark conditions are
fully reproducible and controlled.

---

## Required Samples

| Filename | Duration | Language | Condition | Purpose |
|---|---|---|---|---|
| `short-en-clean.wav` | ~2 s | English | Clean | Baseline latency reference — single short sentence with no background noise |
| `short-en-noisy.wav` | ~2 s | English | Noisy | Robustness check — same or equivalent sentence recorded or mixed with ambient noise (~10 dB SNR) |
| `medium-en-clean.wav` | ~15 s | English | Clean | Multi-sentence fluency — 3–4 sentences covering punctuation and prosodic variety |
| `long-en-clean.wav` | ~60 s | English | Clean | Paragraph stress test — continuous speech to expose context-window clipping and memory pressure |
| `short-ru-clean.wav` | ~2 s | Russian | Clean | Multilingual baseline — single short Russian sentence, tests Cyrillic token path |
| `filler-en.wav` | ~5 s | English | Filler words | Disfluency handling — contains "um", "uh", "like", "you know" to measure how the model handles non-lexical fillers |
| `repeat-en.wav` | ~5 s | English | Repetition | Repetition artifact detection — either a deliberately repeated phrase or a sentence designed to trigger looping output |
| `silence.wav` | ~3 s | — | Silence | Edge case — pure silence or near-silence; expected output is empty string or whitespace only |

---

## Format Specification

```
Sample rate : 16000 Hz
Bit depth   : 16-bit signed integer PCM
Channels    : 1 (mono)
Container   : WAV (RIFF/PCM, no compression)
```

Do **not** use MP3, AAC, OGG, or float32 WAV — convert to the spec above before running
any benchmark script.

### Quick conversion with ffmpeg

```bash
ffmpeg -i input.mp3 -ar 16000 -ac 1 -sample_fmt s16 output.wav
```

### Verify with soxi (part of SoX)

```bash
soxi short-en-clean.wav
# Expected: Sample Rate: 16000, Channels: 1, Encoding: 16-bit Signed Integer PCM
```

---

## Ground Truth

`ground-truth.txt` (planned — not yet added to the repo) will live in this same directory
and hold one pipe-delimited entry per audio file:

```
filename|expected text
short-en-clean.wav|Hello, this is a short test sentence.
short-en-noisy.wav|Hello, this is a short test sentence.
medium-en-clean.wav|The quick brown fox jumps over the lazy dog. ...
long-en-clean.wav|...
short-ru-clean.wav|Привет, это короткое тестовое предложение.
filler-en.wav|Um, I think, uh, you know, this is a test.
repeat-en.wav|The cat sat on the mat. The cat sat on the mat.
silence.wav|
```

`silence.wav` intentionally has an empty expected transcript.

`benchmark-wer.sh` (planned — not yet present in the repo) is intended to exit with a
non-zero status if `ground-truth.txt` does not exist, so missing ground truth is caught
immediately rather than silently skipped.

---

## Generating Samples

`validation/scripts/generate-test-audio.sh` is a planned helper (not yet present in the
repo) that will use macOS `say` to synthesise the English samples automatically and
document which ones (Russian, noisy) require manual recording.

Once it has been added, run it from the repository root:

```bash
bash validation/scripts/generate-test-audio.sh
```

Manually recorded samples (microphone required):
- `short-ru-clean.wav` — macOS `say` does not support Russian by default
- `short-en-noisy.wav` — requires real ambient noise or offline noise mixing

---

## Decision Thresholds (from requirements.md)

| Metric | Threshold |
|---|---|
| WER on clean English samples | ≤ 15% → GO |
| End-to-end latency (M3 Pro) | < 2.0 s → GO |
| Repetition 4-gram overlap rate | < threshold defined in benchmark script |
