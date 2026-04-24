#include <gtest/gtest.h>

#include "ipc/session.h"
#include "ipc/protocol.h"
#include "config/config.h"
#include "config/interrupts.h"
#include "engine.h"
#include "backend/backend.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

// g_interrupted must be defined exactly once per test binary.
std::atomic<bool> g_interrupted{false};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static std::pair<int,int> make_pair() {
    int sv[2];
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0)
        return {-1, -1};
    return {sv[0], sv[1]};
}

// Write a 4-byte big-endian length + payload as a binary frame.
static void write_frame(int fd, const void* data, uint32_t len) {
    uint8_t hdr[4] = {
        static_cast<uint8_t>(len >> 24),
        static_cast<uint8_t>(len >> 16),
        static_cast<uint8_t>(len >> 8),
        static_cast<uint8_t>(len)
    };
    ::write(fd, hdr, 4);
    if (len > 0) ::write(fd, data, len);
}

// Write a zero-length sentinel frame.
static void write_sentinel(int fd) {
    write_frame(fd, nullptr, 0);
}

// ---------------------------------------------------------------------------
// MockBackend — lightweight Backend for session tests
// ---------------------------------------------------------------------------

class MockBackend : public Backend {
public:
    InferenceResult process(
        const std::vector<int16_t>&,
        int,
        const std::string&,
        std::function<void(float)>) override
    {
        return InferenceResult{"hello world", "", 10};
    }

    void unload_model() override {}

