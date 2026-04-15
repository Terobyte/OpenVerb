// test_sprint_bugs.cpp — TDD proof-of-bugs for the sprint bug report.
//
// CRITICAL
//   Bug 1  capture.cpp:74-75  AudioQueueDispose(true) during active callback
//   Bug 2  server.cpp:264-265 dispatch_sync on concurrent queue is not a barrier
//
// MODERATE
//   Bug 3  engine.cpp:77-137  process_file() accesses backend_ after releasing mutex
//   Bug 4  session.cpp:379    ConnectionClosed swallowed during INFERRING — CPU wasted
//
// MINOR
//   Bug 5  ring_buffer.cpp:14 Byte-by-byte write() is ~10-50x slower than memcpy
//   Bug 6  ring_buffer.cpp:30 read_idx_ advances past unread byte when avail is odd
//   Bug 7  session.cpp:140    std::async timeout doesn't interrupt model load
//
// Tests for Bugs 6 and 7 already exist and are currently FAILING:
//   BugRegression.ReadAllOddByteCountOverflows
//   BugRegression.FiveByteWriteCausesReadAllOverflow
//   TDD_Bug5_High.AsyncTimeoutBlocksForeverOnHangingLoad
//
// This file adds the test for Bug 4 (the only moderate bug without a test)
// and documents Bugs 1, 2, 3, 5 where a unit test is not feasible.

#include <gtest/gtest.h>

#include "ipc/session.h"
#include "ipc/protocol.h"
#include "config/config.h"
#include "config/interrupts.h"
#include "engine.h"
#include "backend/backend.h"
#include "audio/ring_buffer.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

// Every test binary that uses g_interrupted must define it exactly once.
std::atomic<bool> g_interrupted{false};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static std::pair<int, int> sprint_socketpair() {
    int sv[2];
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return {-1, -1};
    return {sv[0], sv[1]};
}

static void sprint_write_frame(int fd, const void* data, uint32_t len) {
    uint8_t hdr[4] = {
        static_cast<uint8_t>(len >> 24),
        static_cast<uint8_t>(len >> 16),
        static_cast<uint8_t>(len >> 8),
        static_cast<uint8_t>(len)
    };
    ::write(fd, hdr, 4);
    if (len > 0) ::write(fd, data, len);
}

static void sprint_write_sentinel(int fd) {
    sprint_write_frame(fd, nullptr, 0);
}

// SlowBackend: runs for `run_ms_` milliseconds, checks both g_interrupted
// and abort_flag every 10 ms — matches the LlamaContext generation loop.
class SlowBackend : public Backend {
public:
    explicit SlowBackend(int run_ms) : run_ms_(run_ms) {}

    std::atomic<bool> inference_started{false};

