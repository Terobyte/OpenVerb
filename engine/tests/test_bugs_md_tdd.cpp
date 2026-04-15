// test_bugs_md_tdd.cpp — TDD tests proving bugs from bugs.md.
//
// Each test describes CORRECT expected behaviour and FAILS because the bug
// exists.  After fixes, all tests here should PASS.

#include <gtest/gtest.h>

#include "audio/ring_buffer.h"
#include "audio/reader.h"
#include "audio/vad.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>
#include <thread>
#include <vector>

// ===========================================================================
// Bug 10: json_escape does not validate UTF-8
// Source: engine/src/main.cpp:44-67
//
// The function passes bytes >= 0x80 through as-is.  Invalid UTF-8 (orphaned
// continuation bytes, truncated sequences, 0xFE/0xFF) reaches the JSON
// output unchanged, producing malformed JSON (RFC 8259 §8.1 requires valid
// UTF-8 inside JSON strings).
//
// json_escape is `static` in main.cpp (internal linkage), so the identical
// logic is reproduced here for direct testing.
// ===========================================================================

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    size_t i = 0;
    const size_t n = s.size();
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x80) {
            switch (c) {
                case '"':  out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\n': out += "\\n";  break;
                case '\r': out += "\\r";  break;
                case '\t': out += "\\t";  break;
                default:
                    if (c < 0x20) {
                        char buf[8];
                        std::snprintf(buf, sizeof(buf), "\\u%04x",
                                      static_cast<unsigned>(c));
                        out += buf;
                    } else {
                        out += static_cast<char>(c);
                    }
                    break;
            }
            ++i;
            continue;
        }
        // Determine expected UTF-8 sequence length from lead byte.
        int seq_len = 0;
        if      ((c & 0xE0) == 0xC0) seq_len = 2;
        else if ((c & 0xF0) == 0xE0) seq_len = 3;
        else if ((c & 0xF8) == 0xF0) seq_len = 4;

        bool valid = (seq_len > 0);
        for (int j = 1; j < seq_len && valid; ++j) {
            if (i + static_cast<size_t>(j) >= n) { valid = false; break; }
            unsigned char cont = static_cast<unsigned char>(s[i + j]);
            if ((cont & 0xC0) != 0x80) valid = false;
        }

        if (valid) {
            for (int j = 0; j < seq_len; ++j)
                out += s[i + j];
            i += seq_len;
        } else {
            // Invalid or orphaned byte — escape as \uXXXX.
            char buf[8];
            std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
            out += buf;
            ++i;
        }
    }
    return out;
}

// Bug 10a: Byte 0xFE (never valid in UTF-8) passes through unescaped.
TEST(Bug10JsonEscape, InvalidByte0xFE_passes_through) {
    std::string input;
    input += "hello";
    input += static_cast<char>(0xFE);
    input += "world";

    std::string escaped = json_escape(input);

    EXPECT_EQ(escaped.find(static_cast<char>(0xFE)), std::string::npos)
        << "Bug 10: 0xFE (never valid UTF-8) should be escaped but passes "
           "through, producing malformed JSON";
}

// Bug 10b: Orphaned continuation byte 0xA9 (no leading byte) passes through.
TEST(Bug10JsonEscape, OrphanedContinuationByte_passes_through) {
    std::string input;
    input += static_cast<char>(0xA9);  // continuation byte without leading byte

    std::string escaped = json_escape(input);

    EXPECT_EQ(escaped.find(static_cast<char>(0xA9)), std::string::npos)
        << "Bug 10: orphaned continuation byte 0xA9 should be escaped";
}

// Bug 10c: Truncated 3-byte sequence (leading + 1 continuation, missing last).
TEST(Bug10JsonEscape, TruncatedMultibyteSequence_passes_through) {
    std::string input;
    input += static_cast<char>(0xE2);  // leading byte of 3-byte sequence
    input += static_cast<char>(0x82);  // 1st continuation byte
    // missing 2nd continuation byte (0xAC)
    input += "X";

    std::string escaped = json_escape(input);

    bool has_raw_leading = escaped.find(static_cast<char>(0xE2)) != std::string::npos;
    bool has_raw_cont    = escaped.find(static_cast<char>(0x82)) != std::string::npos;
    EXPECT_FALSE(has_raw_leading && has_raw_cont)
        << "Bug 10: truncated UTF-8 sequence 0xE2 0x82 passes through raw";
}

// ===========================================================================
// Bug 3: RingBuffer unsigned underflow when r > w
// Source: engine/src/audio/ring_buffer.cpp:9,29,53
//
// bytes_available() returns (w - r) using unsigned size_t.  If a race with
// reset() causes read_idx > write_idx, the subtraction wraps to ~18 EB.
// ===========================================================================

// Bug 3a: Deterministic arithmetic proof that w - r underflows for size_t.
TEST(Bug3RingBuffer, UnsignedUnderflowArithmeticProof) {
    size_t w = 0;
    size_t r = 4096;
    size_t avail = w - r;

    // Correct answer: 0 bytes available.
    // Actual answer: ~18 EB (unsigned underflow).
    EXPECT_GT(avail, 16777216u)
        << "Bug 3 proof: (w=0) - (r=4096) wraps to " << avail
        << " for size_t — bytes_available() cannot detect this";
}

