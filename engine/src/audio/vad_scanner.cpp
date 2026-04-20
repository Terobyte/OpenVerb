#include "audio/vad_scanner.h"

static constexpr int kFrameMs = 30;

VadScanner::VadScanner(Callback cb, int vad_mode)
    : cb_(std::move(cb)), vad_(vad_mode, SAMPLE_RATE) {}

void VadScanner::push_frame(const int16_t* samples, int num_samples) {
    // Bug H3 fix: use unique_lock so we can unlock mu_ before invoking cb_()
    // via maybe_emit_chunk().  cb_() typically calls chunk_queue_.push() which
    // may block on not_full_.wait(); holding mu_ while blocking can deadlock
    // if the consumer thread also needs mu_ (e.g. for reset()).
    std::unique_lock<std::mutex> lk(mu_);
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
        maybe_emit_chunk(false, lk);
    } else if (in_speech_ && silence_ms_ >= SILENCE_BOUNDARY_MS) {
        if (buffer_ms_ - silence_ms_ >= MIN_CHUNK_MS) {
            maybe_emit_chunk(false, lk);
            in_speech_ = false;  // utterance ended at silence boundary; don't accumulate trailing silence
        }
    }
}

void VadScanner::flush() {
    std::unique_lock<std::mutex> lk(mu_);
    if (!buffer_.empty() && in_speech_ && (buffer_ms_ - silence_ms_ >= MIN_CHUNK_MS)) {
        maybe_emit_chunk(true, lk);
    }
    // Only touch state if we still hold the lock (maybe_emit_chunk may have released it)
    if (lk.owns_lock()) {
        in_speech_ = false;
        silence_ms_ = 0;
    }
}

void VadScanner::reset() {
    std::lock_guard<std::mutex> lk(mu_);
    buffer_.clear();
    buffer_ms_ = 0;
    silence_ms_ = 0;
    in_speech_ = false;
    chunk_id_ = 0;
}

void VadScanner::maybe_emit_chunk(bool is_final,
                                   std::unique_lock<std::mutex>& lk) {
    Chunk c;
    c.id = chunk_id_++;
    c.pcm = std::move(buffer_);
    c.is_final = is_final;
    c.duration_ms = buffer_ms_;

    buffer_.clear();
    buffer_ms_ = 0;
    silence_ms_ = 0;

    // Bug H3 fix: release mu_ before calling cb_() so that a blocking push()
    // inside cb_() cannot deadlock against a consumer that tries to acquire mu_.
    lk.unlock();
    cb_(std::move(c));
}
