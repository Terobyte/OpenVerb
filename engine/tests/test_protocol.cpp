#include <gtest/gtest.h>

#include "ipc/protocol.h"

#include <chrono>
#include <cstdint>
#include <cstring>
#include <future>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

static std::pair<int, int> make_socketpair() {
    int sv[2];
    int rc = ::socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    EXPECT_EQ(rc, 0);
    return {sv[0], sv[1]};
}

class SocketPairTest : public ::testing::Test {
protected:
    int a{-1}, b{-1};

    void SetUp() override {
        auto [sa, sb] = make_socketpair();
        a = sa;
        b = sb;
    }

    void TearDown() override {
        if (a >= 0) ::close(a);
        if (b >= 0) ::close(b);
    }
};

TEST_F(SocketPairTest, SendRecvJsonRoundtrip) {
    nlohmann::json msg;
    msg["type"] = "ping";

    RecvBuffer buf{};
    send_json(a, msg);
    auto result = recv_json(b, buf, 5000);

    EXPECT_EQ(result["type"], "ping");
}

TEST_F(SocketPairTest, BinaryFrameRoundtrip) {
    uint8_t header[4] = {0x00, 0x00, 0x00, 0x05};
    uint8_t payload[5] = {0x01, 0x02, 0x03, 0x04, 0x05};

    EXPECT_EQ(::write(a, header, 4), 4);
    EXPECT_EQ(::write(a, payload, 5), 5);

    RecvBuffer buf{};
    auto frame = recv_binary_frame(b, buf, 5000);

    ASSERT_EQ(frame.size(), 5u);
    EXPECT_EQ(frame[0], 0x01);
    EXPECT_EQ(frame[4], 0x05);
}

TEST_F(SocketPairTest, ZeroLengthSentinel) {
    uint8_t header[4] = {0x00, 0x00, 0x00, 0x00};
    EXPECT_EQ(::write(a, header, 4), 4);

    RecvBuffer buf{};
    auto frame = recv_binary_frame(b, buf, 5000);

    EXPECT_TRUE(frame.empty());
}

TEST_F(SocketPairTest, OversizedJsonThrows) {
    std::string big(70000, 'x');
    std::thread writer([this, &big]() {
        size_t written = 0;
        while (written < big.size()) {
            ssize_t n = ::write(a, big.data() + written, big.size() - written);
            if (n <= 0) break;
            written += static_cast<size_t>(n);
        }
    });

    RecvBuffer buf{};
    EXPECT_THROW(recv_json(b, buf, 2000), std::runtime_error);
    writer.join();
}

TEST_F(SocketPairTest, TimeoutThrows) {
    RecvBuffer buf{};
    EXPECT_THROW(recv_json(b, buf, 100), std::runtime_error);
}

TEST_F(SocketPairTest, MalformedJsonThrows) {
    const char* bad = "{not-json}\n";
    EXPECT_EQ(::write(a, bad, std::strlen(bad)),
              static_cast<ssize_t>(std::strlen(bad)));

    RecvBuffer buf{};
    EXPECT_THROW(recv_json(b, buf, 5000), std::runtime_error);
}

TEST_F(SocketPairTest, PartialFrameDelivery) {
    uint8_t header[4] = {0x00, 0x00, 0x00, 0x04};
    EXPECT_EQ(::write(a, header, 4), 4);

    std::this_thread::sleep_for(std::chrono::milliseconds(1));

    uint8_t payload[4] = {0xAA, 0xBB, 0xCC, 0xDD};
    EXPECT_EQ(::write(a, payload, 4), 4);

    RecvBuffer buf{};
    auto frame = recv_binary_frame(b, buf, 5000);

    ASSERT_EQ(frame.size(), 4u);
    EXPECT_EQ(frame[0], 0xAA);
    EXPECT_EQ(frame[3], 0xDD);
}

