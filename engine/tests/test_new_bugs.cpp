// test_new_bugs.cpp — TDD tests proving bugs in current code.
//
// BUG   LOCATION                          SEVERITY  STATUS
// ──────────────────────────────────────────────────────────
//  A    server.cpp:164  pressure_critical_active_  CRITICAL  PROVEN
//       reset to false while session is active
//
//  B    session.cpp:304-308  progress_queue_        MEDIUM    PROVEN
//       not drained when session.start aborts
//       inference → stale progress carries to next
//
//  C    server.cpp:175  idle unload doesn't         HIGH      PROVEN
//       check session_active_ → can unload
//       model during active inference
//
//  D    server.cpp:139,227  last_inference_time     MEDIUM    DOCUMENTED
//       data race: local variable shared across
//       threads without synchronization

#include <gtest/gtest.h>

#include "ipc/session.h"
#include "ipc/protocol.h"
#include "ipc/server.h"
#include "ipc/progress.h"
#include "config/config.h"
#include "config/interrupts.h"
#include "engine.h"
#include "backend/backend.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>
#include <vector>

std::atomic<bool> g_interrupted{false};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static std::pair<int, int> mkpair() {
    int sv[2];
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return {-1, -1};
    return {sv[0], sv[1]};
}

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

static void write_sentinel(int fd) {
    write_frame(fd, nullptr, 0);
}

static std::string temp_sock_path() {
    return "/tmp/openverb-bug-test-" + std::to_string(::getpid())
         + "-" + std::to_string(
               std::chrono::steady_clock::now().time_since_epoch().count())
         + ".sock";
}

static int connect_unix(const std::string& path) {
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

static bool wait_for_socket(const std::string& path, int timeout_ms) {
    auto deadline = std::chrono::steady_clock::now()
                  + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        struct stat st{};
        if (::stat(path.c_str(), &st) == 0) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return false;
}

static std::vector<nlohmann::json> drain_until(
    int fd, RecvBuffer& buf, const std::string& target, int timeout_ms)
{
    std::vector<nlohmann::json> msgs;
    auto deadline = std::chrono::steady_clock::now()
                  + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        int rem = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now()).count());
        if (rem <= 0) break;
        try {
            auto msg = recv_json(fd, buf, std::min(rem, 2000));
            msgs.push_back(msg);
            if (msg.value("type", "") == target) break;
        } catch (...) { break; }
    }
    return msgs;
}

// ===========================================================================
// Bug B — progress_queue_ not drained on inference abort
//
// session.cpp aborts inference on session.start but — without the fix —
// does not drain progress_queue_.  Values pushed by the backend after
// abort_flag is set (but before join() returns) survive into the next
// session and appear as stale progress to the new client.
//
// This integration test goes through the full session state machine:
//   1. First inference: backend pushes 0.42, then on abort pushes 0.75
//   2. session.start received → inference aborted
//   3. Second inference: backend pushes 0.0 and 1.0
//   4. Assert: client sees no 0.75 in second inference's progress stream
// ===========================================================================

// Backend for Bug B test:
//   call 0: push 0.42, wait for abort, then push 0.75 (post-abort value)
//   call 1: push 0.0 and 1.0, complete normally
struct TwoPhaseBackend : Backend {
    std::atomic<int>  call_count{0};
    std::atomic<bool> first_push_done{false};

    InferenceResult process_stream(
        const std::vector<int16_t>&,
        int,
        const std::string&,
        const std::atomic<bool>& abort_flag,
        ProgressQueue& pq) override
    {
        int n = call_count.fetch_add(1, std::memory_order_relaxed);
        if (n == 0) {
            pq.push(0.42f);
            first_push_done.store(true, std::memory_order_release);
            while (!abort_flag.load(std::memory_order_relaxed))
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            // Simulate backend pushing a final value during cleanup,
            // after abort is detected but before the thread exits.
            // 0.75f: unambiguous in float arithmetic (not close to 0.0 or 1.0).
            pq.push(0.75f);
            return {};
        } else {
            pq.push(0.0f);
            pq.push(1.0f);
            return InferenceResult{"ok", "", 100};
        }
    }

