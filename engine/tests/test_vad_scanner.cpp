#include <gtest/gtest.h>

#include <cmath>
#include <random>
#include <vector>

#include "audio/vad_scanner.h"

static constexpr int kSampleRate = 16000;
static constexpr int kFrameSize  = 480;

static std::vector<int16_t> silence_samples(int ms) {
    return std::vector<int16_t>(static_cast<size_t>(ms * kSampleRate / 1000), 0);
}

static std::vector<int16_t> speech_samples(int ms, unsigned seed = 42u) {
    int total = ms * kSampleRate / 1000;
    std::mt19937 rng(seed);
    std::uniform_int_distribution<int> dist(-32000, 32000);
    std::vector<int16_t> out(static_cast<size_t>(total));
    for (int i = 0; i < total; ++i) {
        out[static_cast<size_t>(i)] = static_cast<int16_t>(dist(rng));
    }
    return out;
}

class VadScannerCallbackCapture {
public:
    std::vector<Chunk> chunks;
    void operator()(Chunk c) { chunks.push_back(std::move(c)); }
};

static void feed_frames(VadScanner& scanner, const std::vector<int16_t>& audio) {
    for (size_t offset = 0; offset + kFrameSize <= audio.size(); offset += kFrameSize) {
        scanner.push_frame(audio.data() + offset, kFrameSize);
    }
}

TEST(VadScannerTest, NoSpeechProducesNoChunks) {
    VadScannerCallbackCapture capture;
    VadScanner scanner([&](Chunk c) { capture(c); }, 0);

    auto silence = silence_samples(5000);
    feed_frames(scanner, silence);

    EXPECT_TRUE(capture.chunks.empty());
}

TEST(VadScannerTest, ContinuousSpeechProducesSingleChunkAtMaxChunkMs) {
    VadScannerCallbackCapture capture;
    VadScanner scanner([&](Chunk c) { capture(c); }, 0);

    auto speech = speech_samples(MAX_CHUNK_MS + 1000);
    feed_frames(scanner, speech);

    ASSERT_GE(capture.chunks.size(), 1u);
    EXPECT_GE(capture.chunks[0].duration_ms, MAX_CHUNK_MS);
}

TEST(VadScannerTest, SilenceBoundarySplitsIntoTwoChunks) {
    VadScannerCallbackCapture capture;
    VadScanner scanner([&](Chunk c) { capture(c); }, 0);

    auto speech1 = speech_samples(MIN_CHUNK_MS + 1000);
    feed_frames(scanner, speech1);

    auto silence = silence_samples(SILENCE_BOUNDARY_MS + 1000);
    feed_frames(scanner, silence);

    auto speech2 = speech_samples(MIN_CHUNK_MS + 1000, 99u);
    feed_frames(scanner, speech2);

    scanner.flush();

    ASSERT_GE(capture.chunks.size(), 2u);
}

// Regression: after a silence-boundary emit, trailing silence must not become
// a second (silence-only) final chunk when flush() is called.
TEST(VadScannerTest, SpeechThenLongSilenceThenFlushProducesExactlyOneChunk) {
    VadScannerCallbackCapture capture;
    VadScanner scanner([&](Chunk c) { capture(c); }, 0);

    // Enough speech to satisfy MIN_CHUNK_MS threshold
    auto speech = speech_samples(MIN_CHUNK_MS + 1000);
    feed_frames(scanner, speech);

    // Silence long enough to trigger a boundary emit
    auto silence = silence_samples(SILENCE_BOUNDARY_MS + 500);
    feed_frames(scanner, silence);

    // At this point one chunk should already have been emitted.
    ASSERT_EQ(capture.chunks.size(), 1u);
    EXPECT_FALSE(capture.chunks[0].is_final);

    // More trailing silence followed by flush must NOT emit a second chunk.
    auto trailing_silence = silence_samples(1000);
    feed_frames(scanner, trailing_silence);

    scanner.flush();

    EXPECT_EQ(capture.chunks.size(), 1u) << "flush() must not emit a silence-only final chunk";
}

TEST(VadScannerTest, FinalFlushEmitsIsFinalChunkEvenIfBelowMinChunkMs) {
    VadScannerCallbackCapture capture;
    VadScanner scanner([&](Chunk c) { capture(c); }, 0);

    auto speech = speech_samples(500);
    feed_frames(scanner, speech);

    scanner.flush();

    ASSERT_FALSE(capture.chunks.empty());
    EXPECT_TRUE(capture.chunks.back().is_final);
    EXPECT_LT(capture.chunks.back().duration_ms, MIN_CHUNK_MS);
}
