#include <gtest/gtest.h>

#include "audio/ring_buffer.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

// ===========================================================================
// Bug #7 — read_all() heap buffer overflow when avail is odd
//
// write() accepts any byte count. If an odd number of bytes is written,
// read_all() allocates vector<int16_t>(avail/2) but copies avail bytes
// via reinterpret_cast — writing 1 byte past the end of the vector.
// ===========================================================================
TEST(BugRegression, ReadAllOddByteCountOverflows) {
    RingBuffer rb;

    // Write 3 bytes (odd count). read_all must consume only 2 (1 int16_t sample)
    // and leave 1 trailing byte in the buffer — no heap overflow.
    uint8_t odd_data[] = {0x01, 0x02, 0x03};
    rb.write(odd_data, sizeof(odd_data));

    ASSERT_EQ(rb.bytes_available(), 3u);

    auto result = rb.read_all();

    // Fixed: returns exactly 1 sample (2 bytes consumed)
    EXPECT_EQ(result.size(), 1u)
        << "Expected 1 sample from 3 bytes (drops odd trailing byte)";

    // Fixed: 1 odd trailing byte remains
    EXPECT_EQ(rb.bytes_available(), 1u)
        << "Expected 1 trailing byte left after read_all";
}

// ===========================================================================
// Bug #1 — read_all() never advances read_idx
//
// After read_all(), bytes_available() still reports the original count
// because read_idx was never moved forward.
// ===========================================================================
TEST(BugRegression, ReadAllDoesNotAdvanceReadIdx) {
    RingBuffer rb;

    uint8_t data[] = {0xAA, 0xBB};
    rb.write(data, sizeof(data));

    ASSERT_EQ(rb.bytes_available(), 2u);

    auto first = rb.read_all();
    ASSERT_EQ(first.size(), 1u);

    // After read_all consumed the data, bytes_available should be 0.
    size_t avail_after = rb.bytes_available();
    EXPECT_EQ(avail_after, 0u)
        << "BUG: bytes_available()=" << avail_after
        << " after read_all(). read_idx was never advanced.";

    // Second read_all returns the same stale data.
    auto second = rb.read_all();
    EXPECT_EQ(second.size(), 0u)
        << "BUG: second read_all() returned " << second.size()
        << " samples — stale data from un-advanced read_idx.";
}

// ===========================================================================
// Bug #1 extended — write after read_all sees wrong free space
//
// read_all() doesn't advance read_idx, so write() thinks the buffer
// is fuller than it is. A large write after read_all may be rejected.
// ===========================================================================
TEST(BugRegression, WriteAfterReadAllSeesWrongFreeSpace) {
    RingBuffer rb;

    // Fill 1/4 of the buffer, read it all, then write again.
    // Fixed read_all() advances read_idx, so the second write should succeed.
    size_t quarter = 16777216 / 4;
    std::vector<uint8_t> big(quarter, 0xAA);
    rb.write(big.data(), big.size());

    auto result = rb.read_all();
    ASSERT_GT(result.size(), 0u);

    // Fixed: read_idx advanced → buffer is empty
    size_t avail = rb.bytes_available();
    EXPECT_EQ(avail, 0u)
        << "bytes_available()=" << avail << " after read_all(), expected 0";

    // Fixed: second write into the now-empty buffer must fully succeed
    std::vector<uint8_t> second(quarter, 0xBB);
    size_t written = rb.write(second.data(), second.size());
    EXPECT_EQ(written, quarter)
        << "write after read_all accepted only " << written
        << " bytes (expected " << quarter << ") — phantom used space";
}

// ===========================================================================
// Bug #2 — reset() with relaxed ordering can break concurrent write
//
// Demonstrates that reset() stores indices with relaxed ordering while
// write() loads them with acquire ordering. Under high contention,
// the writer can see a stale write_idx combined with a fresh read_idx
// (or vice versa), producing an incorrect free-space calculation.
//
// This test uses a fast spin to maximize contention; under ThreadSanitizer
// it will flag the data race.
// ===========================================================================
TEST(BugRegression, ResetAndWriteConcurrentRace) {
    RingBuffer rb;
    std::atomic<bool> go{false};
    std::atomic<int> corruption_count{0};

    auto writer = std::thread([&]() {
        while (!go.load()) {}
        for (int i = 0; i < 10000; ++i) {
            uint8_t d = static_cast<uint8_t>(i);
            rb.write(&d, 1);
        }
    });

    auto resetter = std::thread([&]() {
        while (!go.load()) {}
        for (int i = 0; i < 50; ++i) {
            rb.reset();
            std::this_thread::sleep_for(std::chrono::microseconds(50));
        }
    });

    go.store(true);

    writer.join();
    resetter.join();

    // Post-condition: bytes_available must not exceed buffer size.
    // With the relaxed-ordering bug, write_idx can be reset while
    // read_idx is stale, making (write_idx - read_idx) > BUF_SIZE.
    size_t avail = rb.bytes_available();
    EXPECT_LE(avail, 16777216u)
        << "BUG: bytes_available()=" << avail
        << " exceeds BUF_SIZE — corrupt index state from relaxed reset()";

    // Also verify: write after reset should still work
    rb.reset();
    uint8_t byte = 0x42;
    size_t w = rb.write(&byte, 1);
    EXPECT_EQ(w, 1u);

    size_t final_avail = rb.bytes_available();
    EXPECT_EQ(final_avail, 1u)
        << "BUG: after clean reset + 1 byte write, bytes_available()="
        << final_avail << " (expected 1). Stale index from prior race.";
}

// ===========================================================================
// Bug #7 concrete proof — read_all with 5 bytes writes past vector end
//
// Writes exactly 5 bytes, then verifies that the vector allocated by
// read_all() is too small for the copy loop.
// ===========================================================================
TEST(BugRegression, FiveByteWriteCausesReadAllOverflow) {
    RingBuffer rb;

    // Write 5 bytes. Fixed read_all must return 2 samples (4 bytes) without
    // overflowing, leaving 1 trailing byte unread.
    uint8_t five[] = {0x10, 0x20, 0x30, 0x40, 0x50};
    rb.write(five, sizeof(five));

    ASSERT_EQ(rb.bytes_available(), 5u);

    auto result = rb.read_all();

    // Fixed: returns 2 complete int16_t samples
    EXPECT_EQ(result.size(), 2u)
        << "Expected 2 samples from 5 bytes (drops odd trailing byte)";

    // Fixed: sample values match written bytes (little-endian pairs)
    EXPECT_EQ(result[0], static_cast<int16_t>(0x2010));
    EXPECT_EQ(result[1], static_cast<int16_t>(0x4030));

    // Fixed: 1 trailing byte remains
    EXPECT_EQ(rb.bytes_available(), 1u)
        << "Expected 1 trailing byte left after read_all";
}
