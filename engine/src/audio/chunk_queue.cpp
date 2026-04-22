#include "audio/chunk_queue.h"

void ChunkQueue::push(const Chunk& chunk) {
    std::unique_lock<std::mutex> lock(mu_);
    // Bug H4 fix: capture the current generation before waiting so that, after
    // waking, we can detect whether reset() fired and the queue belongs to a new
    // session.  If the generation changed, discard this stale chunk.
    const uint64_t entry_generation = generation_;
    not_full_.wait(lock, [this]() {
        return static_cast<int>(queue_.size()) < CHUNK_QUEUE_MAX_DEPTH || shut_;
    });
    if (shut_) return;
    // Bug H4 fix: discard chunk if reset() advanced the generation counter
    // while this push() was blocked — the old chunk belongs to the previous
    // session and must not be inserted into the freshly-cleared queue.
    if (generation_ != entry_generation) return;
    audio_ms_ += chunk.duration_ms;
    queue_.push(chunk);
    not_empty_.notify_one();
}

std::optional<Chunk> ChunkQueue::pop() {
    std::unique_lock<std::mutex> lock(mu_);
    not_empty_.wait(lock, [this]() {
        return !queue_.empty() || shut_;
    });
    if (queue_.empty()) return std::nullopt;
    Chunk c = std::move(queue_.front());
    queue_.pop();
    audio_ms_ = std::max(0, audio_ms_ - c.duration_ms);
    not_full_.notify_one();
    return c;
}

void ChunkQueue::shutdown() {
    std::lock_guard<std::mutex> lock(mu_);
    shut_ = true;
    not_empty_.notify_all();
    not_full_.notify_all();
}

void ChunkQueue::reset() {
    std::lock_guard<std::mutex> lock(mu_);
    std::queue<Chunk>().swap(queue_);
    audio_ms_ = 0;
    shut_ = false;
    ++generation_;
    not_empty_.notify_all();
    not_full_.notify_all();
}

int ChunkQueue::depth() const {
    std::lock_guard<std::mutex> lock(mu_);
    return static_cast<int>(queue_.size());
}

int ChunkQueue::queued_audio_ms() const {
    std::lock_guard<std::mutex> lock(mu_);
    return audio_ms_;
}
