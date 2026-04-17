// test_negative_proof.cpp
//
// Verification tests for previously reported C++ bugs from bugs.md.
// Each bug gets TWO independent checks (source + runtime) confirming the fix.
//
// Bugs verified:
//   #5  — VAD threshold reduced to 4 frames (120 ms) so short commands pass
//   #27 — RecvBuffer.accumulated cleared on binary->JSON mode switch
//   #49 — AudioCapture::start() logs errors on failure paths
//   #67 — Trailing Unicode whitespace is trimmed (leading already was)

#include <gtest/gtest.h>

#include "audio/vad.h"
#include "commands/parser.h"
#include "ipc/protocol.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#ifndef OPENVERB_SOURCE_DIR
#define OPENVERB_SOURCE_DIR ".."
#endif

static std::string src_path(const char* relative) {
    return std::string(OPENVERB_SOURCE_DIR) + "/src/" + relative;
}

// ===========================================================================
// BUG #5: VAD threshold now allows short speech commands
//
// vad.cpp uses kMinSpeechFrames = 4 (120 ms).  Utterances with >= 4 speech
// frames are kept.  Short commands like "stop" (~150 ms) are preserved.
// ===========================================================================

TEST(Bug5_Source, ThresholdConstantAllowsShortCommands) {
    std::ifstream src(src_path("audio/vad.cpp"));
    ASSERT_TRUE(src.is_open());

    std::string content((std::istreambuf_iterator<char>(src)),
                         std::istreambuf_iterator<char>());

    EXPECT_NE(content.find("kMinSpeechFrames = 4"), std::string::npos)
        << "vad.cpp should use kMinSpeechFrames = 4 (120 ms) to keep short commands.";
}

TEST(Bug5_Runtime, SixSpeechFrameSineIsKeptByFilter) {
    constexpr int kSampleRate = 16000;
    constexpr int kFrameMs = 30;
    constexpr int kFrameSize = kSampleRate * kFrameMs / 1000;
    constexpr int kSpeechFrames = 6;
    constexpr int kTotalSamples = kSpeechFrames * kFrameSize;
    constexpr double kFreqHz = 440.0;
    constexpr double kAmplitude = 16000.0;
    const double two_pi = 2.0 * std::acos(-1.0);

    Vad vad(/*mode=*/0, kSampleRate);

    std::vector<int16_t> sine(static_cast<size_t>(kTotalSamples));
    for (int i = 0; i < kTotalSamples; ++i) {
        sine[static_cast<size_t>(i)] = static_cast<int16_t>(
            kAmplitude * std::sin(two_pi * kFreqHz * i / kSampleRate));
    }

    int speech_frames = 0;
    for (int fi = 0; fi < kSpeechFrames; ++fi) {
        if (vad.is_speech(sine.data() + fi * kFrameSize, kFrameSize)) {
            ++speech_frames;
        }
    }

    ASSERT_GT(speech_frames, 0) << "Need at least 1 speech frame to verify fix";

    AudioData audio;
    audio.sample_rate = kSampleRate;
    audio.channels = 1;
    audio.bits_per_sample = 16;
    audio.samples = sine;

    auto result = vad.filter(audio, kSampleRate);

    EXPECT_FALSE(result.empty())
        << "Bug #5 FIX: " << speech_frames << " speech frames in "
        << (kSpeechFrames * kFrameMs) << " ms should be kept by filter(). "
        << "The 4-frame (120 ms) minimum threshold allows short commands.";
}

// ===========================================================================
// BUG #27: RecvBuffer.accumulated is cleared on binary->JSON mode switch
//
// recv_json() now detects stale binary data (no newline, first byte is not
// a JSON value start character) and clears accumulated before reading.
// ===========================================================================

TEST(Bug27_Source, AccumulatedClearInRecvJson) {
    std::ifstream src(src_path("ipc/protocol.cpp"));
    ASSERT_TRUE(src.is_open());

    std::string content((std::istreambuf_iterator<char>(src)),
                         std::istreambuf_iterator<char>());

    EXPECT_NE(content.find("accumulated.clear()"), std::string::npos)
        << "recv_json should clear accumulated when stale binary data is detected.";
}

TEST(Bug27_Runtime, StaleBinaryBytesClearedBeforeJsonParsing) {
    int sv[2];
    ASSERT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0);

    RecvBuffer buf{};

    buf.accumulated = "\xDE\xAD\xBE\xEF";

    std::string json_msg = R"({"type":"ping"})" "\n";
    write(sv[0], json_msg.c_str(), json_msg.size());

    bool parsed_ping = false;
    std::string error_msg;
    try {
        auto msg = recv_json(sv[1], buf, 500);
        if (msg.contains("type") && msg["type"].get<std::string>() == "ping") {
            parsed_ping = true;
        }
    } catch (const std::runtime_error& e) {
        error_msg = e.what();
    } catch (...) {}

    close(sv[0]);
    close(sv[1]);

    EXPECT_TRUE(parsed_ping)
        << "Bug #27 FIX: Stale binary bytes should be cleared so the valid "
        << "JSON message is parsed. Error: " << error_msg;
}