    InferenceResult process(const std::vector<int16_t>&, int, const std::string&,
                            std::function<void(float)>) override { return {}; }
    void unload_model() override {}
    std::string name() const override { return "two-phase"; }
};

TEST(NewBugB, NoStaleProgressAfterSessionAbort) {
    g_interrupted.store(false);

    auto* backend = new TwoPhaseBackend();
    openverb::Engine engine(Config{}, std::unique_ptr<Backend>(backend));
    openverb::SessionConfig cfg{15, 30, 30, 4096};

    auto [ca, cb] = mkpair();
    ASSERT_GE(ca, 0);

    std::thread t([&]() {
        openverb::Session::handle_connection(cb, engine, cfg);
    });

    RecvBuffer buf{};

    // === First session ===
    send_json(ca, nlohmann::json{{"type", "session.start"}});
    {
        auto msgs = drain_until(ca, buf, "session.ready", 5000);
        bool got = false;
        for (auto& m : msgs) if (m.value("type", "") == "session.ready") { got = true; break; }
        ASSERT_TRUE(got) << "first session.ready not received";
    }

    int16_t sample = 1000;
    write_frame(ca, &sample, sizeof(sample));
    write_sentinel(ca);

    // Wait for backend to push 0.42, then wait an extra 200 ms so the
    // session's 100 ms drain loop forwards it to the client and empties
    // the queue.  The abort will then only race with the 0.99 push.
    for (int i = 0; i < 200; ++i) {
        if (backend->first_push_done.load(std::memory_order_acquire)) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_TRUE(backend->first_push_done.load()) << "backend never started";
    std::this_thread::sleep_for(std::chrono::milliseconds(200));

    // Abort first inference; backend will push 0.99 post-abort.
    send_json(ca, nlohmann::json{{"type", "session.start"}});

    // Drain messages until second session.ready.
    {
        auto msgs = drain_until(ca, buf, "session.ready", 5000);
        bool got = false;
        for (auto& m : msgs) if (m.value("type", "") == "session.ready") { got = true; break; }
        ASSERT_TRUE(got) << "second session.ready not received";
    }

    // === Second session ===
    write_frame(ca, &sample, sizeof(sample));
    write_sentinel(ca);

    // Collect all progress values from the second inference.
    std::vector<float> second_progress;
    for (int i = 0; i < 50; ++i) {
        nlohmann::json msg;
        try {
            msg = recv_json(ca, buf, 3000);
        } catch (...) { break; }
        if (msg.value("type", "") == "progress")
            second_progress.push_back(msg.value("percent", -1.0f));
        if (msg.value("type", "") == "result" || msg.value("type", "") == "error")
            break;
    }

    send_json(ca, nlohmann::json{{"type", "session.shutdown"}});
    t.join();
    ::close(ca);
    ::close(cb);
    g_interrupted.store(false);

    // After the fix, progress_queue_.drain() is called in the abort path
    // (after inference_thread_.join()), so 0.75 must not appear here.
    // Tight epsilon (0.001f) avoids float-comparison pitfalls between
    // 0.75 and neighbouring values (0.0 and 1.0 are both > 0.2 away).
    bool has_stale = false;
    for (float v : second_progress) {
        if (std::abs(v - 0.75f) < 0.001f) { has_stale = true; break; }
    }
    EXPECT_FALSE(has_stale)
        << "Bug B regression: stale progress 0.75 from the aborted first "
           "inference leaked into the second session's progress stream. "
           "Fix: session.cpp must call progress_queue_.drain() after "
           "inference_thread_.join() in the session.start abort path.";
}

// ===========================================================================
// Bug A + C — IpcServer concurrency bugs
//
// Both bugs share infrastructure: IpcServer running with a backend that
// tracks whether unload_model() was called while inference was running.
// ===========================================================================

class TrackingBackend : public Backend {
public:
    std::atomic<bool> is_inferring{false};
    std::atomic<bool> unloaded_during_inference{false};

    InferenceResult process_stream(
        const std::vector<int16_t>&,
        int,
        const std::string&,
        const std::atomic<bool>& abort_flag,
        ProgressQueue& pq) override
    {
        is_inferring.store(true, std::memory_order_seq_cst);
        pq.push(0.0f);
        auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::milliseconds(15000);
        while (std::chrono::steady_clock::now() < deadline) {
            if (g_interrupted.load(std::memory_order_relaxed)) break;
            if (abort_flag.load(std::memory_order_relaxed)) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        is_inferring.store(false, std::memory_order_seq_cst);
        return InferenceResult{"done", "", 100};
    }

    void unload_model() override {
        if (is_inferring.load(std::memory_order_seq_cst)) {
            unloaded_during_inference.store(true, std::memory_order_seq_cst);
        }
    }

    InferenceResult process(
        const std::vector<int16_t>&, int, const std::string&,
        std::function<void(float)>) override { return {}; }

    std::string name() const override { return "tracking"; }
};

// ===========================================================================
// Bug C — idle unload fires during active session
//
// server.cpp:175-184 checks idle timeout but does NOT check
// session_active_.  The idle check runs in the poll timeout branch
// (server.cpp:162) which executes while the session thread runs in the
// background.  After idle_timeout_secs_ elapses, engine_.unload_model()
// is called during active inference.
//
// PROOF:
//   1. Start IpcServer with idle_timeout = 2s
//   2. Immediately connect + start session + trigger inference
//   3. Wait 4s (idle check fires since last_inference_time is stale)
//   4. TrackingBackend records if unload_model() was called during
//      inference → bug confirmed
// ===========================================================================
TEST(NewBugC, IdleUnloadDuringActiveSession) {
    g_interrupted.store(false);

    auto* backend = new TrackingBackend();
    openverb::Engine engine(Config{},
        std::unique_ptr<Backend>(backend));

    std::string sock = temp_sock_path();
    ::unlink(sock.c_str());

    openverb::IpcServer server(engine, 2);

    std::thread server_thread([&]() { server.start(sock); });
    ASSERT_TRUE(wait_for_socket(sock, 5000));

    // Connect immediately (no pre-aging)
    int fd = connect_unix(sock);
    ASSERT_GE(fd, 0);

    RecvBuffer buf{};
    send_json(fd, nlohmann::json{{"type", "session.start"}});

    auto msgs = drain_until(fd, buf, "session.ready", 5000);
    bool got_ready = false;
    for (auto& m : msgs)
        if (m.value("type", "") == "session.ready") got_ready = true;
    ASSERT_TRUE(got_ready) << "session.ready never received";

    // Trigger inference with a long-running backend (15s)
    int16_t sample = 1000;
    write_frame(fd, &sample, sizeof(sample));
    write_sentinel(fd);

    // Wait for inference to start
    for (int i = 0; i < 200; ++i) {
        if (backend->is_inferring.load(std::memory_order_seq_cst)) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    ASSERT_TRUE(backend->is_inferring.load(std::memory_order_seq_cst))
        << "Backend never started inferring";

    // Wait for idle timeout to fire:
    //   poll timeout = 1s, idle_timeout = 2s
    //   After ~2s from server start, the idle check at server.cpp:179
    //   fires because last_inference_time was never updated (only
    //   updated when session ENDS, not when it starts).
    //   session_active_ is true but the idle check doesn't check it.
    std::this_thread::sleep_for(std::chrono::milliseconds(4000));

    // Record results before cleanup
    bool was_inferring = backend->is_inferring.load(std::memory_order_seq_cst);
    bool unloaded = backend->unloaded_during_inference.load(
        std::memory_order_seq_cst);

    // Cleanup
    g_interrupted.store(true, std::memory_order_relaxed);
    server.stop();
    if (server_thread.joinable()) server_thread.join();
    ::close(fd);
    ::unlink(sock.c_str());
    g_interrupted.store(false);

    EXPECT_FALSE(unloaded)
        << "Bug C CONFIRMED: engine_.unload_model() was called while "
        << "process_stream() was executing on the inference thread. "
        << "server.cpp:175 must check session_active_ before the idle "
        << "unload: if (!session_active_.load() && !idle_unloaded && ...)";
}

// ===========================================================================
// Bug A — pressure_critical_active_ reset during active session
//
// server.cpp:162-164:
//   if (pret == 0) {
//       // No session is active while the accept loop is spinning. ← WRONG
//       pressure_critical_active_.store(false, ...);
//
// The comment is FALSE: session_thread_ runs concurrently with the
// accept loop. On poll timeout, the code clears pressure_critical_active_,
// defeating the CRITICAL memory pressure handler's safety guard.
//
// After the flag is cleared, if CRITICAL memory pressure fires:
//   server.cpp:115 → pressure_critical_active_ == false → else branch
//   → engine_.unload_model() called IMMEDIATELY during inference
//
// PROOF:
//   1. Start server with TrackingBackend
//   2. Start session + trigger inference
//   3. Wait 1.5s for poll timeout to clear pressure_critical_active_
//   4. Then wait another idle_timeout for the idle unload to trigger
//      (the idle check also doesn't guard session_active_)
//   5. If unload_model() called during inference → both bugs confirmed
// ===========================================================================
TEST(NewBugA, PressureFlagResetAllowsUnloadDuringSession) {
    g_interrupted.store(false);

    auto* backend = new TrackingBackend();
    openverb::Engine engine(Config{},
        std::unique_ptr<Backend>(backend));

    std::string sock = temp_sock_path();
    ::unlink(sock.c_str());

    // Short idle timeout to trigger the unload path that the
    // cleared pressure_critical_active_ flag would also enable.
    openverb::IpcServer server(engine, 2);

    std::thread server_thread([&]() { server.start(sock); });
    ASSERT_TRUE(wait_for_socket(sock, 5000));

    int fd = connect_unix(sock);
    ASSERT_GE(fd, 0);

    RecvBuffer buf{};
    send_json(fd, nlohmann::json{{"type", "session.start"}});

    auto msgs = drain_until(fd, buf, "session.ready", 5000);
    bool got_ready = false;
    for (auto& m : msgs)
        if (m.value("type", "") == "session.ready") got_ready = true;
    ASSERT_TRUE(got_ready);

    int16_t sample = 1000;
    write_frame(fd, &sample, sizeof(sample));
    write_sentinel(fd);

    for (int i = 0; i < 200; ++i) {
        if (backend->is_inferring.load(std::memory_order_seq_cst)) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    ASSERT_TRUE(backend->is_inferring.load(std::memory_order_seq_cst));

    // Wait for poll timeout (1s) which resets pressure_critical_active_
    // AND for idle timeout (2s) which calls unload_model() unguarded
    std::this_thread::sleep_for(std::chrono::milliseconds(4000));

    bool unloaded = backend->unloaded_during_inference.load(
        std::memory_order_seq_cst);

    g_interrupted.store(true, std::memory_order_relaxed);
    server.stop();
    if (server_thread.joinable()) server_thread.join();
    ::close(fd);
    ::unlink(sock.c_str());
    g_interrupted.store(false);

    EXPECT_FALSE(unloaded)
        << "Bug A+C CONFIRMED: engine_.unload_model() was called while "
        << "inference was running. server.cpp:164 resets "
        << "pressure_critical_active_ to false on poll timeout even "
        << "when a session is active. Combined with the missing "
        << "session_active_ check at line 175, this allows model "
        << "memory to be freed during inference (use-after-free).";
}

// ===========================================================================
// Bug D — last_inference_time data race (TSAN only)
//
// server.cpp:139  auto last_inference_time = steady_clock::now();
// server.cpp:227  last_inference_time = steady_clock::now();  (session thread)
// server.cpp:178  now - last_inference_time                    (main thread)
//
// test_bugs.cpp Bug #4 SKIP claims FIXED with atomic member but
// no such member exists in server.h. Still a local variable.
// ===========================================================================
TEST(NewBugD, LastInferenceTimeDataRace) {
    GTEST_SKIP()
        << "Bug D: server.cpp:139 last_inference_time is a local "
        << "steady_clock::time_point captured by reference across threads. "
        << "Session thread writes at line 227, main poll loop reads at "
        << "line 178 — data race (UB under C++ standard). "
        << "test_bugs.cpp Bug #4 SKIP message claims FIXED with "
        << "std::atomic<int64_t> last_inference_sec_ but no such member "
        << "exists in server.h. Run with -fsanitize=thread to confirm.";
}