TEST_F(SocketPairTest, MultipleJsonInOneSegment) {
    std::string combined = R"({"type":"first"})" "\n" R"({"type":"second"})" "\n";
    EXPECT_EQ(::write(a, combined.c_str(), combined.size()),
              static_cast<ssize_t>(combined.size()));

    RecvBuffer buf{};
    auto r1 = recv_json(b, buf, 5000);
    EXPECT_EQ(r1["type"], "first");

    auto r2 = recv_json(b, buf, 5000);
    EXPECT_EQ(r2["type"], "second");
}

TEST_F(SocketPairTest, PhaseBoundaryJsonThenBinary) {
    // Single write: JSON + binary header + payload arrive in one segment so
    // recv_json() reads the whole thing in one read() call and leaves the
    // binary frame in RecvBuffer.accumulated.
    std::string json_msg = R"({"type":"session.ready"})" "\n";
    uint8_t header[4]  = {0x00, 0x00, 0x00, 0x03};
    uint8_t payload[3] = {0x10, 0x20, 0x30};

    std::vector<uint8_t> combined(json_msg.begin(), json_msg.end());
    combined.insert(combined.end(), header,  header  + 4);
    combined.insert(combined.end(), payload, payload + 3);
    EXPECT_EQ(::write(a, combined.data(), combined.size()),
              static_cast<ssize_t>(combined.size()));

    RecvBuffer buf{};

    auto r = recv_json(b, buf, 5000);
    EXPECT_EQ(r["type"], "session.ready");

    auto frame = recv_binary_frame(b, buf, 5000);
    ASSERT_EQ(frame.size(), 3u);
    EXPECT_EQ(frame[0], 0x10);
    EXPECT_EQ(frame[2], 0x30);
}

TEST_F(SocketPairTest, PartialHeaderBoundaryTest) {
    // Write JSON + first 2 of 4 header bytes in one segment so that
    // recv_json() buffers the partial header in RecvBuffer.accumulated.
    // The remaining 2 header bytes and the payload are written separately,
    // exercising recv_binary_frame()'s path that stitches the header from
    // accumulated + a subsequent read_exact() call.
    std::string json_msg = R"({"type":"ready"})" "\n";
    uint8_t partial_header[2] = {0x00, 0x00};   // first 2 of 4 header bytes

    std::vector<uint8_t> first_write(json_msg.begin(), json_msg.end());
    first_write.insert(first_write.end(), partial_header, partial_header + 2);
    EXPECT_EQ(::write(a, first_write.data(), first_write.size()),
              static_cast<ssize_t>(first_write.size()));

    RecvBuffer buf{};
    auto r = recv_json(b, buf, 5000);
    EXPECT_EQ(r["type"], "ready");

    // Exactly 2 partial header bytes must now be buffered in accumulated.
    ASSERT_EQ(buf.accumulated.size(), 2u);

    // Send the remaining 2 header bytes (length = 2) followed by payload.
    uint8_t rest[4] = {0x00, 0x02, 0xBE, 0xEF};
    EXPECT_EQ(::write(a, rest, 4), 4);

    auto frame = recv_binary_frame(b, buf, 5000);
    ASSERT_EQ(frame.size(), 2u);
    EXPECT_EQ(frame[0], 0xBE);
    EXPECT_EQ(frame[1], 0xEF);
}

TEST_F(SocketPairTest, ConnectionClosedOnEOF) {
    ::close(a);
    a = -1;

    RecvBuffer buf{};
    EXPECT_THROW(recv_json(b, buf, 1000), ConnectionClosed);
}

TEST_F(SocketPairTest, SendErrorRoundtrip) {
    send_error(a, ErrorCode::session_limit, "engine busy");

    RecvBuffer buf{};
    auto r = recv_json(b, buf, 5000);
    EXPECT_EQ(r["type"], "error");
    EXPECT_EQ(r["code"], "session_limit");
    EXPECT_EQ(r["message"], "engine busy");
}
