// ---------------------------------------------------------------------------
// test_resampler.cpp — Unit tests for audio/resampler.h
//
// Coverage:
//   to_mono()
//     MonoInputReturnsCopy            — already mono → copy, channels==1
//     StereoInputAveragesChannels     — L=1000, R=3000 → mono=2000 per frame
//     ThreeChannelInputAverages       — three channels averaged correctly
//
//   resample()
//     SameStereoRateReturnsMono       — stereo @ 44100 → target 44100 → channels==1
//                                       (regression guard: was returning stereo before fix)
//     SameMonoRateReturnsCopy         — mono @ 16000 → target 16000 → unchanged copy
//     DownsampleOutputLength          — 44100 → 16000, verify output frame count
//     DownsampleOutputIsMono          — 44100 stereo → 16000 → channels==1
//     UpsampleOutputLength            — 8000 → 16000, verify output frame count
//     UpsampleOutputIsMono            — 8000 stereo → 16000 → channels==1
//     ZeroTargetRateThrows            — target_rate == 0 → runtime_error
//     NegativeTargetRateThrows        — target_rate < 0 → runtime_error
//     EmptyInputReturnsEmpty          — zero samples → zero samples out
// ---------------------------------------------------------------------------

#include <gtest/gtest.h>

#include <cstdint>
#include <stdexcept>
#include <vector>

#include "audio/resampler.h"
#include "audio/reader.h"   // AudioData

// ===========================================================================
// Helper: build a synthetic AudioData without any file I/O
// ===========================================================================

// make_audio — construct an AudioData with the given parameters.
//
//   channel_data — one inner vector per channel; all channels must be the
//                  same length.  The samples are interleaved (frame-major)
//                  in the returned AudioData, matching WAV/read_wav layout.
static AudioData make_audio(
    const std::vector<std::vector<int16_t>>& channel_data,
    int sample_rate,
    int bits_per_sample = 16)
{
    AudioData ad;
    ad.sample_rate     = sample_rate;
    ad.bits_per_sample = bits_per_sample;
    ad.channels        = static_cast<int>(channel_data.size());

    if (channel_data.empty()) {
        return ad;
    }

    const std::size_t frames = channel_data[0].size();
    ad.samples.resize(frames * channel_data.size());

    for (std::size_t f = 0; f < frames; ++f) {
        for (std::size_t c = 0; c < channel_data.size(); ++c) {
            ad.samples[f * channel_data.size() + c] = channel_data[c][f];
        }
    }

    return ad;
}

// make_mono — shorthand: single channel of N constant samples.
static AudioData make_mono(int sample_rate, int n_samples, int16_t value = 0)
{
    return make_audio({{std::vector<int16_t>(
        static_cast<std::size_t>(n_samples), value)}},
        sample_rate);
}

// make_stereo — shorthand: two channels of N constant samples.
static AudioData make_stereo(int sample_rate, int n_samples,
                              int16_t left = 1000, int16_t right = 3000)
{
    return make_audio(
        {std::vector<int16_t>(static_cast<std::size_t>(n_samples), left),
         std::vector<int16_t>(static_cast<std::size_t>(n_samples), right)},
        sample_rate);
}

// ===========================================================================
// Tests: to_mono
// ===========================================================================

TEST(ToMono, MonoInputReturnsCopy) {
    AudioData mono = make_mono(16000, 100, /*value=*/42);
    AudioData out  = to_mono(mono);

    EXPECT_EQ(out.channels,        1);
    EXPECT_EQ(out.sample_rate,     16000);
    EXPECT_EQ(out.bits_per_sample, 16);
    EXPECT_EQ(out.samples.size(),  100u);
    EXPECT_EQ(out.samples[0],      42);
    // Must be a copy; the original must be unmodified.
    EXPECT_EQ(mono.samples[0],     42);
}

TEST(ToMono, StereoInputAveragesChannels) {
    // L=1000, R=3000 → average per frame = 2000
    AudioData stereo = make_stereo(44100, 8, /*left=*/1000, /*right=*/3000);
    AudioData out    = to_mono(stereo);

    EXPECT_EQ(out.channels,       1);
    EXPECT_EQ(out.sample_rate,    44100);
    EXPECT_EQ(out.samples.size(), 8u);

    for (std::size_t i = 0; i < 8u; ++i) {
        EXPECT_EQ(out.samples[i], static_cast<int16_t>(2000))
            << "frame " << i << " unexpected";
    }
}

TEST(ToMono, ThreeChannelInputAverages) {
    // Channels: 300, 600, 900  → average = 600 per frame
    constexpr int N = 4;
    AudioData tri = make_audio(
        {std::vector<int16_t>(N, 300),
         std::vector<int16_t>(N, 600),
         std::vector<int16_t>(N, 900)},
        22050);
    AudioData out = to_mono(tri);

    EXPECT_EQ(out.channels,       1);
    EXPECT_EQ(out.samples.size(), static_cast<std::size_t>(N));
    for (int i = 0; i < N; ++i) {
        EXPECT_EQ(out.samples[static_cast<std::size_t>(i)],
                  static_cast<int16_t>(600))
            << "frame " << i << " unexpected";
    }
}

// ===========================================================================
// Tests: resample — same-rate path
// ===========================================================================

// REGRESSION GUARD: before the mono-first fix, resample() with identical
// rates would return the input as-is, preserving stereo channels.
// After the fix, the mono-first contract applies even on this path.
TEST(Resample, SameStereoRateReturnsMono) {
    AudioData stereo = make_stereo(44100, 64);
    AudioData out    = resample(stereo, /*target_rate=*/44100);

    EXPECT_EQ(out.channels,    1)
        << "resample() must always return channels==1 (mono-first contract)";
    EXPECT_EQ(out.sample_rate, 44100);
    // Frame count must equal the input frame count (no rate change).
    EXPECT_EQ(out.samples.size(), 64u);
}

