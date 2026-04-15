#ifdef OPENVERB_INTEGRATION_TESTS

#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <glob.h>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "config/config.h"
#include "config/defaults.h"
#include "engine.h"
#include "ipc/protocol.h"
#include "ipc/server.h"

std::atomic<bool> g_interrupted{false};

namespace {

std::string fixtures_dir() {
    std::string p = __FILE__;
    auto sep = p.find_last_of("/\\");
    return (sep != std::string::npos ? p.substr(0, sep + 1) : std::string("./"))
           + "fixtures/";
}

std::string make_socket_path() {
    auto ns = std::chrono::steady_clock::now().time_since_epoch().count();
    return "/tmp/openverb-test-" + std::to_string(::getpid()) + "-"
           + std::to_string(ns) + ".sock";
}

int connect_to(const std::string& path) {
    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        return -1;
    }
    return fd;
}

void write_fully(int fd, const void* data, size_t len) {
    auto ptr = static_cast<const uint8_t*>(data);
    size_t written = 0;
    while (written < len) {
        ssize_t n = ::write(fd, ptr + written, len - written);
        if (n < 0) {
            if (errno == EINTR) continue;
            throw std::runtime_error("write_fully failed");
        }
        written += static_cast<size_t>(n);
    }
}

void send_frame(int fd, const uint8_t* data, size_t len) {
    uint8_t header[4];
    uint32_t n = static_cast<uint32_t>(len);
    header[0] = static_cast<uint8_t>((n >> 24) & 0xFF);
    header[1] = static_cast<uint8_t>((n >> 16) & 0xFF);
    header[2] = static_cast<uint8_t>((n >>  8) & 0xFF);
    header[3] = static_cast<uint8_t>(n & 0xFF);
    write_fully(fd, header, 4);
    if (len > 0) write_fully(fd, data, len);
}

void send_sentinel(int fd) {
    uint8_t header[4] = {0, 0, 0, 0};
    write_fully(fd, header, 4);
}

std::vector<uint8_t> read_wav_pcm(const std::string& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return {};
    auto sz = f.tellg();
    f.seekg(0);
    std::vector<uint8_t> data(static_cast<size_t>(sz));
    f.read(reinterpret_cast<char*>(data.data()), static_cast<std::streamsize>(sz));
    if (data.size() <= 44) return {};
    return {data.begin() + 44, data.end()};
}

bool wait_for_file(const std::string& path, int timeout_ms) {
    auto deadline = std::chrono::steady_clock::now()
                    + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        struct stat st{};
        if (::stat(path.c_str(), &st) == 0) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return false;
}

std::string find_mmproj(const std::string& model_path) {
    std::string dir;
    auto sep = model_path.rfind('/');
    dir = (sep != std::string::npos) ? model_path.substr(0, sep) : ".";
    std::string pattern = dir + "/*mmproj*.gguf";
    glob_t g{};
    std::string result;
    if (::glob(pattern.c_str(), 0, nullptr, &g) == 0 && g.gl_pathc > 0) {
        result = g.gl_pathv[0];
    }
    ::globfree(&g);
    return result;
}

nlohmann::json drain_until_result(int fd, RecvBuffer& buf, int timeout_ms = 60000) {
    for (;;) {
        auto msg = recv_json(fd, buf, timeout_ms);
        std::string type = msg.value("type", "");
        if (type == "result" || type == "error") return msg;
    }
}

} // namespace

class IpcIntegrationTest : public ::testing::Test {
protected:
    void SetUp() override {
        socket_path_ = make_socket_path();
        ::unlink(socket_path_.c_str());

        const char* env = std::getenv("OPENVERB_TEST_MODEL");
        has_model_ = env && env[0] != '\0';

        Config cfg;
        if (has_model_) {
            cfg.model_path  = env;
            cfg.mmproj_path = find_mmproj(env);
            cfg.threads     = 2;
            cfg.ctx_size    = 4096;
        }

        engine_ = std::make_unique<openverb::Engine>(std::move(cfg));
        server_ = std::make_unique<openverb::IpcServer>(*engine_);
        server_thread_ = std::thread([this]() {
            server_->start(socket_path_);
        });

        ASSERT_TRUE(wait_for_file(socket_path_, 5000))
            << "Server socket did not appear: " << socket_path_;
    }

