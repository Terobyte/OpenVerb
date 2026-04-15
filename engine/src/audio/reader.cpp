// ---------------------------------------------------------------------------
// reader.cpp — WAV / raw-PCM audio file ingestion
//
// Public API (declared in audio/reader.h):
//   read_wav()               — decode a RIFF/WAVE PCM file into AudioData
//   read_pcm()               — load a raw headerless 16-bit PCM file
//   peek_wav_duration_secs() — return duration from WAV header only (no alloc)
//
// WAV parsing supports:
//   • Any sample rate and channel count
//   • Only PCM (audio format code 1); μ-law, ADPCM, etc. → throws
//   • Unknown chunks (LIST, INFO, fact, JUNK, …) are skipped gracefully
//   • Odd-sized chunks are padded to even per the RIFF spec
// ---------------------------------------------------------------------------

#include "audio/reader.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

// ===========================================================================
// Internal helpers (anonymous namespace)
// ===========================================================================

namespace {

// Read exactly `n` bytes from `f`; throw if the stream runs out.
void must_read(std::ifstream& f, void* buf, std::size_t n, const char* ctx) {
    if (!f.read(static_cast<char*>(buf), static_cast<std::streamsize>(n)))
        throw std::runtime_error(std::string("WAV parse error (") + ctx +
                                 "): unexpected end of file");
}

uint16_t read_u16(std::ifstream& f, const char* ctx) {
    uint8_t b[2];
    must_read(f, b, 2, ctx);
    return static_cast<uint16_t>(b[0]) | (static_cast<uint16_t>(b[1]) << 8);
}

uint32_t read_u32(std::ifstream& f, const char* ctx) {
    uint8_t b[4];
    must_read(f, b, 4, ctx);
    return static_cast<uint32_t>(b[0])
         | (static_cast<uint32_t>(b[1]) << 8)
         | (static_cast<uint32_t>(b[2]) << 16)
         | (static_cast<uint32_t>(b[3]) << 24);
}

// ---------------------------------------------------------------------------
// WavFmt — result of parsing the RIFF/WAVE chunk tree
// ---------------------------------------------------------------------------

struct WavFmt {
    uint16_t audio_format;    // 1 = PCM
    uint16_t channels;
    uint32_t sample_rate;
    uint16_t bits_per_sample;
    uint32_t data_chunk_size; // byte count of the data payload
};

// ---------------------------------------------------------------------------
// scan_wav_header — shared by read_wav and peek_wav_duration_secs
//
// Parses the RIFF descriptor and then iterates through WAVE chunks until
// both 'fmt ' and 'data' have been located.  Unknown chunks are skipped.
// After returning, the file position is just past the 'data' chunk header
// (i.e. pointing at the first sample byte).
// ---------------------------------------------------------------------------

WavFmt scan_wav_header(std::ifstream& f) {
    // ── RIFF descriptor ─────────────────────────────────────────────────────
    char riff[4];
    must_read(f, riff, 4, "RIFF tag");
    if (std::memcmp(riff, "RIFF", 4) != 0)
        throw std::runtime_error("not a RIFF file");

    read_u32(f, "RIFF size");   // total file size minus 8; not used by reader

    char wave[4];
    must_read(f, wave, 4, "WAVE tag");
    if (std::memcmp(wave, "WAVE", 4) != 0)
        throw std::runtime_error("RIFF container is not WAVE");

    // ── Chunk scan ──────────────────────────────────────────────────────────
    WavFmt fmt{};
    bool   got_fmt  = false;
    bool   got_data = false;

    while (!got_data) {
        char id[4];
        if (!f.read(id, 4))
            throw std::runtime_error("WAV: reached end of file without a data chunk");

        uint32_t chunk_size = read_u32(f, "chunk size");

        if (std::memcmp(id, "fmt ", 4) == 0) {
            // ── fmt chunk ───────────────────────────────────────────────────
            if (chunk_size < 16)
                throw std::runtime_error("WAV: fmt chunk is too small");

            fmt.audio_format    = read_u16(f, "audio_format");
            fmt.channels        = read_u16(f, "channels");
            fmt.sample_rate     = read_u32(f, "sample_rate");
            read_u32(f, "byte_rate");    // byte_rate   (recomputable; skip)
            read_u16(f, "block_align");  // block_align (recomputable; skip)
            fmt.bits_per_sample = read_u16(f, "bits_per_sample");

            if (fmt.audio_format != 1)
                throw std::runtime_error(
                    "unsupported WAV format: only PCM (format 1) supported");

            if (fmt.channels == 0)
                throw std::runtime_error("WAV: invalid channel count (0)");
            if (fmt.sample_rate == 0)
                throw std::runtime_error("WAV: invalid sample rate (0)");
            if (fmt.bits_per_sample == 0)
                throw std::runtime_error("WAV: invalid bits_per_sample (0)");

            // Skip extension bytes and RIFF alignment pad.
            // Per the RIFF spec, a chunk with an odd payload size is followed
            // by one silent padding byte so the next chunk starts on an even
            // boundary.  Unknown chunks handle this with `chunk_size & 1` above;
            // we must do the same here for fmt.
            uint32_t to_skip = (chunk_size - 16) + (chunk_size & 1u);
            if (to_skip > 0)
                f.seekg(static_cast<std::streamoff>(to_skip), std::ios::cur);

            got_fmt = true;

        } else if (std::memcmp(id, "data", 4) == 0) {
            // ── data chunk ──────────────────────────────────────────────────
            if (!got_fmt)
                throw std::runtime_error(
                    "WAV: data chunk appears before fmt chunk");

            fmt.data_chunk_size = chunk_size;
            got_data = true;  // stop scanning; file pos is now at first sample

        } else {
            // ── unknown chunk (LIST, INFO, fact, JUNK, …) ───────────────────
            // WAV spec: chunk payloads are padded to an even byte boundary.
            // Use uint64_t to prevent overflow when chunk_size == 0xFFFFFFFF.
            uint64_t skip = static_cast<uint64_t>(chunk_size) + (chunk_size & 1u);
            f.seekg(static_cast<std::streamoff>(skip), std::ios::cur);
        }
    }

    return fmt;
}

}  // anonymous namespace