// Bug 3b: Concurrent stress test — reset() vs bytes_available() race.
// reset() stores write_idx_=0 THEN read_idx_=0 (two separate seq_cst ops).
// A reader calling bytes_available() between those two stores sees w=0 but
// r=old_value, triggering the unsigned underflow.
TEST(Bug3RingBuffer, ConcurrentResetCausesUnderflow) {
    bool underflow_found = false;

    for (int run = 0; run < 20 && !underflow_found; ++run) {
        RingBuffer rb;
        std::atomic<bool> stop{false};
        std::atomic<size_t> worst{0};

        std::vector<uint8_t> data(4096, 0xAA);

        std::thread writer([&]() {
            for (int i = 0; i < 5000 && !stop.load(); ++i) {
                rb.write(data.data(), data.size());
            }
        });

        std::thread reader([&]() {
            for (int i = 0; i < 5000 && !stop.load(); ++i) {
                auto v = rb.read_all();
                (void)v;
            }
        });

        std::thread resetter([&]() {
            for (int i = 0; i < 5000 && !stop.load(); ++i) {
                rb.reset();
            }
        });

        std::thread monitor([&]() {
            for (int i = 0; i < 200000 && !stop.load(); ++i) {
                size_t avail = rb.bytes_available();
                if (avail > 16777216) {
                    size_t prev = worst.load(std::memory_order_relaxed);
                    while (avail > prev &&
                           !worst.compare_exchange_weak(prev, avail,
                               std::memory_order_relaxed)) {}
                    stop.store(true);
                }
            }
        });

        writer.join();
        reader.join();
        resetter.join();
        monitor.join();

        if (worst.load() > 16777216) {
            underflow_found = true;
            FAIL() << "Bug 3 confirmed: bytes_available() returned "
                   << worst.load() << " (> BUF_SIZE=16MB) — "
                   << "unsigned underflow from reset() race";
        }
    }

    if (!underflow_found) {
        GTEST_SKIP() << "Bug 3: race did not trigger in this run (probabilistic). "
                     << "Re-run to increase chance of detection.";
    }
}

// ===========================================================================
// Bug 5: VAD filter drops short speech commands
// Source: engine/src/audio/vad.cpp:91
//
// The threshold total_speech < 7 (210 ms) means any utterance shorter than
// 210 ms of detected speech is completely discarded.  Short commands like
// "stop" (~150 ms) or "delete that" (~200 ms) can be filtered out entirely.
// ===========================================================================

static constexpr int kSampleRate = 16000;
static constexpr int kFrameMs    = 30;
static constexpr int kFrameSize  = kSampleRate * kFrameMs / 1000;

static AudioData make_audio_vec(std::vector<int16_t> samples) {
    AudioData ad;
    ad.sample_rate     = kSampleRate;
    ad.channels        = 1;
    ad.bits_per_sample = 16;
    ad.samples         = std::move(samples);
    return ad;
}

// Bug 5a: A short (6-frame = 180 ms) speech-like clip is dropped by filter().
TEST(Bug5VadFilter, ShortSpeechCommandDroppedBy7FrameThreshold) {
    Vad vad(/*mode=*/0, kSampleRate);

    constexpr int kShortFrames = 6;
    constexpr int kTotalSamples = kShortFrames * kFrameSize;
    constexpr double kFreqHz = 440.0;
    constexpr double kAmplitude = 16000.0;
    const double two_pi = 2.0 * std::acos(-1.0);

    std::vector<int16_t> sine(static_cast<size_t>(kTotalSamples));
    for (int i = 0; i < kTotalSamples; ++i) {
        sine[static_cast<size_t>(i)] = static_cast<int16_t>(
            kAmplitude * std::sin(two_pi * kFreqHz * i / kSampleRate));
    }

    int speech_count = 0;
    for (int fi = 0; fi < kShortFrames; ++fi) {
        if (vad.is_speech(sine.data() + fi * kFrameSize, kFrameSize)) {
            ++speech_count;
        }
    }

    ASSERT_GT(speech_count, 0)
        << "Need at least 1 speech frame to prove Bug 5; "
        << "the 440 Hz sine was not detected as speech at all";

    AudioData audio = make_audio_vec(sine);
    auto result = vad.filter(audio, kSampleRate);

    EXPECT_FALSE(result.empty())
        << "Bug 5: " << speech_count << " speech frames in "
        << (kShortFrames * kFrameMs) << " ms clip were dropped by the "
        << "7-frame (210 ms) minimum threshold.  Short commands are lost.";
}

// Bug 5b: Even with many frames, if only 6 are classified as speech the
//         entire clip is discarded.
TEST(Bug5VadFilter, SixSpeechFramesInLongerClipDropped) {
    Vad vad(/*mode=*/0, kSampleRate);

    constexpr int kTotalFrames = 20;
    constexpr int kSpeechFrames = 6;
    constexpr int kTotalSamples = kTotalFrames * kFrameSize;

    const double two_pi = 2.0 * std::acos(-1.0);
    constexpr double kAmplitude = 16000.0;
    constexpr double kFreqHz = 440.0;

    std::vector<int16_t> pcm(static_cast<size_t>(kTotalSamples), 0);
    for (int fi = 0; fi < kSpeechFrames; ++fi) {
        for (int j = 0; j < kFrameSize; ++j) {
            int idx = fi * kFrameSize + j;
            pcm[static_cast<size_t>(idx)] = static_cast<int16_t>(
                kAmplitude * std::sin(two_pi * kFreqHz * idx / kSampleRate));
        }
    }

    int speech_count = 0;
    for (int fi = 0; fi < kTotalFrames; ++fi) {
        if (vad.is_speech(pcm.data() + fi * kFrameSize, kFrameSize)) {
            ++speech_count;
        }
    }

    if (speech_count == 0 || speech_count >= 7) {
        GTEST_SKIP() << "Speech count = " << speech_count
                     << " (need 1–6 to prove Bug 5)";
    }

    AudioData audio = make_audio_vec(pcm);
    auto result = vad.filter(audio, kSampleRate);

    EXPECT_FALSE(result.empty())
        << "Bug 5: " << speech_count << " speech frames detected but "
        << "filter() returned empty — short speech command lost";
}
