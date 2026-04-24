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

// With force-emit at LIVE_EMIT_MS (1500 ms), continuous speech splits into many
// live partial chunks — one every LIVE_EMIT_MS — instead of a single chunk at
// MAX_CHUNK_MS.  The total duration across all chunks must still cover the
// entire audio; MAX_CHUNK_MS now only acts as a backstop for pathological
// never-splits cases (VAD constantly firing without ever triggering a live or
// silence boundary, which cannot happen while LIVE_EMIT_MS < MAX_CHUNK_MS).
TEST(VadScannerTest, ContinuousSpeechSplitsIntoLivePartials) {
    VadScannerCallbackCapture capture;
    VadScanner scanner([&](Chunk c) { capture(c); }, 0);

    auto speech = speech_samples(MAX_CHUNK_MS + 1000);
    feed_frames(scanner, speech);

    ASSERT_GE(capture.chunks.size(), 5u)
        << "continuous speech must produce many live partials, not one fat chunk";
    int total_ms = 0;
    for (const auto& c : capture.chunks) {
        total_ms += c.duration_ms;
        EXPECT_LE(c.duration_ms, LIVE_EMIT_MS + 150)
            << "each chunk must be bounded by LIVE_EMIT_MS (got " << c.duration_ms << ")";
    }
    EXPECT_GE(total_ms, MAX_CHUNK_MS)
        << "total audio across chunks must cover the input (got " << total_ms << " ms)";
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

// After a silence-boundary emit, trailing silence must not become an extra
// (silence-only) final chunk — flush's peak gate drops all-zero buffers.
// Regression protection: Gemma hallucinates arbitrary text when handed a
// silent buffer, so the gate is also a UX safeguard.
//
// Note: the initial speech is MIN_CHUNK_MS+1000 = 4000 ms, which with force-
// emit at LIVE_EMIT_MS (1500 ms) produces ≥2 live partials before the silence
// boundary.  What matters here is that after flush() the chunk count does NOT
// grow — the trailing silence is rejected by the peak gate.
TEST(VadScannerTest, SpeechThenLongSilenceThenFlushDoesNotEmitExtraSilenceChunk) {
    VadScannerCallbackCapture capture;
    VadScanner scanner([&](Chunk c) { capture(c); }, 0);

    auto speech = speech_samples(MIN_CHUNK_MS + 1000);
    feed_frames(scanner, speech);

    auto silence = silence_samples(SILENCE_BOUNDARY_MS + 500);
    feed_frames(scanner, silence);

    const size_t chunks_before_flush = capture.chunks.size();
    ASSERT_GE(chunks_before_flush, 1u) << "speech must emit at least one chunk";
    for (const auto& c : capture.chunks) {
        EXPECT_FALSE(c.is_final) << "pre-flush chunks must be partials";
    }

    auto trailing_silence = silence_samples(1000);
    feed_frames(scanner, trailing_silence);

    scanner.flush();

    EXPECT_EQ(capture.chunks.size(), chunks_before_flush)
        << "flush() must not emit a silence-only final chunk (Gemma hallucinates on silence)";
}

// When VAD never fires in_speech_ but the buffered audio has real signal
// (peak > threshold), flush emits anyway. This is the backstop for the
// WebRTC-VAD-underestimates-conversational-speech case: users with normal
// mic gain (peaks 3-9 k / 32767) would otherwise get silent drops every
// time VAD disagreed with reality about whether they were speaking.
TEST(VadScannerTest, FlushEmitsNonZeroBufferEvenIfVadNeverFired) {
    VadScannerCallbackCapture capture;
    // Use mode 3 (very aggressive) so VAD is likely to reject the input.
    VadScanner scanner([&](Chunk c) { capture(c); }, 3);

    // Low-amplitude periodic signal — ~1 k peak, below what mode-3 VAD
    // typically accepts but well above the flush peak threshold (500).
    std::vector<int16_t> audio(16000);  // 1 second
    for (size_t i = 0; i < audio.size(); ++i) {
        audio[i] = static_cast<int16_t>(1500.0 * sin(2.0 * M_PI * 220.0 * i / 16000.0));
    }
    feed_frames(scanner, audio);
    scanner.flush();

    ASSERT_FALSE(capture.chunks.empty())
        << "flush must emit when buffered audio has real signal, even if VAD rejected every frame";
    EXPECT_TRUE(capture.chunks.back().is_final);
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

// Force-emit fires every LIVE_EMIT_MS during continuous speech to keep the
// live HUD feeling responsive.  These chunks are partials (is_final=false)
// and are only used for HUD display; session.cpp runs one coherent inference
// over the full PCM buffer at end-of-audio for the FINAL transcript, so
// mid-utterance partials no longer corrupt the final text.
TEST(VadScannerTest, ContinuousSpeechEmitsLiveChunksAtLiveEmitMs) {
    VadScannerCallbackCapture capture;
    VadScanner scanner([&](Chunk c) { capture(c); }, 0);

    // 4.5 s of continuous speech — no silence boundary, should see ~3 live
    // partials at ~1500 ms each.
    auto speech = speech_samples(LIVE_EMIT_MS * 3);
    feed_frames(scanner, speech);

    ASSERT_GE(capture.chunks.size(), 2u)
        << "continuous speech must emit multiple live partials at LIVE_EMIT_MS cadence";
    for (const auto& c : capture.chunks) {
        EXPECT_FALSE(c.is_final) << "live partials must have is_final=false";
        EXPECT_LE(c.duration_ms, LIVE_EMIT_MS + 150)
            << "live chunks must be close to LIVE_EMIT_MS in length (got " << c.duration_ms << ")";
    }
}
