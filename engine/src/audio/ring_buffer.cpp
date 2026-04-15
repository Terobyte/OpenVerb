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
    size_t w_pos = w & MASK;
    size_t first = BUF_SIZE - w_pos;
    if (first >= n) {
        std::memcpy(buf_.data() + w_pos, src, n);
    } else {
        std::memcpy(buf_.data() + w_pos, src, first);
        std::memcpy(buf_.data(), src + first, n - first);
    }
    write_idx_.store(w + n, std::memory_order_release);
    return n;
}

std::vector<int16_t> RingBuffer::read_all() {
    size_t r       = read_idx_.load(std::memory_order_relaxed);
    size_t w       = write_idx_.load(std::memory_order_acquire);
    size_t avail   = (w >= r) ? w - r : 0;  // guard against reset() race underflow
    avail &= ~size_t(1);          // mask to even byte count
    size_t samples = avail / 2;
    std::vector<int16_t> result(samples);
    size_t n = samples * 2;
    size_t r_pos = r & MASK;
    size_t first = BUF_SIZE - r_pos;
    if (first >= n) {
        std::memcpy(result.data(), buf_.data() + r_pos, n);
    } else {
        std::memcpy(result.data(), buf_.data() + r_pos, first);
        std::memcpy(reinterpret_cast<uint8_t*>(result.data()) + first, buf_.data(), n - first);
    }
    read_idx_.store(r + n, std::memory_order_release);
    return result;
}

void RingBuffer::reset() {
    write_idx_.store(0, std::memory_order_seq_cst);
    read_idx_.store(0, std::memory_order_seq_cst);
}

size_t RingBuffer::bytes_available() const {
    size_t w = write_idx_.load(std::memory_order_acquire);
    size_t r = read_idx_.load(std::memory_order_acquire);
    return (w >= r) ? w - r : 0;  // guard against reset() race underflow
}

double RingBuffer::duration_secs() const {
    size_t bytes = bytes_available();
    return static_cast<double>(bytes) / (SAMPLE_RATE * sizeof(int16_t));
}
