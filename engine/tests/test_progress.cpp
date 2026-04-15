#include <gtest/gtest.h>

#include "ipc/progress.h"

#include <thread>
#include <vector>

TEST(ProgressQueueTest, PushAndDrain) {
    ProgressQueue q;
    q.push(0.5f);
    q.push(0.75f);
    auto items = q.drain();
    ASSERT_EQ(items.size(), 2u);
    EXPECT_FLOAT_EQ(items[0], 0.5f);
    EXPECT_FLOAT_EQ(items[1], 0.75f);
}

TEST(ProgressQueueTest, DrainEmpty) {
    ProgressQueue q;
    auto items = q.drain();
    EXPECT_TRUE(items.empty());
}

TEST(ProgressQueueTest, PushNItems) {
    ProgressQueue q;
    for (int i = 0; i < 100; ++i) {
        q.push(static_cast<float>(i));
    }
    auto items = q.drain();
    ASSERT_EQ(items.size(), 100u);
    for (int i = 0; i < 100; ++i) {
        EXPECT_FLOAT_EQ(items[i], static_cast<float>(i));
    }
}

TEST(ProgressQueueTest, ThreadedPushAndDrain) {
    ProgressQueue q;
    std::thread t1([&]() {
        for (int i = 0; i < 50; ++i) q.push(static_cast<float>(i));
    });
    std::thread t2([&]() {
        for (int i = 50; i < 100; ++i) q.push(static_cast<float>(i));
    });
    t1.join();
    t2.join();
    auto items = q.drain();
    EXPECT_EQ(items.size(), 100u);
}
