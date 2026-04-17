#include "audio/vad_scanner.h"

static constexpr int kFrameMs = 30;

VadScanner::VadScanner(Callback cb, int vad_mode)
    : cb_(std::move(cb)), vad_(vad_mode, SAMPLE_RATE) {}

void VadScanner::push_frame(const int16_t* samples, int num_samples) {
    bool speech = vad_.is_speech(samples, num_samples);
    int frame_ms = num_samples * 1000 / SAMPLE_RATE;

    buffer_.insert(buffer_.end(), samples, samples + num_samples);
    buffer_ms_ += frame_ms;

    if (speech) {
        in_speech_ = true;
        silence_ms_ = 0;
    } else if (in_speech_) {
        silence_ms_ += frame_ms;
    }

    if (in_speech_ && buffer_ms_ >= MAX_CHUNK_MS) {
        maybe_emit_chunk(false);
    } else if (in_speech_ && silence_ms_ >= SILENCE_BOUNDARY_MS) {
        if (buffer_ms_ - silence_ms_ >= MIN_CHUNK_MS) {
            maybe_emit_chunk(false);
        }
    }
}

void VadScanner::flush() {
    if (!buffer_.empty() && in_speech_) {
        maybe_emit_chunk(true);
    }
    in_speech_ = false;
    silence_ms_ = 0;
}

void VadScanner::reset() {
    buffer_.clear();
    buffer_ms_ = 0;
    silence_ms_ = 0;
    in_speech_ = false;
    chunk_id_ = 0;
}

void VadScanner::maybe_emit_chunk(bool is_final) {
    Chunk c;
    c.id = chunk_id_++;
    c.pcm = std::move(buffer_);
    c.is_final = is_final;
    c.duration_ms = buffer_ms_;

    buffer_.clear();
    buffer_ms_ = 0;
    silence_ms_ = 0;

    cb_(std::move(c));
}