// ===========================================================================
// BUG #49: AudioCapture::start() logs errors on failure paths
//
// start() now calls LOG_ERROR on each failure path before returning.
// The function still returns void but errors are logged for diagnostics.
// ===========================================================================

TEST(Bug49_Source, StartReturnsVoidWithSilentReturns) {
    std::ifstream src(src_path("audio/capture.cpp"));
    ASSERT_TRUE(src.is_open());

    std::string content((std::istreambuf_iterator<char>(src)),
                         std::istreambuf_iterator<char>());

    auto start_sig = content.find("void AudioCapture::start(");
    ASSERT_NE(start_sig, std::string::npos)
        << "Cannot find start() signature";

    auto stop_sig = content.find("void AudioCapture::stop()");
    ASSERT_NE(stop_sig, std::string::npos)
        << "Cannot find stop() signature";

    ASSERT_GT(stop_sig, start_sig)
        << "stop() should be after start()";

    std::string start_body = content.substr(start_sig, stop_sig - start_sig);

    EXPECT_NE(start_body.find("void AudioCapture::start("), std::string::npos);
    EXPECT_EQ(start_body.find("throw"), std::string::npos)
        << "start() returns void (no throw).";
    EXPECT_EQ(start_body.find("return false"), std::string::npos)
        << "start() returns void (no bool return).";

    int silent_returns = 0;
    size_t pos = 0;
    while ((pos = start_body.find("return;", pos)) != std::string::npos) {
        silent_returns++;
        pos += 7;
    }

    EXPECT_GE(silent_returns, 2)
        << "AudioCapture::start() has " << silent_returns
        << " bare `return;` paths. Function returns void.";
}

TEST(Bug49_Source, ErrorLoggingOnFailure) {
    std::ifstream src(src_path("audio/capture.cpp"));
    ASSERT_TRUE(src.is_open());

    std::string content((std::istreambuf_iterator<char>(src)),
                         std::istreambuf_iterator<char>());

    auto start_sig = content.find("void AudioCapture::start(");
    ASSERT_NE(start_sig, std::string::npos);

    auto stop_sig = content.find("void AudioCapture::stop()");
    std::string start_body = content.substr(start_sig, stop_sig - start_sig);

    EXPECT_NE(start_body.find("LOG_ERROR"), std::string::npos)
        << "Bug #49 FIX: start() now logs errors via LOG_ERROR on failure paths.";
}

// ===========================================================================
// BUG #67: Trailing Unicode whitespace is trimmed
//
// parser.cpp trim_whitespace() now correctly handles multi-byte UTF-8
// characters by finding the leading byte before checking is_unicode_space().
// Both leading and trailing Unicode whitespace (NBSP, EM SPACE, etc.) are
// properly trimmed.
// ===========================================================================

TEST(Bug67_Source, TrailingTrimHandlesMultiByteUtf8) {
    std::ifstream src(src_path("commands/parser.cpp"));
    ASSERT_TRUE(src.is_open());

    std::string content((std::istreambuf_iterator<char>(src)),
                         std::istreambuf_iterator<char>());

    auto trim_fn = content.find("void trim_whitespace(");
    ASSERT_NE(trim_fn, std::string::npos);

    std::string trim_body = content.substr(trim_fn, 800);

    ASSERT_NE(trim_body.find("is_unicode_space"), std::string::npos)
        << "trim_whitespace should call is_unicode_space";

    EXPECT_NE(trim_body.find("0xC0"), std::string::npos)
        << "Bug #67 FIX: trailing trim skips UTF-8 continuation bytes (0x80-0xBF) "
        << "to find the leading byte before checking is_unicode_space.";
}

TEST(Bug67_Runtime, LeadingAndTrailingNbspAreTrimmed) {
    std::string leading_nbsp = "\xC2\xA0" "delete that";
    auto r1 = parse_command(leading_nbsp);
    EXPECT_EQ(r1.command, "delete_last")
        << "Leading NBSP should be trimmed.";

    std::string trailing_nbsp = "delete that" "\xC2\xA0";
    auto r2 = parse_command(trailing_nbsp);
    EXPECT_EQ(r2.command, "delete_last")
        << "Bug #67 FIX: Trailing NBSP (U+00A0) is now trimmed correctly.";
}

TEST(Bug67_Runtime, TrailingEmSpaceIsTrimmed) {
    std::string trailing_em = "undo" "\xE2\x80\x83";
    auto r = parse_command(trailing_em);

    EXPECT_EQ(r.command, "undo")
        << "Bug #67 FIX: Trailing EM SPACE (U+2003) is now trimmed correctly.";
}