    InferenceResult process_stream(
        const std::vector<int16_t>&,
        int,
        const std::string&,
        const std::atomic<bool>& abort_flag,
        ProgressQueue& progress_queue) override
    {
        if (abort_flag.load(std::memory_order_relaxed)) {
            return InferenceResult{};
        }
        progress_queue.push(0.0f);
        if (delay_ms_ > 0) {
            auto deadline = std::chrono::steady_clock::now()
                          + std::chrono::milliseconds(delay_ms_);
            while (std::chrono::steady_clock::now() < deadline) {
                if (abort_flag.load(std::memory_order_relaxed)) {
                    return InferenceResult{};
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        }
        if (abort_flag.load(std::memory_order_relaxed)) {
            return InferenceResult{};
        }
        progress_queue.push(1.0f);
        return InferenceResult{result_text_, "", 10};
    }

    std::string name() const override { return "mock"; }

    void set_result(const std::string& text) { result_text_ = text; }
    void set_delay_ms(int ms) { delay_ms_ = ms; }

private:
    std::string result_text_{"hello world"};
    int delay_ms_{0};
};

// ---------------------------------------------------------------------------
// CooperativeSlowBackend — Backend that runs for a fixed duration, checking
// abort_flag every ~10 ms.  Used by ClientEofDuringInferenceAbortsPromptly to
// verify that stop_requested_ terminates a long-running inference quickly.
// ---------------------------------------------------------------------------

class CooperativeSlowBackend : public Backend {
public:
    explicit CooperativeSlowBackend(int delay_ms) : delay_ms_(delay_ms) {}

    InferenceResult process(
        const std::vector<int16_t>&,
        int,
        const std::string&,
        std::function<void(float)>) override
    {
        return InferenceResult{};
    }

    void unload_model() override {}

    InferenceResult process_stream(
        const std::vector<int16_t>&,
        int,
        const std::string&,
        const std::atomic<bool>& abort_flag,
        ProgressQueue&) override
    {
        auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::milliseconds(delay_ms_);
        while (std::chrono::steady_clock::now() < deadline) {
            if (abort_flag.load(std::memory_order_relaxed)) {
                return InferenceResult{};
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        return InferenceResult{"slow result", "", delay_ms_};
    }

    std::string name() const override { return "cooperative_slow"; }

private:
    int delay_ms_;
};

// ---------------------------------------------------------------------------
// Helper: create an Engine backed by MockBackend
// ---------------------------------------------------------------------------

static openverb::Engine make_mock_engine() {
    return openverb::Engine(Config{},
        std::make_unique<MockBackend>());
}

// ---------------------------------------------------------------------------
// Fixture
//
// engine_ is constructed with an empty Config — model_path is unset so
// ensure_loaded() will throw rather than succeed.  Tests that only drive the
// IDLE state never touch the Engine, so the empty config is safe.
// ---------------------------------------------------------------------------
class SessionTest : public ::testing::Test {
protected:
    int a{-1}, b{-1};
    openverb::Engine engine_{Config{}};

    void SetUp() override {
        auto [sa, sb] = make_pair();
        a = sa;
        b = sb;
    }

    void TearDown() override {
        if (a >= 0) ::close(a);
        if (b >= 0) ::close(b);
    }
};

// ---------------------------------------------------------------------------
// Test: IDLE timeout (no messages sent → session closes after timeout)
// ---------------------------------------------------------------------------
TEST_F(SessionTest, TimeoutOnIdle) {
    openverb::SessionConfig cfg{1, 1, 1, 4096};  // 1-second timeouts

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    auto start   = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();
    EXPECT_LT(elapsed, 5);
}  // ClientDisconnectDuringStreaming (StreamingSessionTest)

// ===========================================================================
// Negative — unknown message type in IDLE state is silently ignored
//
// IDLE state handles "session.start", "ping", "session.shutdown".
// Any other type must be discarded; the session must remain alive and
// respond to subsequent valid messages.
// ===========================================================================
TEST_F(SessionTest, UnknownMessageInIdleIsIgnored) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    send_json(a, nlohmann::json{{"type", "unknown.command"}, {"data", 42}});

    // Session must stay alive — confirm with ping/pong.
    send_json(a, nlohmann::json{{"type", "ping"}});
    auto pong = recv_json(a, buf, 3000);
    EXPECT_EQ(pong.value("type", ""), "pong")
        << "session did not survive an unknown message type: " << pong.dump();

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ===========================================================================
// Negative — malformed JSON in IDLE closes the connection cleanly
//
// A client that sends garbage bytes instead of valid JSON must not crash
// the session; it must exit cleanly and join within a few seconds.
// ===========================================================================
TEST_F(SessionTest, MalformedJsonInIdleCausesCleanExit) {
    openverb::SessionConfig cfg{3, 3, 3, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    const char garbage[] = "not json at all }{[";
    uint32_t len = static_cast<uint32_t>(sizeof(garbage) - 1);
    uint8_t hdr[4] = {
        static_cast<uint8_t>(len >> 24),
        static_cast<uint8_t>(len >> 16),
        static_cast<uint8_t>(len >> 8),
        static_cast<uint8_t>(len)
    };
    ::write(a, hdr, 4);
    ::write(a, garbage, len);

    auto start = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();

    EXPECT_LT(elapsed, 5)
        << "session hung after receiving malformed JSON in IDLE state";
}

// ---------------------------------------------------------------------------
// Test: ping → pong in IDLE state
// ---------------------------------------------------------------------------
TEST_F(SessionTest, PingPongInIdle) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    // Send ping
    send_json(a, nlohmann::json{{"type", "ping"}});

    // Expect pong
    RecvBuffer buf{};
    auto msg = recv_json(a, buf, 3000);
    EXPECT_EQ(msg["type"], "pong");

    // Close the client side so the session exits
    ::close(a);
    a = -1;
    session_thread.join();
}

// ---------------------------------------------------------------------------
// Test: session.shutdown in IDLE → DESTROYED cleanly
// ---------------------------------------------------------------------------
TEST_F(SessionTest, ShutdownInIdle) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    // Send shutdown
    send_json(a, nlohmann::json{{"type", "session.shutdown"}});

    // Session should exit cleanly; thread should join quickly
    auto start = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();
    EXPECT_LT(elapsed, 3);
}

// ---------------------------------------------------------------------------
// Test: multiple pings all get pong back
// ---------------------------------------------------------------------------
TEST_F(SessionTest, MultiplePings) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};
    for (int i = 0; i < 3; ++i) {
        send_json(a, nlohmann::json{{"type", "ping"}});
        auto msg = recv_json(a, buf, 3000);
        EXPECT_EQ(msg["type"], "pong");
    }

    // Shutdown cleanly
    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ---------------------------------------------------------------------------
// Test: client disconnect mid-IDLE → session exits without crash
// ---------------------------------------------------------------------------
TEST_F(SessionTest, ClientDisconnectInIdle) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    // Close client side immediately
    ::close(a);
    a = -1;

    auto start = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();
    EXPECT_LT(elapsed, 3);
}  // ClientDisconnectInIdle

// ---------------------------------------------------------------------------
// Test: session.start triggers WAITING_READY → engine load attempted →
//       error response sent → session returns to IDLE.
//
// Engine is constructed with an empty Config so ensure_loaded() throws.
// The session must catch the exception, send an error, and return to IDLE.
// ---------------------------------------------------------------------------
TEST_F(SessionTest, SessionStartTriggersLoadAttempt) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    // Trigger WAITING_READY
    send_json(a, nlohmann::json{{"type", "session.start"}});

