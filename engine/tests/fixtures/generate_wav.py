#!/usr/bin/env python3
"""Generate WAV test fixtures for OpenVerb engine tests.

Run once to regenerate the committed binary fixtures:

    python3 engine/tests/fixtures/generate_wav.py

Outputs (same directory as this script):
    sine_440hz.wav  – 440 Hz sine, mono,   44100 Hz, 16-bit PCM, 0.25 s  (~21 KB)
    silence.wav     – all-zero silence, mono,   16000 Hz, 16-bit PCM, 0.25 s  (~8 KB)
    stereo.wav      – 440 Hz L / 880 Hz R,  stereo, 44100 Hz, 16-bit PCM, 0.25 s  (~43 KB)

Total on disk: < 100 KB.

Requires: Python 3.6+, standard library only (math, os, struct).
DO NOT add this script as a CMake build step — the pre-generated WAV files
are committed to the repo so that building requires no Python dependency.
"""

import math
import os
import struct


def _write_wav(path: str, samples: list, num_channels: int, sample_rate: int,
               bits_per_sample: int = 16) -> None:
    """Write a list of integer PCM samples to a canonical WAV file.

    For stereo, samples must be interleaved: [L0, R0, L1, R1, ...].
    Samples are clamped to [-32768, 32767] before encoding.
    """
    bytes_per_sample = bits_per_sample // 8
    data_size = len(samples) * bytes_per_sample
    byte_rate = sample_rate * num_channels * bytes_per_sample
    block_align = num_channels * bytes_per_sample

    with open(path, "wb") as f:
        # RIFF chunk descriptor
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_size))  # chunk size = file size - 8
        f.write(b"WAVE")

        # fmt sub-chunk  (16 bytes for PCM)
        f.write(b"fmt ")
        f.write(struct.pack("<I", 16))              # sub-chunk size
        f.write(struct.pack("<H", 1))               # audio format: PCM = 1
        f.write(struct.pack("<H", num_channels))
        f.write(struct.pack("<I", sample_rate))
        f.write(struct.pack("<I", byte_rate))
        f.write(struct.pack("<H", block_align))
        f.write(struct.pack("<H", bits_per_sample))

        # data sub-chunk
        f.write(b"data")
        f.write(struct.pack("<I", data_size))
        for s in samples:
            clamped = max(-32768, min(32767, int(round(s))))
            f.write(struct.pack("<h", clamped))


def _sine_samples(freq_hz: float, duration_s: float, sample_rate: int,
                  amplitude: int = 32767) -> list:
    n = int(sample_rate * duration_s)
    two_pi_f = 2.0 * math.pi * freq_hz
    return [amplitude * math.sin(two_pi_f * t / sample_rate) for t in range(n)]


def main() -> None:
    out_dir = os.path.dirname(os.path.abspath(__file__))

    # ------------------------------------------------------------------
    # 1. sine_440hz.wav  —  440 Hz, mono, 44100 Hz, 0.25 s
    #    Used by: test_reader (valid WAV read, 44.1 kHz sample-rate check)
    #             test_resampler (44100 → 16000 output-count check)
    # ------------------------------------------------------------------
    samples_sine = _sine_samples(440.0, 0.25, 44100)
    path_sine = os.path.join(out_dir, "sine_440hz.wav")
    _write_wav(path_sine, samples_sine, num_channels=1, sample_rate=44100)
    size_sine = os.path.getsize(path_sine)
    print(f"  sine_440hz.wav  : {len(samples_sine):>6} samples, {size_sine:>6} bytes")

    # ------------------------------------------------------------------
    # 2. silence.wav  —  all zeros, mono, 16000 Hz, 0.25 s
    #    Used by: test_reader (valid WAV read)
    #             test_resampler (16 kHz mono passthrough)
    #             test_vad  (silence → is_speech=false, filter → empty)
    # ------------------------------------------------------------------
    n_silence = int(16000 * 0.25)
    samples_silence = [0] * n_silence
    path_silence = os.path.join(out_dir, "silence.wav")
    _write_wav(path_silence, samples_silence, num_channels=1, sample_rate=16000)
    size_silence = os.path.getsize(path_silence)
    print(f"  silence.wav     : {len(samples_silence):>6} samples, {size_silence:>6} bytes")

    # ------------------------------------------------------------------
    # 3. stereo.wav  —  440 Hz L / 880 Hz R, stereo, 44100 Hz, 0.25 s
    #    Used by: test_reader (channels=2 check)
    #             test_resampler (stereo→mono, 44100→16000 stereo path)
    # ------------------------------------------------------------------
    n_stereo = int(44100 * 0.25)
    samples_left  = _sine_samples(440.0, 0.25, 44100)
    samples_right = _sine_samples(880.0, 0.25, 44100)
    samples_stereo = []
    for l, r in zip(samples_left, samples_right):
        samples_stereo.append(l)
        samples_stereo.append(r)
    path_stereo = os.path.join(out_dir, "stereo.wav")
    _write_wav(path_stereo, samples_stereo, num_channels=2, sample_rate=44100)
    size_stereo = os.path.getsize(path_stereo)
    print(f"  stereo.wav      : {n_stereo:>6} frames,  {size_stereo:>6} bytes")

    total = size_sine + size_silence + size_stereo
    print(f"  total           : {total:>6} bytes  ({total / 1024:.1f} KB)")
    assert total < 100 * 1024, f"fixtures exceed 100 KB budget: {total} bytes"
    print("  OK — all fixtures written, total < 100 KB")


if __name__ == "__main__":
    main()
