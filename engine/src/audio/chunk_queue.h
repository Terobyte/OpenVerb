#pragma once

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <queue>
#include <vector>

#include "config/defaults.h"

struct Chunk {
    int id;
    std::vector<int16_t> pcm;
    bool is_final;
    int duration_ms;
};

class ChunkQueue {
public:
    void push(const Chunk& chunk);
    std::optional<Chunk> pop();
    void shutdown();
    void reset();

    int depth() const;
    int queued_audio_ms() const;

private:
    mutable std::mutex mu_;
    std::condition_variable not_empty_;
    std::condition_variable not_full_;
    std::queue<Chunk> queue_;
    int audio_ms_ = 0;
    bool shut_ = false;
};