    // Expect an error because no model is configured
    RecvBuffer buf{};
    auto msg = recv_json(a, buf, 3000);
    EXPECT_EQ(msg["type"], "error");
    EXPECT_EQ(msg["code"], "model_load_failed");

    // Session should be back in IDLE — verify with ping/pong
    send_json(a, nlohmann::json{{"type", "ping"}});
    auto pong = recv_json(a, buf, 3000);
    EXPECT_EQ(pong["type"], "pong");

    // Clean up
    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ---------------------------------------------------------------------------
// Test: session can be reused after a failed session.start (model load error).
//       Second session.start → another error → session still alive → shutdown.
// ---------------------------------------------------------------------------
TEST_F(SessionTest, SessionReuseAfterLoadError) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    // First attempt
    send_json(a, nlohmann::json{{"type", "session.start"}});
    auto err1 = recv_json(a, buf, 3000);
    EXPECT_EQ(err1["type"], "error");
    EXPECT_EQ(err1["code"], "model_load_failed");

    // Second attempt — session must still be alive
    send_json(a, nlohmann::json{{"type", "session.start"}});
    auto err2 = recv_json(a, buf, 3000);
    EXPECT_EQ(err2["type"], "error");
    EXPECT_EQ(err2["code"], "model_load_failed");

    // Confirm session is still responsive
    send_json(a, nlohmann::json{{"type", "ping"}});
    auto pong = recv_json(a, buf, 3000);
    EXPECT_EQ(pong["type"], "pong");

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ---------------------------------------------------------------------------
// Test: session.start with a context field — context must be accepted
//       without error (the field is optional; the error here is still the
//       model-not-found failure, not a protocol violation).
// ---------------------------------------------------------------------------
TEST_F(SessionTest, SessionStartWithContext) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    nlohmann::json start_msg;
    start_msg["type"]    = "session.start";
    start_msg["context"] = R"({"app":"test","window":"terminal"})";
    send_json(a, start_msg);

    RecvBuffer buf{};
    auto msg = recv_json(a, buf, 3000);
    // Still fails (no model), but must not produce a phase_violation or
    // malformed_json error — only inference_failed.
    EXPECT_EQ(msg["type"], "error");
    EXPECT_EQ(msg["code"], "model_load_failed");

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ===========================================================================
// StreamingSessionTest — uses MockBackend to test full session lifecycle
// ===========================================================================

class StreamingSessionTest : public ::testing::Test {
protected:
    int a{-1}, b{-1};
    openverb::Engine engine_{make_mock_engine()};

    void SetUp() override {
        auto [sa, sb] = make_pair();
        a = sa;
        b = sb;
    }