    void TearDown() override {
        g_interrupted.store(true, std::memory_order_relaxed);
        server_->stop();
        if (server_thread_.joinable()) server_thread_.join();
        g_interrupted.store(false, std::memory_order_relaxed);
        ::unlink(socket_path_.c_str());
    }

    void RequireModel() {
        if (!has_model_) {
            GTEST_SKIP() << "OPENVERB_TEST_MODEL not set; skipping";
        }
    }

    bool has_model_ = false;
    std::string socket_path_;
    std::unique_ptr<openverb::Engine> engine_;
    std::unique_ptr<openverb::IpcServer> server_;
    std::thread server_thread_;
};

TEST_F(IpcIntegrationTest, PingPong) {
    int fd = connect_to(socket_path_);
    ASSERT_GE(fd, 0);
    RecvBuffer buf{};

    send_json(fd, nlohmann::json{{"type", "ping"}});
    auto resp = recv_json(fd, buf, 5000);
    EXPECT_EQ(resp.value("type", ""), "pong");

    ::close(fd);
}

TEST_F(IpcIntegrationTest, ConcurrentConnectionRejection) {
    int fd1 = connect_to(socket_path_);
    ASSERT_GE(fd1, 0);

    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    int fd2 = connect_to(socket_path_);
    ASSERT_GE(fd2, 0);

    RecvBuffer buf2{};
    auto resp = recv_json(fd2, buf2, 5000);
    EXPECT_EQ(resp.value("type", ""), "error");
    EXPECT_EQ(resp.value("code", ""), "session_limit");

    ::close(fd2);
    ::close(fd1);
}

