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

    // WebRTC VAD only accepts 10 / 20 / 30 ms frames at the configured rate
    // (at 16 kHz: 160, 320, or 480 samples). Any other length makes
    // WebRtcVad_Process return -1, which is_speech() reads as "not speech" —
    // so callers that feed us 128 ms AVAudioEngine buffers (2048 samples) or
    // 500 ms bench frames would silently bypass VAD and the session would
    // return an empty transcript. We normalise internally by iterating in
    // kVadFrameSamples (30 ms) slices and buffering the remainder in
    // pending_ across calls.
    constexpr int kVadFrameMs      = 30;
    constexpr int kVadFrameSamples = SAMPLE_RATE * kVadFrameMs / 1000;

    pending_.insert(pending_.end(), samples, samples + num_samples);

    size_t offset = 0;
    while (pending_.size() - offset >= static_cast<size_t>(kVadFrameSamples)) {
        const int16_t* frame_ptr = pending_.data() + offset;
        bool speech = vad_.is_speech(frame_ptr, kVadFrameSamples);

        buffer_.insert(buffer_.end(), frame_ptr, frame_ptr + kVadFrameSamples);
        buffer_ms_ += kVadFrameMs;

        if (speech) {
            in_speech_ = true;
            silence_ms_ = 0;
        } else if (in_speech_) {
            silence_ms_ += kVadFrameMs;
        }

        offset += static_cast<size_t>(kVadFrameSamples);

        if (in_speech_ && buffer_ms_ >= MAX_CHUNK_MS) {
            maybe_emit_chunk(false, lk);
            // maybe_emit_chunk unlocks lk before invoking the callback. Re-lock
            // to continue consuming pending_ safely.
            if (!lk.owns_lock()) lk.lock();
        } else if (in_speech_ && silence_ms_ >= SILENCE_BOUNDARY_MS) {
            if (buffer_ms_ - silence_ms_ >= MIN_CHUNK_MS) {
                maybe_emit_chunk(false, lk);
                if (!lk.owns_lock()) lk.lock();
                in_speech_ = false;  // utterance ended at silence boundary; don't accumulate trailing silence
            }
        }
    }

    // Retain the leftover tail (< 30 ms) for the next push_frame.
    if (offset > 0) {
        pending_.erase(pending_.begin(), pending_.begin() + offset);
    }
}

void VadScanner::flush() {
    std::unique_lock<std::mutex> lk(mu_);
    // Flush represents end-of-audio: emit any buffered speech even if it is
    // shorter than MIN_CHUNK_MS. The MIN_CHUNK_MS guard only applies to
    // mid-stream silence-boundary emits (see push_frame), where it prevents
    // spurious tiny chunks during a pause. At stream end we must transcribe
    // whatever we have, otherwise short utterances ("hi", "save file") return
    // an empty result — which was the regression tracked by the
    // VadScannerTest.FinalFlushEmitsIsFinalChunkEvenIfBelowMinChunkMs test.
    if (!buffer_.empty() && in_speech_) {
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
    pending_.clear();
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