    void TearDown() override {
        if (a >= 0) ::close(a);
        if (b >= 0) ::close(b);
    }
};

// Helper: generate a single 480-sample (30ms at 16 kHz) speech-like frame.
// WebRTC VAD classifies full-scale random noise as speech.
static std::vector<int16_t> make_speech_frame() {
    static uint32_t seed = 42;
    std::vector<int16_t> frame(480);
    for (auto& s : frame) {
        seed = seed * 1664525u + 1013904223u;  // LCG
        s = static_cast<int16_t>((seed >> 16) & 0xFFFF);
    }
    return frame;
}

// Send N 480-sample speech frames as binary wire frames.
static void send_speech_frames(int fd, int count) {
    auto frame = make_speech_frame();
    uint32_t byte_len = static_cast<uint32_t>(frame.size() * sizeof(int16_t));
    for (int i = 0; i < count; ++i) {
        write_frame(fd, frame.data(), byte_len);
    }
}

// Skip streaming messages (progress, partial_result, queue_status,
// polish_started, polished_result) until a terminal message (result, error,
// or unknown type) arrives.
static nlohmann::json drain_to_terminal(int fd, RecvBuffer& buf, int timeout_ms = 30000) {
    while (true) {
        auto msg = recv_json(fd, buf, timeout_ms);
        auto t = msg.value("type", "");
        if (t == "progress" || t == "partial_result" || t == "queue_status" ||
            t == "polish_started" || t == "polished_result") {
            continue;
        }
        return msg;
    }
}

// ---------------------------------------------------------------------------
// Test: full streaming lifecycle — start → ready → speech audio → sentinel → result
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, FullStreamingLifecycle) {
    openverb::SessionConfig cfg{15, 30, 30, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    send_json(a, nlohmann::json{{"type", "session.start"}});

    auto ready = recv_json(a, buf, 3000);
    EXPECT_EQ(ready["type"], "session.ready");

    // Send enough speech frames to exceed MIN_CHUNK_MS so VadScanner emits
    // a chunk on flush().  MIN_CHUNK_MS = 3000 ms → 100 frames × 30 ms = 3000 ms.
    send_speech_frames(a, 100);

    write_sentinel(a);

    auto msg = drain_to_terminal(a, buf, 30000);

    EXPECT_EQ(msg["type"], "result");
    EXPECT_EQ(msg["text"], "hello world");

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ---------------------------------------------------------------------------
// Test: stall timeout — start → ready → no audio sent → timeout error
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, StallTimeout) {
    openverb::SessionConfig cfg{2, 1, 2, 4096};  // 2s idle timeout

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    send_json(a, nlohmann::json{{"type", "session.start"}});

    auto ready = recv_json(a, buf, 3000);
    EXPECT_EQ(ready["type"], "session.ready");

    // Session idle timeout is 2s; wait up to 5s so the test never races
    // against its own recv timeout and leaves session_thread joinable.
    auto msg = recv_json(a, buf, 5000);
    EXPECT_EQ(msg["type"], "error");
    EXPECT_EQ(msg["code"], "timeout");

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ---------------------------------------------------------------------------
// Test: session reuse — full cycle twice on same connection
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, SessionReuseAfterInference) {
    openverb::SessionConfig cfg{15, 30, 30, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    for (int cycle = 0; cycle < 2; ++cycle) {
        send_json(a, nlohmann::json{{"type", "session.start"}});

        auto ready = recv_json(a, buf, 5000);
        EXPECT_EQ(ready["type"], "session.ready");

        send_speech_frames(a, 100);
        write_sentinel(a);

        auto msg = drain_to_terminal(a, buf, 30000);
        EXPECT_EQ(msg["type"], "result");
    }

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ---------------------------------------------------------------------------
// Test: client closes connection mid-stream → session exits cleanly
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, DisconnectMidStream) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    send_json(a, nlohmann::json{{"type", "session.start"}});

    auto ready = recv_json(a, buf, 3000);
    EXPECT_EQ(ready["type"], "session.ready");

    int16_t sample = 1000;
    write_frame(a, &sample, sizeof(sample));

    std::this_thread::sleep_for(std::chrono::milliseconds(50));

    ::close(a);
    a = -1;

    auto start = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();
    EXPECT_LT(elapsed, 3);
}  // DisconnectMidStream

// ---------------------------------------------------------------------------
// Test: shutdown during inference aborts cleanly
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, ShutdownDuringInference) {
    auto mock = new MockBackend();
    mock->set_delay_ms(2000);
    openverb::Engine mock_engine(Config{},
        std::unique_ptr<Backend>(mock));

    openverb::SessionConfig cfg{5, 5, 5, 4096};

    auto [sa, sb] = make_pair();
    int ca = sa, cb = sb;

    std::thread session_thread([&]() {
        openverb::Session::handle_connection(cb, mock_engine, cfg);
    });

    RecvBuffer buf{};

    send_json(ca, nlohmann::json{{"type", "session.start"}});
    auto ready = recv_json(ca, buf, 3000);
    EXPECT_EQ(ready["type"], "session.ready");

    int16_t sample = 1000;
    write_frame(ca, &sample, sizeof(sample));
    write_sentinel(ca);

    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    send_json(ca, nlohmann::json{{"type", "session.shutdown"}});

    auto start = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();
    EXPECT_LT(elapsed, 5);

    ::close(ca);
    ::close(cb);
}