TEST_F(IpcIntegrationTest, ClientDisconnectRecovery) {
    {
        int fd = connect_to(socket_path_);
        ASSERT_GE(fd, 0);
        ::close(fd);
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    int fd2 = connect_to(socket_path_);
    ASSERT_GE(fd2, 0);
    RecvBuffer buf{};

    send_json(fd2, nlohmann::json{{"type", "ping"}});
    auto resp = recv_json(fd2, buf, 5000);
    EXPECT_EQ(resp.value("type", ""), "pong");

    ::close(fd2);
}

TEST_F(IpcIntegrationTest, SessionStartReady) {
    RequireModel();

    int fd = connect_to(socket_path_);
    ASSERT_GE(fd, 0);
    RecvBuffer buf{};

    send_json(fd, nlohmann::json{
        {"type", "session.start"},
        {"context", nlohmann::json::object()}
    });

    auto resp = recv_json(fd, buf, 30000);
    EXPECT_EQ(resp.value("type", ""), "session.ready");

    ::close(fd);
}

TEST_F(IpcIntegrationTest, FullSessionWithAudio) {
    RequireModel();

    int fd = connect_to(socket_path_);
    ASSERT_GE(fd, 0);
    RecvBuffer buf{};

    send_json(fd, nlohmann::json{
        {"type", "session.start"},
        {"context", nlohmann::json::object()}
    });
    auto ready = recv_json(fd, buf, 30000);
    ASSERT_EQ(ready.value("type", ""), "session.ready")
        << "Expected session.ready, got: " << ready.dump();

    auto pcm = read_wav_pcm(fixtures_dir() + "sine_440hz.wav");
    ASSERT_FALSE(pcm.empty());

    size_t off = 0;
    while (off < pcm.size()) {
        size_t chunk = std::min(static_cast<size_t>(CHUNK_BYTES),
                                pcm.size() - off);
        send_frame(fd, pcm.data() + off, chunk);
        off += chunk;
    }
    send_sentinel(fd);

    auto result = drain_until_result(fd, buf, 60000);
    EXPECT_EQ(result.value("type", ""), "result");
    EXPECT_FALSE(result.value("text", "").empty())
        << "Model produced empty text for non-silent audio";

    ::close(fd);
}

TEST_F(IpcIntegrationTest, SessionReuse) {
    RequireModel();

    int fd = connect_to(socket_path_);
    ASSERT_GE(fd, 0);
    RecvBuffer buf{};

    // --- Session 1: no audio → empty result ---
    send_json(fd, nlohmann::json{
        {"type", "session.start"},
        {"context", nlohmann::json::object()}
    });
    auto r1 = recv_json(fd, buf, 30000);
    ASSERT_EQ(r1.value("type", ""), "session.ready");

    send_sentinel(fd);
    auto res1 = drain_until_result(fd, buf, 30000);
    EXPECT_EQ(res1.value("type", ""), "result");
    EXPECT_EQ(res1.value("text", ""), "");

    // --- Session 2: real audio → non-empty result ---
    send_json(fd, nlohmann::json{
        {"type", "session.start"},
        {"context", nlohmann::json::object()}
    });
    auto r2 = recv_json(fd, buf, 30000);
    ASSERT_EQ(r2.value("type", ""), "session.ready");

    auto pcm = read_wav_pcm(fixtures_dir() + "sine_440hz.wav");
    ASSERT_FALSE(pcm.empty());
    size_t off = 0;
    while (off < pcm.size()) {
        size_t chunk = std::min(static_cast<size_t>(CHUNK_BYTES),
                                pcm.size() - off);
        send_frame(fd, pcm.data() + off, chunk);
        off += chunk;
    }
    send_sentinel(fd);

    auto res2 = drain_until_result(fd, buf, 60000);
    EXPECT_EQ(res2.value("type", ""), "result");
    EXPECT_FALSE(res2.value("text", "").empty());

    ::close(fd);
}

// ---------------------------------------------------------------------------
// DisconnectDuringInference
//
// Verifies that closing the client socket (EOF) while the engine is in the
// INFERRING state causes the engine to abort inference and return to an
// accepting state within ~1 s.  The abort_flag is checked every token in
// the generation loop, so the engine should react within a few tokens
// (the "32-token abort check" boundary).
// ---------------------------------------------------------------------------
TEST_F(IpcIntegrationTest, DisconnectDuringInference) {
    RequireModel();

    // --- Phase 1: connect, start session, send audio, trigger inference ---
    int fd = connect_to(socket_path_);
    ASSERT_GE(fd, 0);
    RecvBuffer buf{};

    send_json(fd, nlohmann::json{
        {"type", "session.start"},
        {"context", nlohmann::json::object()}
    });
    auto ready = recv_json(fd, buf, 30000);
    ASSERT_EQ(ready.value("type", ""), "session.ready")
        << "Expected session.ready, got: " << ready.dump();

    auto pcm = read_wav_pcm(fixtures_dir() + "sine_440hz.wav");
    ASSERT_FALSE(pcm.empty());

    size_t off = 0;
    while (off < pcm.size()) {
        size_t chunk = std::min(static_cast<size_t>(CHUNK_BYTES),
                                pcm.size() - off);
        send_frame(fd, pcm.data() + off, chunk);
        off += chunk;
    }
    send_sentinel(fd);

    // Give the engine a moment to enter the INFERRING state, then close
    // the socket to simulate an abrupt client disconnect (EOF on server side).
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    ::close(fd);

    // --- Phase 2: verify the server recovers and accepts a new connection ---
    auto recover_start = std::chrono::steady_clock::now();
    int fd2 = -1;

    // Retry loop: the engine needs to abort inference and return to IDLE.
    // Should happen within ~1 s (abort_flag checked every token).
    for (int attempt = 0; attempt < 20; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        fd2 = connect_to(socket_path_);
        if (fd2 >= 0) break;
    }

    ASSERT_GE(fd2, 0) << "Server did not accept a new connection within 2 s "
                       << "after client disconnect during inference";

    // Verify the new connection is functional (ping/pong).
    RecvBuffer buf2{};
    send_json(fd2, nlohmann::json{{"type", "ping"}});
    auto resp = recv_json(fd2, buf2, 3000);
    EXPECT_EQ(resp.value("type", ""), "pong");

    auto recover_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - recover_start).count();
    EXPECT_LT(recover_ms, 2000)
        << "Engine took " << recover_ms << "ms to recover after disconnect";

    ::close(fd2);
}

#endif // OPENVERB_INTEGRATION_TESTS
