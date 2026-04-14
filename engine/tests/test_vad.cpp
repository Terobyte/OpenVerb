#include <gtest/gtest.h>

#include <cmath>
#include <cstdint>
#include <random>
#include <vector>

#include "audio/reader.h"
#include "audio/vad.h"

static constexpr int kSampleRate = 16000;
static constexpr int kFrameMs   = 30;
static constexpr int kFrameSize = kSampleRate * kFrameMs / 1000;

static std::vector<int16_t> noise_samples(int n, int16_t amplitude = 32000)
{
    std::mt19937 rng(42u);
    std::uniform_int_distribution<int> dist(-static_cast<int>(amplitude),
                                             static_cast<int>(amplitude));
    std::vector<int16_t> out(static_cast<std::size_t>(n));
    for (int i = 0; i < n; ++i) {
        out[static_cast<std::size_t>(i)] = static_cast<int16_t>(dist(rng));
    }
    return out;
}

static AudioData make_audio(std::vector<int16_t> samples)
{
    AudioData ad;
    ad.sample_rate     = kSampleRate;
    ad.channels        = 1;
    ad.bits_per_sample = 16;
    ad.samples         = std::move(samples);
    return ad;
}

static AudioData make_silence(int n_samples)
{
    return make_audio(std::vector<int16_t>(static_cast<std::size_t>(n_samples), 0));
}

TEST(IsSpeech, SilenceReturnsFalse) {
    Vad vad;
    std::vector<int16_t> frame(static_cast<std::size_t>(kFrameSize), 0);
    EXPECT_FALSE(vad.is_speech(frame.data(), kFrameSize));
}

TEST(IsSpeech, SineWaveReturnsSpeech) {
    Vad vad(/*mode=*/0, kSampleRate);

    // Generate a 440 Hz sine wave — a pure tone well within the speech
    // frequency range (85–8000 Hz).  Mode 0 (least aggressive) should
    // classify it as speech within a handful of 30 ms frames.
    constexpr int    kNumFrames    = 50;
    constexpr int    kTotalSamples = kNumFrames * kFrameSize;
    constexpr double kFreqHz       = 440.0;
    constexpr double kAmplitude    = 16000.0;
    const double     two_pi        = 2.0 * std::acos(-1.0);

    std::vector<int16_t> sine(static_cast<std::size_t>(kTotalSamples));
    for (int i = 0; i < kTotalSamples; ++i) {
        sine[static_cast<std::size_t>(i)] = static_cast<int16_t>(
            kAmplitude * std::sin(two_pi * kFreqHz * i / kSampleRate));
    }

    bool detected = false;
    for (int i = 0; i < kNumFrames && !detected; ++i) {
        detected = vad.is_speech(sine.data() + i * kFrameSize, kFrameSize);
    }
    EXPECT_TRUE(detected)
        << "440 Hz sine wave at 16 kHz not classified as speech within "
        << kNumFrames << " frames (mode 0)";
}

TEST(Filter, SilenceOnlyReturnsEmpty) {
    Vad vad;
    AudioData audio = make_silence(kSampleRate * 2);
    auto result = vad.filter(audio, kSampleRate);
    EXPECT_TRUE(result.empty());
}

TEST(Filter, SpeechSilenceSpeechPreservesBothSegments) {
    Vad vad(/*mode=*/0, kSampleRate);

    constexpr int kBlockA = 12;
    // kGap must exceed over_hang_max_1 (8 frames for mode 0) PLUS
    // silence_frame_limit = VAD_SILENCE_MS / kFrameMs = 500/30 = 16 frames → total 24.
    // 30 frames (900 ms) provides a clear margin so the gap forces separation.
    constexpr int kGap    = 30;
    constexpr int kBlockB = 10;

    std::mt19937 rng_a(42u);
    std::uniform_int_distribution<int> dist(-32000, 32000);

    std::vector<int16_t> combined;

    auto gen_block = [&](int n_frames, std::mt19937& rng) -> std::vector<int16_t> {
        std::vector<int16_t> block(static_cast<std::size_t>(n_frames * kFrameSize));
        for (auto& s : block) s = static_cast<int16_t>(dist(rng));
        return block;
    };

    auto a = gen_block(kBlockA, rng_a);
    combined.insert(combined.end(), a.begin(), a.end());

    std::vector<int16_t> gap(static_cast<std::size_t>(kGap * kFrameSize), 0);
    combined.insert(combined.end(), gap.begin(), gap.end());

    std::mt19937 rng_b(99u);
    auto b = gen_block(kBlockB, rng_b);
    combined.insert(combined.end(), b.begin(), b.end());

    AudioData audio = make_audio(combined);
    auto result = vad.filter(audio, kSampleRate);

    EXPECT_FALSE(result.empty())
        << "Expected non-empty output from two speech blocks totalling "
        << (kBlockA + kBlockB) << " candidate frames";

    // WebRTC VAD over_hang_max_1 = 8 frames for mode 0: if block B were
    // dropped, the output would be at most (kBlockA + 8) frames.  Requiring
    // strictly more than that guarantees block B's samples are present.
    const std::size_t block_a_plus_overhang =
        static_cast<std::size_t>((kBlockA + 8) * kFrameSize);
    EXPECT_GT(result.size(), block_a_plus_overhang)
        << "Output (" << result.size() << " samples) does not exceed "
        << "block A + max over-hang (" << block_a_plus_overhang << " samples); "
        << "block B may not have been preserved";

    // Upper bound: kGap (30) > over_hang_max_1 (8) + silence_frame_limit (16),
    // so the gap forces a clean segment break and no gap silence enters output.
    // Maximum output = block A + 8 over-hang + block B + 8 over-hang.
    const std::size_t max_samples =
        static_cast<std::size_t>((kBlockA + 9 + kBlockB) * kFrameSize);
    EXPECT_LE(result.size(), max_samples);
}

TEST(Filter, AudioShorterThan30msNoCrash) {
    Vad vad;
    AudioData audio = make_silence(/*n_samples=*/100);
    std::vector<int16_t> result;
    ASSERT_NO_THROW(result = vad.filter(audio, kSampleRate));
    EXPECT_TRUE(result.empty());
}