TEST(Resample, SameMonoRateReturnsCopy) {
    AudioData mono = make_mono(16000, 64, /*value=*/100);
    AudioData out  = resample(mono, /*target_rate=*/16000);

    EXPECT_EQ(out.channels,       1);
    EXPECT_EQ(out.sample_rate,    16000);
    EXPECT_EQ(out.samples.size(), 64u);
    // Values must survive the copy unchanged.
    EXPECT_EQ(out.samples[0],  100);
    EXPECT_EQ(out.samples[63], 100);
}

// ===========================================================================
// Tests: resample — downsampling (44100 → 16000)
// ===========================================================================

TEST(Resample, DownsampleOutputLength) {
    // Expected frames = floor(n_in * dst / src) = floor(1024 * 16000 / 44100)
    constexpr int N_IN   = 1024;
    const     int N_OUT  = static_cast<int>(
        static_cast<double>(N_IN) * 16000.0 / 44100.0);

    AudioData mono = make_mono(44100, N_IN);
    AudioData out  = resample(mono, 16000);

    EXPECT_EQ(out.sample_rate,    16000);
    EXPECT_EQ(out.channels,       1);
    EXPECT_EQ(out.samples.size(), static_cast<std::size_t>(N_OUT));
}

TEST(Resample, DownsampleOutputIsMono) {
    AudioData stereo = make_stereo(44100, 512);
    AudioData out    = resample(stereo, 16000);

    EXPECT_EQ(out.channels,    1);
    EXPECT_EQ(out.sample_rate, 16000);
}

// ===========================================================================
// Tests: resample — 48kHz stereo → 16kHz mono (both conversions at once)
// ===========================================================================

// Verify that the pipeline performs both the channel downmix (stereo → mono)
// and the rate conversion (48 000 → 16 000) in a single resample() call,
// which is the typical path for e.g. microphone input captured at 48 kHz.
TEST(Resample, FortyEightKhzStereoToSixteenKhzMono) {
    constexpr int N_IN  = 960;   // 20 ms frame at 48 kHz
    const     int N_OUT = static_cast<int>(
        static_cast<double>(N_IN) * 16000.0 / 48000.0);  // = 320

    AudioData stereo = make_stereo(48000, N_IN);
    AudioData out    = resample(stereo, 16000);

    // Channel conversion
    EXPECT_EQ(out.channels,    1)
        << "48kHz stereo input must be downmixed to mono";
    // Rate conversion
    EXPECT_EQ(out.sample_rate, 16000)
        << "output must be at 16 kHz";
    // Output frame count
    EXPECT_EQ(out.samples.size(), static_cast<std::size_t>(N_OUT))
        << "expected " << N_OUT << " output frames";
}

// ===========================================================================
// Tests: resample — upsampling (8000 → 16000)
// ===========================================================================

TEST(Resample, UpsampleOutputLength) {
    // Expected frames = floor(n_in * dst / src) = floor(512 * 16000 / 8000) = 1024
    constexpr int N_IN  = 512;
    const     int N_OUT = static_cast<int>(
        static_cast<double>(N_IN) * 16000.0 / 8000.0);

    AudioData mono = make_mono(8000, N_IN);
    AudioData out  = resample(mono, 16000);

    EXPECT_EQ(out.sample_rate,    16000);
    EXPECT_EQ(out.channels,       1);
    EXPECT_EQ(out.samples.size(), static_cast<std::size_t>(N_OUT));
}

TEST(Resample, UpsampleOutputIsMono) {
    AudioData stereo = make_stereo(8000, 256);
    AudioData out    = resample(stereo, 16000);

    EXPECT_EQ(out.channels,    1);
    EXPECT_EQ(out.sample_rate, 16000);
}

// ===========================================================================
// Tests: resample — error handling
// ===========================================================================

TEST(Resample, ZeroTargetRateThrows) {
    AudioData mono = make_mono(16000, 16);
    EXPECT_THROW(resample(mono, 0), std::runtime_error);
}

TEST(Resample, NegativeTargetRateThrows) {
    AudioData mono = make_mono(16000, 16);
    EXPECT_THROW(resample(mono, -8000), std::runtime_error);
}

// A single-sample input is a degenerate but valid edge case.
// Cubic interpolation requires look-ahead/behind neighbours; the implementation
// must clamp indices and not crash on a 1-frame buffer.
TEST(Resample, SingleSampleInputNoCrash) {
    // Single sample at 44100 Hz downsampled to 16000 Hz.
    AudioData one = make_mono(44100, /*n_samples=*/1, /*value=*/32767);
    AudioData out;
    ASSERT_NO_THROW(out = resample(one, 16000));
    EXPECT_EQ(out.channels,    1);
    EXPECT_EQ(out.sample_rate, 16000);
    // 1 input frame at 44100 → floor(1 * 16000 / 44100) == 0 output frames;
    // the result may be empty but the call must not crash.
    // (An implementation that rounds up to 1 is also acceptable.)
    EXPECT_LE(out.samples.size(), 1u);
}

TEST(Resample, EmptyInputReturnsEmpty) {
    // AudioData with zero samples should produce zero samples out.
    AudioData empty;
    empty.sample_rate     = 44100;
    empty.channels        = 1;
    empty.bits_per_sample = 16;
    // empty.samples is default-constructed (size 0)

    AudioData out = resample(empty, 16000);
    EXPECT_EQ(out.samples.size(), 0u);
}