    InferenceResult process_stream(
        const std::vector<int16_t>&,
        int,
        const std::string&,
        const std::atomic<bool>& abort_flag,
        ProgressQueue& pq) override
    {
        inference_started.store(true, std::memory_order_release);
        pq.push(0.0f);
        auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::milliseconds(run_ms_);
        while (std::chrono::steady_clock::now() < deadline) {
            if (g_interrupted.load(std::memory_order_relaxed)) break;
            if (abort_flag.load(std::memory_order_relaxed))    break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        pq.push(1.0f);
        return InferenceResult{"done", "", run_ms_};
    }

    InferenceResult process(const std::vector<int16_t>&, int,
                            const std::string&,
                            std::function<void(float)>) override { return {}; }
    void unload_model() override {}
    std::string name() const override { return "slow"; }

private:
    int run_ms_;
};

// ===========================================================================
// CRITICAL — Bug 1: AudioQueueDispose(true) during active callback
//
// Location: capture.cpp:74-75
//
//   AudioQueueStop(impl_->queue, true);
//   AudioQueueDispose(impl_->queue, true);  // ← BUG
//
// Apple AudioToolbox docs state:
//   "Do not call AudioQueueDispose with inImmediate=true when a callback
//    might be in progress."
//
// AudioQueueStop(q, true) is synchronous — it waits for the CURRENT buffer
// callback to finish, then stops. But the queue may still have pending
// buffers queued (from AudioQueueEnqueueBuffer) that will fire callbacks
// after Stop() returns.
//
// AudioQueueDispose(q, true) with inImmediate=true tears down the queue
// immediately. If a callback fires AFTER Dispose but BEFORE the OS has
// fully torn down the callback infrastructure:
//   self->queue    → freed memory
//   buffer->mAudioData → freed memory
//   AudioQueueEnqueueBuffer(self->queue, ...) → use-after-free
//
// Fix: AudioQueueDispose(impl_->queue, false);
//      (false = synchronous / non-immediate — waits for all pending
//       callbacks to complete THEN disposes. Equivalent to a safe barrier.)
//
// Not unit-testable: requires actual AudioQueue hardware + timing to trigger.
// Verify with ASAN build + microphone capture under load.
// ===========================================================================

TEST(SprintBug1_Critical, AudioQueueDisposeImmediateDuringActiveCallback) {
    GTEST_SKIP()
        << "Bug 1 (CRITICAL) — capture.cpp:75\n"
        << "  AudioQueueDispose(impl_->queue, true) — inImmediate=true is unsafe\n"
        << "  Apple docs: 'Do not call AudioQueueDispose with inImmediate=true\n"
        << "  when a callback might be in progress.'\n"
        << "  AudioQueueStop(true) waits for current callback only; pending\n"
        << "  re-enqueued buffers can still fire AFTER Stop() returns.\n"
        << "  AudioQueueDispose(true) then frees queue+buffer memory while\n"
        << "  callback may still hold a reference → use-after-free.\n"
        << "  Fix: AudioQueueDispose(impl_->queue, false);\n"
        << "  (false = non-immediate = safe drain before dispose)\n"
        << "  Test with ASAN + real microphone capture.";
}

// ===========================================================================
// CRITICAL — Bug 2: dispatch_sync on concurrent queue is not a barrier
//
// Location: server.cpp:264-265
//
//   dispatch_source_cancel(mem_source_);
//   dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{});
//   dispatch_release(mem_source_);
//
// Apple GCD docs: dispatch_sync() on a CONCURRENT queue submits a block and
// waits for THAT block to complete. It does NOT drain all previously-submitted
// blocks on the queue. Other blocks (including the mem_source_ event handler)
// may still be running on worker threads.
//
// Race window:
//   T1 (main): dispatch_source_cancel(mem_source_)
//   T2 (GCD):  memory pressure event fires, handler block is dispatched
//              (the OS queued this before cancel was processed)
//   T1 (main): dispatch_sync completes (unrelated block)
//   T1 (main): dispatch_release(mem_source_); IpcServer dtor fires
//   T2 (GCD):  handler executes: self->pressure_force_unload_ = ...
//              → self is a dangling pointer → use-after-free
//
// dispatch_source_cancel() schedules the cancellation handler but the event
// handler may already be in-flight on a concurrent queue thread.
//
// Fix: Use dispatch_source_set_cancel_handler and dispatch a barrier on the
// source's queue, or use a dispatch_group to track handler completion:
//
//   dispatch_group_t grp = dispatch_group_create();
//   dispatch_source_set_event_handler(mem_source_, ^{
//       dispatch_group_enter(grp);
//       // ... handler body ...
//       dispatch_group_leave(grp);
//   });
//   // In stop():
//   dispatch_source_cancel(mem_source_);
//   dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
//   dispatch_release(mem_source_);
//   dispatch_release(grp);
//
// Not unit-testable: requires GCD memory pressure simulation.
// Verify with AddressSanitizer + daemon under memory pressure stress.
// ===========================================================================

TEST(SprintBug2_Critical, DispatchSyncOnConcurrentQueueIsNotBarrier) {
    GTEST_SKIP()
        << "Bug 2 (CRITICAL) — server.cpp:264-265\n"
        << "  dispatch_sync(get_global_queue(UTILITY), ^{}) is NOT a barrier.\n"
        << "  It only waits for the submitted block — not all in-flight handlers.\n"
        << "  The mem_source_ event handler may still be running on a worker\n"
        << "  thread when dispatch_release() is called → use-after-free on `self`.\n"
        << "  Fix: Use dispatch_group to track handler entry/exit, wait on group\n"
        << "  before release. Or use a serial queue for the handler.\n"
        << "  Verify with ASAN + memory pressure simulation (leaks/memgraph).";
}

// ===========================================================================
// MODERATE — Bug 3: process_file() accesses backend_ without holding mutex
//
// Location: engine.cpp:77-137
//
//   InferenceResult Engine::process_file(...) {
//       ensure_loaded();          // acquires + releases engine_mutex_
//       ...
//       return backend_->process(...);  // ← no lock held here
//   }
//
// If unload_model() is called concurrently from another thread (e.g. in a
// hypothetical future multi-client scenario), it calls:
//   backend_->unload_model()     // sets llama_ = nullptr
//   loaded_.store(false)
//
// Then backend_->process() → process_impl() → llama_->infer() crashes
// on null pointer dereference.
//
// In current usage process_file() is only called in single-threaded CLI mode
// so the race cannot trigger. However process_stream() correctly holds the
// mutex for the full duration (which creates a different deadlock risk).
//
// The design inconsistency means the correct fix depends on the intended
// threading model. Options:
//   a) Hold engine_mutex_ for the duration of process_file() (match process_stream)
//   b) Use shared_ptr<Backend> so unload_model() doesn't invalidate the ptr
//   c) Document that process_file() is single-threaded only (status quo)
//
// Not unit-testable without a multi-threaded caller for process_file().
// ===========================================================================

TEST(SprintBug3_Moderate, ProcessFileAccessesBackendWithoutMutex) {
    GTEST_SKIP()
        << "Bug 3 (MODERATE) — engine.cpp:77-137\n"
        << "  process_file() calls ensure_loaded() (mutex acquired+released)\n"
        << "  then accesses backend_->process() without holding engine_mutex_.\n"
        << "  Concurrent unload_model() resets llama_ to nullptr →\n"
        << "  backend_->process() crashes with null pointer dereference.\n"
        << "  Safe in current usage (process_file = CLI single-threaded only).\n"
        << "  Fix: hold engine_mutex_ across the backend_->process() call,\n"
        << "  or use shared_ptr<Backend> for safe concurrent access.";
}

// ===========================================================================
// MODERATE — Bug 4: ConnectionClosed during INFERRING state silently swallowed
//
// Location: session.cpp:379
//
//   } catch (...) {}   // ← swallows ConnectionClosed during inference poll
//
// The INFERRING state polls the socket for client commands (session.start,
// session.shutdown) while inference runs in a background thread. When the
// client disconnects, ::poll() returns POLLIN (EOF), recv_json() throws
// ConnectionClosed, and the catch-all discards it. Inference continues
// burning CPU/GPU for a dead connection until it naturally completes.
//
// Test: Use a 3-second backend. Close client socket after 200ms (mid-
// inference). Session should abort within ~500ms of the disconnect.
// With the bug, the session continues for the full remaining ~2800ms.
// ===========================================================================

TEST(SprintBug4_Moderate, DisconnectDuringInferenceAbortsSessionPromptly) {
    // Suppress SIGPIPE — the session sends to a closed socket (EOF sends SIGPIPE
    // on some paths). We want the write to fail with EPIPE, not kill the process.
    ::signal(SIGPIPE, SIG_IGN);
    g_interrupted.store(false);

    const int BACKEND_RUN_MS  = 3000;  // would run 3s without abort
    const int DISCONNECT_MS   = 200;   // disconnect after 200ms of inference
    // Expected: session exits within DISCONNECT_MS + abort_latency + margin
    // SlowBackend checks abort_flag every 10ms → abort_latency ≈ 10ms
    const long MAX_JOIN_MS    = 600;

    auto* backend = new SlowBackend(BACKEND_RUN_MS);
    openverb::Engine engine(Config{}, std::unique_ptr<Backend>(backend));

    auto [ca, cb] = sprint_socketpair();
    ASSERT_GE(ca, 0);

    openverb::SessionConfig cfg{5, 5, 30, 4096};  // 30s inference timeout

    std::thread session_thread([&]() {
        openverb::Session::handle_connection(cb, engine, cfg);
    });

    RecvBuffer buf{};
    send_json(ca, nlohmann::json{{"type", "session.start"}});
    auto ready = recv_json(ca, buf, 3000);
    ASSERT_EQ(ready.value("type", ""), "session.ready")
        << "session.ready not received: " << ready.dump();

    // Send one audio frame + sentinel to trigger INFERRING state.
    int16_t sample = 1000;
    sprint_write_frame(ca, &sample, sizeof(sample));
    sprint_write_sentinel(ca);

    // Wait until the backend actually enters process_stream().
    // Without this, we might close before inference even starts and
    // the disconnect would be caught in STREAMING_AUDIO state instead.
    for (int i = 0; i < 100; ++i) {
        if (backend->inference_started.load(std::memory_order_acquire)) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    ASSERT_TRUE(backend->inference_started.load(std::memory_order_acquire))
        << "Backend never started inferring — test setup failed";

    // Wait a bit longer so the INFERRING poll loop has at least one cycle.
    std::this_thread::sleep_for(std::chrono::milliseconds(DISCONNECT_MS));

    // ── Simulate client disconnect ────────────────────────────────────────
    ::close(ca);
    ca = -1;

    // Measure how long it takes for the session to detect the disconnect
    // and abort inference.
    auto t0 = std::chrono::steady_clock::now();
    session_thread.join();
    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t0).count();

    EXPECT_LE(elapsed_ms, MAX_JOIN_MS)
        << "Bug 4 CONFIRMED: session took " << elapsed_ms << " ms to exit "
           "after client disconnect; expected ≤ " << MAX_JOIN_MS << " ms.\n"
           "ConnectionClosed is swallowed in session.cpp:379 catch(...){} "
           "so inference continues for a dead connection.\n"
           "Fix: catch (const ConnectionClosed&) explicitly and set "
           "stop_requested_ = true before breaking.";

    if (ca >= 0) ::close(ca);
    ::close(cb);
    g_interrupted.store(false);
}

// ===========================================================================
// MINOR — Bug 5: ring_buffer write() is byte-by-byte (O(n) vs memcpy O(1))
//
// Location: ring_buffer.cpp:14-16
//
//   for (size_t i = 0; i < n; ++i) {
//       buf_[(w + i) & MASK] = src[i];   // ← 1 byte at a time
//   }
//
// For a 4096-byte audio frame this is ~4096 iterations instead of at most
// 2 memcpy() calls. At 16kHz × 2 bytes × 100 callbacks/sec = 3.2 MB/s
// throughput, the byte loop wastes ~40 µs per frame vs ~1 µs with memcpy.
//
// The wrap-around case (write spans the ring end) requires two memcpy calls:
//   size_t first  = min(n, BUF_SIZE - (w & MASK));
//   size_t second = n - first;
//   memcpy(&buf_[(w) & MASK], src,         first);
//   memcpy(&buf_[0],          src + first, second);  // wrap
//
// This test verifies correctness of a large write (4096 bytes) that wraps
// the ring buffer boundary. It should PASS both before and after the fix —
// the fix is pure performance, not a correctness change.
// ===========================================================================

TEST(SprintBug5_Minor, LargeWriteWrappingBoundaryPreservesData) {
    RingBuffer rb;

    // Fill ring buffer almost to the end, then read all to advance write_idx
    // to a position where the next write will wrap around the ring boundary.
    // BUF_SIZE = 16 MB. We need write_idx near BUF_SIZE.

    // Strategy: fill 16MB - 100 bytes, read all (advances read_idx),
    // then write 200 bytes. The write should wrap: 100 bytes before the end
    // and 100 bytes from the start.
    const size_t BUF_SIZE = 16777216;
    const size_t pre_fill = BUF_SIZE - 100;

    std::vector<uint8_t> filler(pre_fill, 0xAA);
    size_t w1 = rb.write(filler.data(), pre_fill);
    ASSERT_EQ(w1, pre_fill);

    auto junk = rb.read_all();  // drain: read_idx advances to pre_fill
    EXPECT_EQ(rb.bytes_available(), 0u);

    // Now write 200 bytes that CROSS the ring boundary.
    std::vector<uint8_t> payload(200);
    for (int i = 0; i < 200; ++i) payload[i] = static_cast<uint8_t>(i & 0xFF);

    size_t w2 = rb.write(payload.data(), 200);
    ASSERT_EQ(w2, 200u) << "Write wrapping ring boundary should accept all 200 bytes";

    // Read back and verify all 200 bytes are intact.
    // bytes are 0x00..0xC7 (200 bytes = 100 complete int16_t samples)
    auto result = rb.read_all();
    ASSERT_EQ(result.size(), 100u) << "Expected 100 int16_t samples from 200 bytes";

    // Verify sample values: little-endian pairs (0,1), (2,3), (4,5) ...
    for (size_t i = 0; i < 100; ++i) {
        uint8_t lo = static_cast<uint8_t>(i * 2     & 0xFF);
        uint8_t hi = static_cast<uint8_t>((i * 2 + 1) & 0xFF);
        int16_t expected = static_cast<int16_t>(lo | (hi << 8));
        EXPECT_EQ(result[i], expected)
            << "Sample " << i << " mismatch at ring boundary wrap";
    }
}

// ===========================================================================
// MINOR — Bug 6 and MINOR — Bug 7
//
// Bug 6 (read_idx odd avail) is proven by the already-failing tests in
// test_bug_regression.cpp:
//   BugRegression.ReadAllOddByteCountOverflows
//   BugRegression.FiveByteWriteCausesReadAllOverflow
//
// Bug 7 (model load not interrupted by SIGINT / async blocks on timeout) is
// proven by the already-failing test in test_tdd_bug_findings.cpp:
//   TDD_Bug5_High.AsyncTimeoutBlocksForeverOnHangingLoad
//
// No additional tests needed — those are the RED tests to fix.
// ===========================================================================