// ===========================================================================
// read_wav
// ===========================================================================

AudioData read_wav(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open())
        throw std::runtime_error("cannot open WAV file: " + path);

    WavFmt fmt = scan_wav_header(f);

    // Only 16-bit PCM is supported for decoding into int16_t samples.
    // 8-bit would over-read (2× too many bytes) and 24/32-bit would be
    // misinterpreted — reject early rather than silently corrupt.
    if (fmt.bits_per_sample != 16)
        throw std::runtime_error(
            "unsupported WAV bit depth: only 16-bit PCM is supported");

    std::size_t num_samples = fmt.data_chunk_size / sizeof(int16_t);

    std::vector<int16_t> samples(num_samples);
    must_read(f, samples.data(),
              num_samples * sizeof(int16_t),
              "sample data");

    AudioData out;
    out.samples         = std::move(samples);
    out.sample_rate     = static_cast<int>(fmt.sample_rate);
    out.channels        = static_cast<int>(fmt.channels);
    out.bits_per_sample = static_cast<int>(fmt.bits_per_sample);
    return out;
}

// ===========================================================================
// read_pcm — raw headerless 16-bit little-endian PCM (16 kHz, mono)
// ===========================================================================

AudioData read_pcm(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open())
        throw std::runtime_error("cannot open PCM file: " + path);

    f.seekg(0, std::ios::end);
    std::streampos size_pos = f.tellg();
    if (size_pos < 0)
        throw std::runtime_error("cannot determine size of PCM file: " + path);
    auto file_size = static_cast<std::size_t>(size_pos);
    f.seekg(0, std::ios::beg);

    std::size_t num_samples = file_size / sizeof(int16_t);
    std::vector<int16_t> samples(num_samples);

    if (num_samples > 0) {
        f.read(reinterpret_cast<char*>(samples.data()),
               static_cast<std::streamsize>(num_samples * sizeof(int16_t)));
        if (f.fail())
            throw std::runtime_error("PCM read error: unexpected I/O failure: " + path);
    }

    AudioData out;
    out.samples         = std::move(samples);
    out.sample_rate     = 16000;
    out.channels        = 1;
    out.bits_per_sample = 16;
    return out;
}

// ===========================================================================
// peek_wav_duration_secs
// ===========================================================================

double peek_wav_duration_secs(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f.is_open())
        throw std::runtime_error("cannot open WAV file: " + path);

    WavFmt fmt = scan_wav_header(f);   // positions past data header; no alloc

    double bytes_per_sec = static_cast<double>(fmt.sample_rate)
                         * fmt.channels
                         * (fmt.bits_per_sample / 8.0);
    return static_cast<double>(fmt.data_chunk_size) / bytes_per_sec;
}
