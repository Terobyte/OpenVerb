#pragma once

#include <cstdint>
#include <functional>
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
    void maybe_emit_chunk(bool is_final);

    Callback cb_;
    Vad vad_;
    std::vector<int16_t> buffer_;
    int chunk_id_ = 0;
    int buffer_ms_ = 0;
    int silence_ms_ = 0;
    bool in_speech_ = false;
};
