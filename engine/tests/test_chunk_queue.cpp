#include <gtest/gtest.h>

#include "audio/chunk_queue.h"

#include <chrono>
#include <thread>
#include <vector>

static Chunk make_chunk(int id, int duration_ms, bool is_final = false) {
    Chunk c;
    c.id = id;
    c.pcm = std::vector<int16_t>(static_cast<size_t>(duration_ms * 16), static_cast<int16_t>(id));
    c.is_final = is_final;
    c.duration_ms = duration_ms;
    return c;
}

TEST(ChunkQueueTest, FIFOOrdering) {
    ChunkQueue q;
    q.push(make_chunk(1, 100));
    q.push(make_chunk(2, 200));
    q.push(make_chunk(3, 300));

    auto c1 = q.pop();
    auto c2 = q.pop();
    auto c3 = q.pop();

    ASSERT_TRUE(c1.has_value());
    ASSERT_TRUE(c2.has_value());
    ASSERT_TRUE(c3.has_value());
    EXPECT_EQ(c1->id, 1);
    EXPECT_EQ(c2->id, 2);
    EXPECT_EQ(c3->id, 3);
}

TEST(ChunkQueueTest, BlockingPop) {
    ChunkQueue q;
    Chunk result;

    std::thread producer([&]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        q.push(make_chunk(42, 100));
    });

    auto c = q.pop();
    ASSERT_TRUE(c.has_value());
    EXPECT_EQ(c->id, 42);
    producer.join();
}

TEST(ChunkQueueTest, ShutdownUnblocksPopper) {
    ChunkQueue q;

    std::thread stopper([&]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        q.shutdown();
    });

    auto c = q.pop();
    EXPECT_FALSE(c.has_value());
    stopper.join();
}

TEST(ChunkQueueTest, DepthCounter) {
    ChunkQueue q;
    EXPECT_EQ(q.depth(), 0);

    q.push(make_chunk(1, 100));
    EXPECT_EQ(q.depth(), 1);

    q.push(make_chunk(2, 200));
    EXPECT_EQ(q.depth(), 2);

    q.pop();
    EXPECT_EQ(q.depth(), 1);

    q.pop();
    EXPECT_EQ(q.depth(), 0);
}

TEST(ChunkQueueTest, QueuedAudioMsTracking) {
    ChunkQueue q;
    EXPECT_EQ(q.queued_audio_ms(), 0);

    q.push(make_chunk(1, 300));
    EXPECT_EQ(q.queued_audio_ms(), 300);

    q.push(make_chunk(2, 500));
    EXPECT_EQ(q.queued_audio_ms(), 800);

    q.pop();
    EXPECT_EQ(q.queued_audio_ms(), 500);

    q.pop();
    EXPECT_EQ(q.queued_audio_ms(), 0);
}

TEST(ChunkQueueTest, BackpressurePushBlocksWhenFull) {
    ChunkQueue q;
    for (int i = 0; i < CHUNK_QUEUE_MAX_DEPTH; ++i) {
        q.push(make_chunk(i, 100));
    }
    EXPECT_EQ(q.depth(), CHUNK_QUEUE_MAX_DEPTH);

    bool pushed = false;
    std::thread pusher([&]() {
        q.push(make_chunk(99, 100));
        pushed = true;
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    EXPECT_FALSE(pushed);

    q.pop();
    pusher.join();
    EXPECT_TRUE(pushed);
    EXPECT_EQ(q.depth(), CHUNK_QUEUE_MAX_DEPTH);
}

TEST(ChunkQueueTest, ShutdownUnblocksBlockedPusher) {
    ChunkQueue q;
    for (int i = 0; i < CHUNK_QUEUE_MAX_DEPTH; ++i) {
        q.push(make_chunk(i, 100));
    }

    bool push_returned = false;
    std::thread pusher([&]() {
        q.push(make_chunk(99, 100));
        push_returned = true;
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    EXPECT_FALSE(push_returned);

    q.shutdown();
    pusher.join();
    EXPECT_TRUE(push_returned);
}

TEST(ChunkQueueTest, ResetClearsResidueAndRearms) {
    ChunkQueue q;
    q.push(make_chunk(1, 100));
    q.push(make_chunk(2, 200));
    q.shutdown();

    q.reset();
    EXPECT_EQ(q.depth(), 0);
    EXPECT_EQ(q.queued_audio_ms(), 0);

    q.push(make_chunk(3, 300));
    EXPECT_EQ(q.depth(), 1);
    EXPECT_EQ(q.queued_audio_ms(), 300);

    auto c = q.pop();
    ASSERT_TRUE(c.has_value());
    EXPECT_EQ(c->id, 3);
}
