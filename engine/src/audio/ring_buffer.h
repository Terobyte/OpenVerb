#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

class RingBuffer {
public:
    RingBuffer();

    size_t write(const void* data, size_t len);
    std::vector<int16_t> read_all();
    void   reset();
    size_t bytes_available() const;
    double duration_secs() const;
    bool   has_overflow() const { return overflow_.load(std::memory_order_acquire); }
    void   clear_overflow()     { overflow_.store(false, std::memory_order_release); }

private:
    static constexpr size_t BUF_SIZE = 16777216; // 16 MB, power of two
    static constexpr size_t MASK     = BUF_SIZE - 1;

    std::vector<uint8_t>       buf_;
    std::atomic<size_t>        write_idx_{0};
    std::atomic<size_t>        read_idx_{0};
    std::atomic<bool>          overflow_{false};
    // Serialises concurrent writes.  CoreAudio may invoke the capture callback
    // from multiple internal threads, violating the SPSC contract.
    mutable std::mutex         write_mutex_;
};
