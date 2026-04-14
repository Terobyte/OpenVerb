#pragma once

#include "audio/reader.h"  // AudioData

// ---------------------------------------------------------------------------
// resampler.h — sample-rate conversion and channel downmix for AudioData.
//
// All functions return a *new* AudioData copy; the input is never modified.
//
// Typical pipeline for Gemma ASR:
//   AudioData mono   = to_mono(raw);          // collapse stereo → mono
//   AudioData pcm16k = resample(mono, 16000); // resample to 16 kHz
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// to_mono — mix all channels down to a single mono channel.
//
//   Averages every channel frame into one sample.  For stereo:
//       mono[i] = (int16_t)((L[i] + R[i]) / 2)
//   Returns the input unchanged (as a copy) if already mono.
//
//   Output AudioData:
//       channels        = 1
//       sample_rate     = input.sample_rate   (unchanged)
//       bits_per_sample = input.bits_per_sample (unchanged)
// ---------------------------------------------------------------------------
AudioData to_mono(const AudioData& input);

// ---------------------------------------------------------------------------
// resample — convert the sample rate of a mono or multi-channel AudioData.
//
//   target_rate — desired output sample rate in Hz (default: 16 000).
//
//   Returns a mono copy — without rate conversion — when
//   input.sample_rate == target_rate.  The mono-first contract (see
//   below) still applies on this path: a stereo input at the target
//   rate is mixed down to mono and returned; it is NOT returned as-is.
//
//   Downsampling  (e.g. 44 100 → 16 000):
//     1. Applies a windowed-sinc (FIR) low-pass filter at the target Nyquist
//        frequency (target_rate / 2) to remove energy above the new Nyquist
//        before decimation.  This prevents aliasing artifacts that degrade
//        automatic speech recognition accuracy.
//        Kernel: 64-tap Blackman-windowed sinc, cut-off = target_rate/2.
//     2. Cubic (Catmull-Rom) interpolation over the filtered signal to land
//        at the precise output sample positions.
//
//   Upsampling  (e.g. 8 000 → 16 000):
//     Cubic interpolation alone — no low-pass pre-filter needed because
//     there is no risk of fold-back aliasing when increasing the rate.
//
//   Mono-first contract: if the input has more than one channel, resample()
//   internally calls to_mono() before any rate conversion.  The returned
//   AudioData is therefore always mono (channels == 1), regardless of the
//   channel count of the input.
//
//   Output AudioData:
//       sample_rate     = target_rate
//       channels        = 1                    (always mono)
//       bits_per_sample = input.bits_per_sample (unchanged)
// ---------------------------------------------------------------------------
AudioData resample(const AudioData& input, int target_rate = 16000);