// ---------------------------------------------------------------------------
// Test: session.start during inference resets to new session
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, RestartDuringInference) {
    auto mock = new MockBackend();
    mock->set_delay_ms(2000);
    openverb::Engine mock_engine(Config{},
        std::unique_ptr<Backend>(mock));

    openverb::SessionConfig cfg{5, 5, 5, 4096};

    auto [sa, sb] = make_pair();
    int ca = sa, cb = sb;

    std::thread session_thread([&]() {
        openverb::Session::handle_connection(cb, mock_engine, cfg);
    });

    RecvBuffer buf{};

    send_json(ca, nlohmann::json{{"type", "session.start"}});
    auto ready = recv_json(ca, buf, 3000);
    EXPECT_EQ(ready["type"], "session.ready");

    int16_t sample = 1000;
    write_frame(ca, &sample, sizeof(sample));
    write_sentinel(ca);

    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    send_json(ca, nlohmann::json{{"type", "session.start"}});

    nlohmann::json msg;
    while (true) {
        msg = recv_json(ca, buf, 5000);
        if (!msg.contains("type")) break;
        if (msg["type"] == "session.ready") break;
    }
    EXPECT_EQ(msg["type"], "session.ready");

    write_sentinel(ca);

    msg = recv_json(ca, buf, 5000);
    while (msg.contains("type") && msg["type"] == "progress") {
        msg = recv_json(ca, buf, 5000);
    }
    EXPECT_EQ(msg["type"], "result");

    send_json(ca, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();

    ::close(ca);
    ::close(cb);
}

// ---------------------------------------------------------------------------
// Test: sentinel with no audio → empty result (VAD-to-zero path)
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, SentinelWithNoAudio) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    send_json(a, nlohmann::json{{"type", "session.start"}});

    auto ready = recv_json(a, buf, 3000);
    EXPECT_EQ(ready["type"], "session.ready");

    write_sentinel(a);

    auto msg = recv_json(a, buf, 3000);
    EXPECT_EQ(msg["type"], "result");
    EXPECT_EQ(msg["text"], "");

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ---------------------------------------------------------------------------
// Test: client disconnect during STREAMING_AUDIO → session exits cleanly
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, ClientDisconnectDuringStreaming) {
    openverb::SessionConfig cfg{5, 5, 5, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    send_json(a, nlohmann::json{{"type", "session.start"}});

    auto ready = recv_json(a, buf, 3000);
    EXPECT_EQ(ready["type"], "session.ready");

    int16_t sample = 1000;
    write_frame(a, &sample, sizeof(sample));

    std::this_thread::sleep_for(std::chrono::milliseconds(50));

    ::close(a);
    a = -1;

    auto start = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();
    EXPECT_LT(elapsed, 5);
}

// ---------------------------------------------------------------------------
// Test: client EOF during INFERRING (after sentinel sent) → session aborts
//       inference and exits within ~1 s.
//
// engineClient.disconnect() causes EOF on the engine side.  The session's
// INFERRING poll loop detects EOF (ConnectionClosed from recv_json), sets
// stop_requested_ (abort_flag), and joins the inference thread.
// CooperativeSlowBackend exits within ~10 ms of abort_flag being set,
// mirroring the per-token abort check in the real LlamaContext generation
// loop ("32-token abort check" boundary).
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, ClientEofDuringInferenceAbortsPromptly) {
    g_interrupted.store(false);

    const int BACKEND_RUN_MS = 3000;  // would run 3 s without abort

    auto [ca, cb] = make_pair();
    ASSERT_GE(ca, 0);

    openverb::Engine slow_engine(Config{},
        std::make_unique<CooperativeSlowBackend>(BACKEND_RUN_MS));

    openverb::SessionConfig cfg{5, 5, 30, 4096};

    std::thread session_thread([&]() {
        openverb::Session::handle_connection(cb, slow_engine, cfg);
    });

    RecvBuffer buf{};
    send_json(ca, nlohmann::json{{"type", "session.start"}});
    auto ready = recv_json(ca, buf, 3000);
    ASSERT_EQ(ready.value("type", ""), "session.ready")
        << "session did not become ready: " << ready.dump();

    // Send one audio sample so ring_buffer_ is non-empty, then the sentinel
    // to trigger the STREAMING_AUDIO → INFERRING transition.
    int16_t sample = 1000;
    write_frame(ca, &sample, sizeof(sample));
    write_sentinel(ca);

    // Give the session time to process the sentinel and enter INFERRING state.
    // The sentinel is already buffered; the session reads it synchronously.
    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    // Close the client socket — equivalent to engineClient.disconnect().
    // This causes EOF on the engine side (POLLHUP / 0-byte read on cb).
    ::close(ca);
    ca = -1;

    // The INFERRING poll loop detects EOF within one 100 ms wait interval,
    // sets stop_requested_, and joins the inference thread.
    // CooperativeSlowBackend exits within ~10 ms of the abort_flag being set.
    // Total recovery ≤ 100 ms (detect) + 10 ms (abort) + overhead << 1 s.
    auto t0 = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();

    EXPECT_LE(elapsed_ms, 1500)
        << "Session took " << elapsed_ms << " ms to exit after client EOF "
           "during inference; expected ≤ 1500 ms. "
           "abort_flag may not be reaching the generation loop.";

    ::close(cb);
    g_interrupted.store(false);
}

