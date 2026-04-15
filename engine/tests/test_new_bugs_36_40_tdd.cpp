// test_new_bugs_36_40_tdd.cpp — RED tests proving bugs 36-40 are real.
//
// Each test asserts CORRECT behavior and FAILS because the bug prevents it.
// When the bug is fixed, the test turns GREEN.

#include <gtest/gtest.h>

#include "audio/reader.h"
#include "audio/resampler.h"
#include "commands/parser.h"
#include "config/defaults.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// ===========================================================================
// BUG 36 — parse_command normalization order: trailing space after punct strip
// Severity: MEDIUM
// File: engine/src/commands/parser.cpp:67-69
//
// "delete that ." → trim → "delete that ." → strip '.' → "delete that "
// The trailing space prevents keyword match.  trim should run AFTER strip.
// ===========================================================================

TEST(Bug36_CommandNormOrder, SpaceBeforePunctCausesMismatch) {
    auto result = parse_command("delete that .");
    EXPECT_EQ(result.command, "delete_last")
        << "Expected command 'delete_last' but got plain text: '"
        << result.text << "'";
}

// ===========================================================================
// BUG 37 — WAV unknown chunk_size=0xFFFFFFFF uint32_t overflow in skip calc
// Severity: MEDIUM
// File: engine/src/audio/reader.cpp:146
//
// uint32_t skip = chunk_size + (chunk_size & 1u);
// 0xFFFFFFFF + 1 = 0 (overflow) → seekg(0) is no-op → parser misparses.
// File contains a valid data chunk after the oversized unknown chunk.
// ===========================================================================

TEST(Bug37_WavChunkOverflow, OversizedChunkSkipsPastDataChunk) {
    const std::string path = "/tmp/test_bug37_overflow.wav";
    {
        std::ofstream f(path, std::ios::binary);
        f.write("RIFF", 4);
        uint32_t riff_size = 0xFFFFFFFF;
        f.write(reinterpret_cast<const char*>(&riff_size), 4);
        f.write("WAVE", 4);

        f.write("fmt ", 4);
        uint32_t fmt_size = 16;
        f.write(reinterpret_cast<const char*>(&fmt_size), 4);
        uint16_t af = 1, ch = 1, ba = 2, bps = 16;
        uint32_t sr = 16000, br = 32000;
        f.write(reinterpret_cast<const char*>(&af), 2);
        f.write(reinterpret_cast<const char*>(&ch), 2);
        f.write(reinterpret_cast<const char*>(&sr), 4);
        f.write(reinterpret_cast<const char*>(&br), 4);
        f.write(reinterpret_cast<const char*>(&ba), 2);
        f.write(reinterpret_cast<const char*>(&bps), 2);

        f.write("JUNK", 4);
        uint32_t junk_size = 0xFFFFFFFF;
        f.write(reinterpret_cast<const char*>(&junk_size), 4);
        f.write("ABCD", 4);

        f.write("data", 4);
        uint32_t data_size = 4;
        f.write(reinterpret_cast<const char*>(&data_size), 4);
        int16_t s1 = 1000, s2 = 2000;
        f.write(reinterpret_cast<const char*>(&s1), 2);
        f.write(reinterpret_cast<const char*>(&s2), 2);
    }

    EXPECT_NO_THROW({
        auto audio = read_wav(path);
        EXPECT_EQ(audio.samples.size(), 2u);
    }) << "WAV with chunk_size=0xFFFFFFFF: overflow causes seekg(0) no-op, "
          "parser re-reads payload as chunk headers and misses the data chunk";

    std::remove(path.c_str());
}

// ===========================================================================
// BUG 38 — to_mono silently discards trailing samples when size % channels != 0
// Severity: LOW
// File: engine/src/audio/resampler.cpp:216
//
// frames = samples.size() / channels uses integer division.
// 3 stereo samples → 1 frame, sample at index 2 silently dropped.
// ===========================================================================

TEST(Bug38_ToMonoTrailingSamples, OddStereoSampleCountPreserved) {
    AudioData stereo;
    stereo.sample_rate = 16000;
    stereo.channels = 2;
    stereo.bits_per_sample = 16;
    stereo.samples = {1000, 2000, 3000};

    auto mono = to_mono(stereo);

    size_t expected =
        (stereo.samples.size() + static_cast<size_t>(stereo.channels) - 1)
        / static_cast<size_t>(stereo.channels);
    EXPECT_EQ(mono.samples.size(), expected)
        << "to_mono dropped " << stereo.samples.size() - mono.samples.size() * 2
        << " trailing sample(s)";
}

// ===========================================================================
// BUG 39 — resample_channel uses floor division for output length
// Severity: LOW
// File: engine/src/audio/resampler.cpp:162-164
//
// 48001 samples @ 48000 Hz → 16000 Hz:
//   floor(48001 * 16000 / 48000) = 16000
//   ceil (48001 * 16000 / 48000) = 16001
// The last sample is silently lost.
// ===========================================================================

TEST(Bug39_ResampleFloorTruncation, OutputLengthPreservesLastSample) {
    AudioData input;
    input.sample_rate = 48000;
    input.channels = 1;
    input.bits_per_sample = 16;
    input.samples.resize(48001, 1000);

    auto output = resample(input, 16000);

    double ratio = 16000.0 / 48000.0;
    size_t expected_min = static_cast<size_t>(
        std::ceil(static_cast<double>(input.samples.size()) * ratio));

    EXPECT_GE(output.samples.size(), expected_min)
        << "48001 samples @ 48kHz → 16kHz: expected >= " << expected_min
        << ", got " << output.samples.size();
}

// ===========================================================================
// BUG 40 — max_audio_secs goes negative when ctx_size < SYSTEM_PROMPT_TOKENS_RESERVED
// Severity: MEDIUM
// File: engine/src/ipc/session.cpp:76-78
//
// effective_ctx - 500 can be negative → negative max_audio_secs.
// Then dur >= max_audio_secs is always true → every frame rejected.
// ===========================================================================

TEST(Bug40_NegativeMaxAudioSecs, SmallCtxSizeDoesNotProduceNegativeDuration) {
    const int small_ctx = 100;
    const int effective_ctx = (small_ctx > 0) ? small_ctx : DEFAULT_CTX_SIZE;
    const double max_audio_secs =
        static_cast<double>(effective_ctx - SYSTEM_PROMPT_TOKENS_RESERVED)
        / static_cast<double>(AUDIO_TOKENS_PER_SEC);

    EXPECT_GE(max_audio_secs, 0.0)
        << "max_audio_secs = " << max_audio_secs << " for ctx_size=" << small_ctx
        << " — negative threshold means EVERY audio frame is immediately rejected";
}
