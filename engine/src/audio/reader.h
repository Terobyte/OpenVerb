#pragma once

#include <cstdint>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// AudioData — decoded, interleaved PCM samples from any supported audio source.
//
// Fields:
//   samples          — interleaved signed 16-bit PCM samples, frame-interleaved
//                      ordering (L0 R0 L1 R1 … for stereo).
//   sample_rate      — samples per second per channel (e.g. 16000, 44100).
//   channels         — number of audio channels (1 = mono, 2 = stereo).
//   bits_per_sample  — original bit depth as reported by the file header
//                      (typically 16; stored for caller bookkeeping only —
//                       samples are always normalised to int16_t on read).
// ---------------------------------------------------------------------------

struct AudioData {
    std::vector<int16_t> samples;
    int sample_rate      = 0;
    int channels         = 0;
    int bits_per_sample  = 0;
};

// ---------------------------------------------------------------------------
// read_wav — decode a WAV (RIFF PCM) file into AudioData.
//
//   Reads the full sample payload.  Throws std::runtime_error on any I/O
//   error, malformed header, or unsupported encoding (non-PCM, 24/32-bit).
// ---------------------------------------------------------------------------
AudioData read_wav(const std::string& path);

// ---------------------------------------------------------------------------
// read_pcm — load a raw headerless PCM file into AudioData.
//
//   Interprets the entire file as interleaved signed 16-bit little-endian
//   samples.  Because raw PCM carries no metadata, the returned AudioData
//   is populated with the assumed contract values:
//       sample_rate     = 16000  (16 kHz)
//       channels        = 1      (mono)
//       bits_per_sample = 16
//   Throws std::runtime_error on I/O errors.
// ---------------------------------------------------------------------------
AudioData read_pcm(const std::string& path);

// ---------------------------------------------------------------------------
// peek_wav_duration_secs — compute audio duration from the WAV header only.
//
//   Reads at most 80 bytes (the RIFF + fmt chunk, covering both standard
//   44-byte and extended 80-byte PCM headers) without loading sample data.
//   Returns duration in seconds as:
//       data_chunk_bytes / (sample_rate * channels * bits_per_sample / 8)
//
//   Useful for fast pre-flight checks (e.g. reject files > MAX_DURATION)
//   without the cost of a full decode.
//
//   Throws std::runtime_error if the file is unreadable or not a PCM WAV.
// ---------------------------------------------------------------------------
double peek_wav_duration_secs(const std::string& path);