// ---------------------------------------------------------------------------
// Helper: send N 480-sample silence frames (all-zero PCM → VAD classifies as
// silence).  Used by StreamingPartialResultsMonotonicChunkIds to create the
// silence boundary that triggers a chunk split.
// ---------------------------------------------------------------------------
static void send_silence_frames(int fd, int count) {
    std::vector<int16_t> frame(480, 0);  // all-zero → silence
    uint32_t byte_len = static_cast<uint32_t>(frame.size() * sizeof(int16_t));
    for (int i = 0; i < count; ++i) {
        write_frame(fd, frame.data(), byte_len);
    }
}

// ---------------------------------------------------------------------------
// Test: streaming pipeline emits partial_result messages in monotonic chunk_id
//       order, and the last one carries is_final=true.
//
// Audio pattern:
//   100 speech frames (3 000 ms ≥ MIN_CHUNK_MS) + 20 silence frames
//   (600 ms = SILENCE_BOUNDARY_MS) + 100 more speech frames + sentinel.
//
// The number of chunks actually emitted depends on WebRTC VAD aggressiveness
// (mode 1 in DEFAULTS); the contract here is ordering + final-flag, not an
// exact chunk count.
//
// NOTE: the final result text is NOT the concatenation of partial texts — that
// invariant was replaced by the FinalInferenceRunsOnFullBuffer test, which
// verifies the sentinel handler runs one coherent inference on the full audio.
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, StreamingPartialResultsMonotonicChunkIds) {
    openverb::SessionConfig cfg{15, 30, 30, 4096};

    std::thread session_thread([this, &cfg]() {
        openverb::Session::handle_connection(b, engine_, cfg);
    });

    RecvBuffer buf{};

    send_json(a, nlohmann::json{{"type", "session.start"}});
    auto ready = recv_json(a, buf, 3000);
    ASSERT_EQ(ready.value("type", ""), "session.ready")
        << "session did not become ready: " << ready.dump();

    send_speech_frames(a, 100);   // 100 × 30 ms = 3 000 ms ≥ MIN_CHUNK_MS
    send_silence_frames(a, 20);   // 20  × 30 ms =   600 ms = SILENCE_BOUNDARY_MS
    send_speech_frames(a, 100);   // second utterance
    write_sentinel(a);

    // Collect all messages until a terminal (result / error) arrives.
    std::vector<nlohmann::json> partials;
    nlohmann::json terminal;
    while (true) {
        auto msg = recv_json(a, buf, 30000);
        auto t = msg.value("type", "");
        if (t == "partial_result") {
            partials.push_back(msg);
        } else if (t == "result" || t == "error") {
            terminal = msg;
            break;
        }
        // skip progress / queue_status / polish_started / polished_result
    }

    ASSERT_GE(partials.size(), 1u)
        << "Expected ≥1 partial_result message, got " << partials.size();

    // chunk_id must be strictly monotonically increasing.
    for (size_t i = 1; i < partials.size(); ++i) {
        int prev = partials[i - 1].value("chunk_id", -1);
        int curr = partials[i].value("chunk_id", -1);
        EXPECT_GT(curr, prev)
            << "chunk_id must be monotonically increasing at index " << i
            << ": " << prev << " → " << curr;
    }

    // Last partial must carry is_final=true.
    EXPECT_TRUE(partials.back().value("is_final", false))
        << "Last partial_result must have is_final=true";

    // Final terminal message must be a result.
    ASSERT_EQ(terminal.value("type", ""), "result");

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}

// ---------------------------------------------------------------------------
// CountingBackend — like MockBackend but tracks every process_stream() call
// and returns a distinct text per call (`stream-N`) so callers can tell which
// call produced the final result.  Used by FinalInferenceRunsOnFullBuffer.
// ---------------------------------------------------------------------------
class CountingBackend : public Backend {
public:
    std::atomic<int>    call_count{0};
    std::mutex          log_mu;
    std::vector<size_t> pcm_sizes;  // guarded by log_mu

