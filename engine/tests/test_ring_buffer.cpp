#include <gtest/gtest.h>

#include "audio/ring_buffer.h"

#include <cstring>
#include <thread>
#include <vector>

TEST(RingBufferTest, WriteReadRoundtrip) {
    RingBuffer rb;
    uint8_t data[] = {0x01, 0x02, 0x03, 0x04};
    size_t written = rb.write(data, sizeof(data));
    EXPECT_EQ(written, sizeof(data));

    auto result = rb.read_all();
    ASSERT_EQ(result.size(), 2u); // 4 bytes / 2 bytes per int16_t
}

TEST(RingBufferTest, WriteUntilFull) {
    RingBuffer rb;
    std::vector<uint8_t> big(16777216, 0xAA);
    size_t written = rb.write(big.data(), big.size());
    EXPECT_EQ(written, big.size());

    uint8_t extra = 0xBB;
    size_t w2 = rb.write(&extra, 1);
    EXPECT_EQ(w2, 0u);
}

TEST(RingBufferTest, ResetClears) {
    RingBuffer rb;
    uint8_t data[] = {0x01, 0x02, 0x03};
    rb.write(data, sizeof(data));
    EXPECT_GT(rb.bytes_available(), 0u);

    rb.reset();
    EXPECT_EQ(rb.bytes_available(), 0u);
}

TEST(RingBufferTest, DurationSecs) {
    RingBuffer rb;
    // 32000 bytes = 16000 samples * 2 bytes = 1.0 second
    std::vector<uint8_t> data(32000, 0);
    rb.write(data.data(), data.size());
    EXPECT_DOUBLE_EQ(rb.duration_secs(), 1.0);
}

TEST(RingBufferTest, ConcurrentWriteRead) {
    RingBuffer rb;
    std::atomic<bool> done{false};

    std::thread writer([&]() {
        for (int i = 0; i < 1000; ++i) {
            uint8_t byte = static_cast<uint8_t>(i & 0xFF);
            rb.write(&byte, 1);
        }
        done.store(true);
    });

    std::thread reader([&]() {
        while (!done.load()) {
            rb.bytes_available();
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    });

    writer.join();
    reader.join();
    EXPECT_GT(rb.bytes_available(), 0u);
}

TEST(RingBufferTest, ResetWhileProducerIdle) {
    RingBuffer rb;
    uint8_t data[] = {0x01, 0x02, 0x03};
    rb.write(data, sizeof(data));

    rb.reset();

    uint8_t data2[] = {0x04, 0x05};
    rb.write(data2, sizeof(data2));
    EXPECT_EQ(rb.bytes_available(), 2u);
}

// ===========================================================================
// Negative / edge-case tests
// ===========================================================================

// Constructing a RingBuffer must leave it empty.
TEST(RingBufferNegative, BytesAvailableIsZeroOnConstruct) {
    RingBuffer rb;
    EXPECT_EQ(rb.bytes_available(), 0u);
    EXPECT_DOUBLE_EQ(rb.duration_secs(), 0.0);
}

// read_all() on an empty buffer must return an empty vector, never crash.
TEST(RingBufferNegative, ReadAllFromEmpty) {
    RingBuffer rb;
    auto result = rb.read_all();
    EXPECT_TRUE(result.empty())
        << "read_all() on empty buffer returned " << result.size() << " samples";
    EXPECT_EQ(rb.bytes_available(), 0u);
}

// write(data, 0) must be a safe no-op: returns 0, leaves buffer empty.
TEST(RingBufferNegative, WriteZeroBytes) {
    RingBuffer rb;
    uint8_t dummy = 0xAB;
    size_t written = rb.write(&dummy, 0);
    EXPECT_EQ(written, 0u);
    EXPECT_EQ(rb.bytes_available(), 0u);
    auto result = rb.read_all();
    EXPECT_TRUE(result.empty());
}

// After reset() + write(), bytes_available must reflect only the new write,
// not residual state from before reset.  Verifies seq_cst reset is clean.
TEST(RingBufferNegative, ResetClearsIndexesForFreshWrite) {
    RingBuffer rb;

    // Partially fill, then read all (advances read_idx).
    uint8_t first[] = {0x11, 0x22, 0x33, 0x44};
    rb.write(first, sizeof(first));
    rb.read_all();

    // Reset: both indexes back to zero.
    rb.reset();
    EXPECT_EQ(rb.bytes_available(), 0u);

    // Write new data — must see exactly 2 bytes.
    uint8_t second[] = {0xAA, 0xBB};
    rb.write(second, sizeof(second));
    EXPECT_EQ(rb.bytes_available(), 2u);

    // Read back: must contain the NEW data, not stale bytes.
    auto result = rb.read_all();
    ASSERT_EQ(result.size(), 1u);
    EXPECT_EQ(result[0], static_cast<int16_t>(0xBBAA));
}

// write() must reject data when the buffer is exactly full.
// Accepting even 1 extra byte would corrupt the circular structure.
TEST(RingBufferNegative, WriteOneBytePastFullIsRejected) {
    RingBuffer rb;
    std::vector<uint8_t> full(16777216, 0xFF);
    size_t w1 = rb.write(full.data(), full.size());
    EXPECT_EQ(w1, full.size()) << "initial fill should succeed";

    uint8_t one_more = 0x01;
    size_t w2 = rb.write(&one_more, 1);
    EXPECT_EQ(w2, 0u)
        << "write to a full buffer must return 0, not " << w2;
}

// Consecutive read_all() calls without new writes must each return empty.
// Verifies read_idx is advanced correctly (regression for the bug where
// read_all() did not advance read_idx at all).
TEST(RingBufferNegative, SecondReadAllOnExhaustedBufferReturnsEmpty) {
    RingBuffer rb;
    uint8_t data[] = {0x01, 0x02};
    rb.write(data, sizeof(data));

    auto first = rb.read_all();
    ASSERT_EQ(first.size(), 1u) << "first read_all should return 1 sample";

    auto second = rb.read_all();
    EXPECT_TRUE(second.empty())
        << "second read_all on exhausted buffer returned " << second.size()
        << " samples — read_idx was not advanced by the first call";
}

// Bug 14: read_all with odd bytes must leave the odd byte in the buffer
TEST(RingBufferBug14, ReadAllMasksOddAvailBytes) {
    RingBuffer rb;
    uint8_t data[] = {0x01, 0x02, 0x03};  // 3 bytes = odd
    rb.write(data, 3);
    EXPECT_EQ(rb.bytes_available(), 3u);
    auto result = rb.read_all();
    EXPECT_EQ(result.size(), 1u);          // 2 bytes = 1 sample
    EXPECT_EQ(rb.bytes_available(), 1u);   // odd byte remains
}

// Bug 21: write() returns partial count when buffer is near-full
TEST(RingBufferBug21, WriteReturnsPartialOnFull) {
    RingBuffer rb;
    std::vector<uint8_t> fill(16777216 - 10, 0);
    size_t w1 = rb.write(fill.data(), fill.size());
    EXPECT_EQ(w1, fill.size());
    std::vector<uint8_t> overflow(20, 0xAA);
    size_t w2 = rb.write(overflow.data(), overflow.size());
    EXPECT_EQ(w2, 10u);
    EXPECT_LT(w2, overflow.size());
}
