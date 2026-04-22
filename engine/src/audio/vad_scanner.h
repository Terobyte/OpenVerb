#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <vector>

#include "audio/chunk_queue.h"
#include "audio/vad.h"
#include "config/defaults.h"

class VadScanner {
public:
    using Callback = std::function<void(Chunk)>;

    explicit VadScanner(Callback cb, int vad_mode = 3);
    void push_frame(const int16_t* samples, int num_samples);
    void flush();
    void reset();

private:
    // Bug H3 fix: takes unique_lock by reference so it can unlock mu_ before
    // invoking cb_() — preventing a deadlock when cb_() (chunk_queue_.push())
    // blocks on a full queue while another thread holds mu_.
    void maybe_emit_chunk(bool is_final, std::unique_lock<std::mutex>& lk);

    mutable std::mutex mu_;
    Callback cb_;
    Vad vad_;
    std::vector<int16_t> buffer_;
    // Pending holds input samples that have not yet formed a full 30 ms VAD
    // sub-frame. push_frame accumulates into pending_ and drains as many
    // 30 ms slices as fit; the remainder carries to the next call.
    std::vector<int16_t> pending_;
    int chunk_id_ = 0;
    int buffer_ms_ = 0;
    int silence_ms_ = 0;
    bool in_speech_ = false;
};
