#include "audio/ring_buffer.h"
#include "config/defaults.h"

RingBuffer::RingBuffer() : buf_(BUF_SIZE, 0) {}

size_t RingBuffer::write(const void* data, size_t len) {
    size_t w = write_idx_.load(std::memory_order_relaxed);
    size_t r = read_idx_.load(std::memory_order_acquire);
    size_t free = BUF_SIZE - (w - r);
    size_t n = (len < free) ? len : free;
    if (n == 0) return 0;

    const uint8_t* src = static_cast<const uint8_t*>(data);
    for (size_t i = 0; i < n; ++i) {
        buf_[(w + i) & MASK] = src[i];
    }
    write_idx_.store(w + n, std::memory_order_release);
    return n;
}

std::vector<int16_t> RingBuffer::read_all() {
    size_t r       = read_idx_.load(std::memory_order_relaxed);
    size_t w       = write_idx_.load(std::memory_order_acquire);
    size_t avail   = w - r;
    size_t samples = avail / 2;
    std::vector<int16_t> result(samples);
    for (size_t i = 0; i < samples * 2; ++i) {
        reinterpret_cast<uint8_t*>(result.data())[i] = buf_[(r + i) & MASK];
    }
    read_idx_.store(r + samples * 2, std::memory_order_release);
    return result;
}

void RingBuffer::reset() {
    write_idx_.store(0, std::memory_order_seq_cst);
    read_idx_.store(0, std::memory_order_seq_cst);
}

size_t RingBuffer::bytes_available() const {
    size_t w = write_idx_.load(std::memory_order_acquire);
    size_t r = read_idx_.load(std::memory_order_acquire);
    return w - r;
}

double RingBuffer::duration_secs() const {
    size_t bytes = bytes_available();
    return static_cast<double>(bytes) / (SAMPLE_RATE * sizeof(int16_t));
}