    InferenceResult process(
        const std::vector<int16_t>&, int, const std::string&,
        std::function<void(float)>) override
    {
        return InferenceResult{};
    }

    void unload_model() override {}

    InferenceResult process_stream(
        const std::vector<int16_t>& pcm, int,
        const std::string&, const std::atomic<bool>&,
        ProgressQueue& progress_queue) override
    {
        int idx = call_count.fetch_add(1, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> lk(log_mu);
            pcm_sizes.push_back(pcm.size());
        }
        progress_queue.push(1.0f);
        return InferenceResult{std::string("stream-") + std::to_string(idx), "", 10};
    }

    std::string name() const override { return "counting"; }
};

// ---------------------------------------------------------------------------
// Test: the FINAL result text comes from ONE coherent inference on the full
//       PCM buffer, not from concatenation of per-chunk worker inferences.
//
// Why this matters: per-chunk inference cuts audio at silence boundaries that
// don't align with word boundaries.  The model hallucinates plausible completions
// for partial tokens on each edge, and concatenating those outputs produces
// garbage text.  The correct behaviour is: worker emits partials for the HUD
// only; the sentinel handler re-infers the full buffer once to produce the
// final transcript.
// ---------------------------------------------------------------------------
TEST_F(StreamingSessionTest, FinalInferenceRunsOnFullBuffer) {
    auto backend_owner = std::make_unique<CountingBackend>();
    CountingBackend* backend = backend_owner.get();
    openverb::Engine counting_engine(Config{}, std::move(backend_owner));

    openverb::SessionConfig cfg{15, 30, 30, 4096};

    std::thread session_thread([this, &cfg, &counting_engine]() {
        openverb::Session::handle_connection(b, counting_engine, cfg);
    });

    RecvBuffer buf{};
    send_json(a, nlohmann::json{{"type", "session.start"}});
    auto ready = recv_json(a, buf, 3000);
    ASSERT_EQ(ready.value("type", ""), "session.ready")
        << "session did not become ready: " << ready.dump();

    // 100 speech frames × 480 samples = 48000 samples total.  Enough to clear
    // MIN_CHUNK_MS so flush() emits one is_final chunk on the sentinel.
    send_speech_frames(a, 100);
    write_sentinel(a);

    // Drain streaming messages (progress, partial_result, queue_status,
    // polish_started, polished_result) until the terminal `result` arrives.
    nlohmann::json terminal;
    while (true) {
        auto msg = recv_json(a, buf, 30000);
        auto t = msg.value("type", "");
        if (t == "result" || t == "error") { terminal = msg; break; }
    }
    ASSERT_EQ(terminal.value("type", ""), "result") << terminal.dump();

    // Sanity: ≥2 process_stream calls total — at least one from the worker
    // (per-chunk) and one from the sentinel handler (full buffer).
    const int calls = backend->call_count.load(std::memory_order_relaxed);
    EXPECT_GE(calls, 2)
        << "expected ≥2 process_stream calls (worker chunk + sentinel full-buffer), "
        << "got " << calls << " — sentinel is not running a final full-buffer inference";

    // The final full-buffer call must have been the last one, and it must have
    // received all 48000 samples.  The worker's chunk calls receive fewer
    // samples per call (bounded by the VAD chunk).
    size_t last_size = 0;
    size_t max_size  = 0;
    {
        std::lock_guard<std::mutex> lk(backend->log_mu);
        ASSERT_FALSE(backend->pcm_sizes.empty());
        last_size = backend->pcm_sizes.back();
        for (auto s : backend->pcm_sizes) if (s > max_size) max_size = s;
    }
    EXPECT_EQ(last_size, 48000u)
        << "last process_stream call must receive the full 48000-sample buffer "
           "(got " << last_size << ")";
    EXPECT_EQ(max_size, 48000u)
        << "full-buffer call must be the largest (got max=" << max_size << ")";

    // The final text must be whatever the LAST (full-buffer) call returned,
    // not the worker's accumulated per-chunk text.  CountingBackend returns
    // "stream-N" where N is the zero-based call index; the last call's index
    // is (calls - 1).
    std::string expected = "stream-" + std::to_string(calls - 1);
    EXPECT_EQ(terminal.value("text", ""), expected)
        << "final result must come from the full-buffer inference, not the worker's accumulated chunks";

    send_json(a, nlohmann::json{{"type", "session.shutdown"}});
    session_thread.join();
}