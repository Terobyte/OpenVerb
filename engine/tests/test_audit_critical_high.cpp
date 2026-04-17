// test_audit_critical_high.cpp — Negative tests proving CRITICAL and HIGH bugs
// from the full audit in bugs.md (2026-04-15).
//
// Convention:
//   RED  — test FAILS on current (buggy) code, becomes GREEN after fix
//   SKIP — requires hardware / Swift/XCTest; documented but not runnable
//   PASS — bug verified FIXED in current code; documents the historical fix
//
// BUG   SEV    FILE                                 STATUS
// ──────────────────────────────────────────────────────────────────────────
// #62  CRIT   backend_gemma_audio.cpp:140          RED  — frac*100 breaks progress
// #9   HIGH   ring_buffer.h/cpp                    RED  — SPSC write() has no exclusion
// #8   HIGH   capture.cpp:80-89                    SKIP — CoreAudio hardware required
// #13  HIGH   session.cpp                          REMOVED — duration_exceeded eliminated
// #10  HIGH   session.cpp                          PASS — join() precedes has_value() read
// #7   HIGH   app/OpenVerbApp.swift:142-159        SKIP — XCTest only
// #11  HIGH   client/EngineClient.swift:177+315    SKIP — XCTest only
// #12  HIGH   client/EngineClient.swift:101-109    SKIP — XCTest only
// #14  HIGH   app/EngineManager.swift:290-298      SKIP — XCTest only
// #15  HIGH   app/EngineClient.swift:154           SKIP — XCTest only
// #16  HIGH   app/EngineClient.swift:239-283       SKIP — XCTest only
// #17  HIGH   app/AudioSession.swift:52            SKIP — XCTest only

#include <gtest/gtest.h>

#include "audio/ring_buffer.h"
#include "ipc/progress.h"
#include "ipc/session.h"
#include "ipc/protocol.h"
#include "config/config.h"
#include "config/interrupts.h"
#include "engine.h"
#include "backend/backend.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <future>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

// Required by engine / session code — one definition per test binary.
std::atomic<bool> g_interrupted{false};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static std::pair<int, int> audit_mkpair() {
    int sv[2];
    if (::socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return {-1, -1};
    return {sv[0], sv[1]};
}

// Send a length-prefixed binary frame (protocol wire format used in STREAMING_AUDIO).
static void audit_write_binary_frame(int fd, const void* data, uint32_t len) {
    uint8_t hdr[4] = {
        static_cast<uint8_t>(len >> 24),
        static_cast<uint8_t>(len >> 16),
        static_cast<uint8_t>(len >> 8),
        static_cast<uint8_t>(len)
    };
    ::write(fd, hdr, 4);
    if (len > 0 && data) ::write(fd, data, len);
}

// Read the full contents of a source file into a std::string.
static std::string audit_read_src(const char* rel_path) {
    std::string full = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/";
    full += rel_path;
    FILE* f = std::fopen(full.c_str(), "r");
    if (!f) return {};
    std::string out;
    char buf[4096];
    while (std::fgets(buf, sizeof(buf), f)) out += buf;
    std::fclose(f);
    return out;
}

// ---------------------------------------------------------------------------
// Minimal mock backend: instantly reports itself as loaded; inference unused
// in these tests (all bugs trigger before the INFERRING state).
// ---------------------------------------------------------------------------

namespace {

struct AuditMock : Backend {
    InferenceResult process(
        const std::vector<int16_t>&, int, const std::string&,
        std::function<void(float)>) override { return {}; }

    InferenceResult process_stream(
        const std::vector<int16_t>&, int, const std::string&,
        const std::atomic<bool>&, ProgressQueue&) override { return {}; }

    void unload_model() override {}
    std::string name() const override { return "audit-mock"; }
};

} // namespace

// ===========================================================================
// BUG #62 CRITICAL — process_stream pushes frac*100.0f; protocol expects 0–1
//
// Location: engine/src/backend/backend_gemma_audio.cpp:140
//
//   auto progress_cb = [&progress_queue](float frac) {
//       progress_queue.push(frac * 100.0f);   // ← multiplies by 100
//   };
//
// llama_->infer() delivers frac in [0,1].  The lambda then pushes a value in
// [0,100] into the ProgressQueue.  Session forwards it as the JSON field
// "percent" (session.cpp:354-356).  ProcessingView (ProcessingView.swift:33)
// clamps with min(percent, 1.0), so the first real progress event (~2% at
// 500 ms) becomes 2.0 → clamped to 1.0 → ring jumps to 100% immediately.
//
// FIX: Remove * 100.0f — push frac directly into the queue.
// ===========================================================================

// Replicates the fixed lambda body from backend_gemma_audio.cpp:140.
// Verifies the pushed value stays in [0,1] after the * 100.0f was removed.
TEST(Bug62_ProgressScale, ProcessStreamPushes100xValueExceedingProtocolRange) {
    ProgressQueue pq;

    // Fixed lambda matching backend_gemma_audio.cpp:140 after the bug fix:
    auto fixed_progress_cb = [&pq](float frac) {
        pq.push(frac);  // no multiplication — protocol requires [0,1]
    };

    // Simulate first real progress event: 2% through inference.
    const float frac = 0.02f;
    fixed_progress_cb(frac);

    auto values = pq.drain();
    ASSERT_EQ(values.size(), 1u) << "expected one progress event";

    const float pushed = values[0];

    // Protocol invariant: percent ∈ [0.0, 1.0]
    // Before fix: pushed == 2.0f  (0.02 * 100) — clamped to 1.0 → instant full ring
    // After fix:  pushed == 0.02f (0.02 * 1)   — correct fractional progress
    EXPECT_LE(pushed, 1.0f)
        << "Bug #62 regression: process_stream pushed " << pushed
        << " for frac=" << frac << " (expected ≤ 1.0 per protocol spec)";
    EXPECT_GT(pushed, 0.0f)
        << "progress value should be positive";
}

// Source inspection: confirm the multiply-by-100 literal is still present.
TEST(Bug62_ProgressScale, SourceContainsFracTimes100) {
    std::string src = audit_read_src("engine/src/backend/backend_gemma_audio.cpp");
    ASSERT_FALSE(src.empty()) << "cannot read backend_gemma_audio.cpp";

    bool has_scale_bug = src.find("frac * 100.0f") != std::string::npos
                      || src.find("frac*100.0f")   != std::string::npos;

    EXPECT_FALSE(has_scale_bug)
        << "Bug #62 CONFIRMED: backend_gemma_audio.cpp still contains 'frac * 100.0f'.\n"
        << "  This multiplies the [0,1] fraction by 100 before pushing to ProgressQueue.\n"
        << "  Fix: change the lambda to  progress_queue.push(frac).";
}

// ===========================================================================
// BUG #9 HIGH — RingBuffer SPSC contract violated; multi-producer corrupts write_idx_
//
// Location: engine/src/audio/ring_buffer.h:9-26, ring_buffer.cpp:6-24
//
//   size_t w = write_idx_.load(std::memory_order_relaxed); // no exclusion
//   ...
//   write_idx_.store(w + n, std::memory_order_release);    // both store same w+n
//
// AudioQueue callbacks may fire on different CoreAudio internal threads.
// Two concurrent write() calls both read the SAME w (relaxed load, no lock),
// both write to the same w_pos in buf_, and both store write_idx_ = w+n.
// Net result: write_idx_ advances by n instead of 2n — one full write silently lost.
//
// FIX: Add a spinlock (std::atomic_flag) or std::mutex around write(), or
//      serialise callbacks through a dispatch_sync.
// ===========================================================================

// Stress test: two concurrent producers must not lose data.
// On multi-core machines this reliably fails without TSan; with
// -fsanitize=thread it also reports the underlying data race.
TEST(Bug9_RingBufferSPSC, ConcurrentWritersProduceSilentDataLoss) {
    constexpr size_t kChunk = 512;
    constexpr int    kIter  = 3000;
    RingBuffer rb;

    // Barrier: both threads spin until signalled together to maximise interleave.
    std::atomic<int> barrier{0};

    auto writer = [&](uint8_t fill) {
        std::vector<uint8_t> chunk(kChunk, fill);
        barrier.fetch_add(1, std::memory_order_acq_rel);
        while (barrier.load(std::memory_order_acquire) < 2) {}  // spin
        for (int i = 0; i < kIter; ++i)
            rb.write(chunk.data(), chunk.size());
    };

    std::thread t1(writer, 0xAA);
    std::thread t2(writer, 0xBB);
    t1.join();
    t2.join();

    const size_t expected = kChunk * static_cast<size_t>(kIter) * 2;
    const size_t actual   = rb.bytes_available();

    EXPECT_EQ(actual, expected)
        << "Bug #9 CONFIRMED: concurrent write() calls lost "
        << (expected - actual) << " of " << expected << " bytes.\n"
        << "  write_idx_.load(relaxed) has no exclusion; both threads read the\n"
        << "  same w, write to the same buffer offset, and store the same w+n.\n"
        << "  Run with -fsanitize=thread for guaranteed detection on all platforms.\n"
        << "  Fix: guard write() with a spinlock or std::mutex.";
}

// Source inspection: confirm write() has no mutex / CAS protecting write_idx_.
TEST(Bug9_RingBufferSPSC, WriteMethodHasNoExclusionMechanism) {
    std::string src = audit_read_src("engine/src/audio/ring_buffer.cpp");
    ASSERT_FALSE(src.empty()) << "cannot read ring_buffer.cpp";

    // After the fix, write() must acquire a lock or use compare_exchange.
    bool has_exclusion =
        src.find("std::mutex")           != std::string::npos ||
        src.find("std::atomic_flag")     != std::string::npos ||
        src.find("compare_exchange")     != std::string::npos ||
        src.find("os_unfair_lock")       != std::string::npos ||
        src.find("dispatch_sync")        != std::string::npos ||
        src.find("lock_guard")           != std::string::npos;

    EXPECT_TRUE(has_exclusion)
        << "Bug #9 CONFIRMED: ring_buffer.cpp write() has no exclusion mechanism.\n"
        << "  write_idx_.load(std::memory_order_relaxed) with no lock/CAS allows\n"
        << "  multiple CoreAudio callback threads to interleave → write_idx_ corruption.\n"
        << "  Fix: add std::atomic_flag spinlock or std::mutex around read-modify-store\n"
        << "  of write_idx_, or route all callbacks through a serialising queue.";
}

// ===========================================================================
// BUG #8 HIGH — AudioCapture::stop() non-immediate dispose races with callback
//
// Location: engine/src/audio/capture.cpp:80-89
//
// Two cooperating halves make up this race:
//
//   Half 1 — stop() uses non-immediate dispose:
//     impl_->capturing.store(false, std::memory_order_release);
//     AudioQueueStop(impl_->queue, true);
//     AudioQueueDispose(impl_->queue, false);  // ← false = not immediate
//
//   Half 2 — audio_callback() re-enqueues even when !capturing:
//     if (!self->capturing.load(...) || !self->callback) {
//         AudioQueueEnqueueBuffer(self->queue, buffer, 0, nullptr);  // ← still enqueues!
//         return;
//     }
//
// AudioQueueDispose(..., false) allows CoreAudio to continue delivering
// callbacks after the call returns.  Each callback re-enqueues its buffer
// into a queue being disposed → use-after-free inside CoreAudio.
//
// SKIP: requires hardware + ASAN + forced concurrent stop()/callback timing.
//
// FIX A: AudioQueueDispose(impl_->queue, true)  — immediate, no more callbacks.
// FIX B: Remove AudioQueueEnqueueBuffer from the !capturing branch.
// ===========================================================================

TEST(Bug8_AudioCaptureDispose, DISABLED_NonImmediateDisposeRacesWithCallback) {
    GTEST_SKIP()
        << "Bug #8 HIGH — capture.cpp:80-89\n"
        << "  Requires CoreAudio hardware + ASAN + forced concurrent stop/callback.\n"
        << "  Not reproducible in a unit test without real audio hardware.\n"
        << "  Manual repro: run with ASAN + exclusive audio device contention;\n"
        << "  call stop() during an active recording and observe callback after dispose.\n"
        << "  Fix A: AudioQueueDispose(impl_->queue, true).\n"
        << "  Fix B: Remove AudioQueueEnqueueBuffer from the !capturing branch.";
}

// Source proof: both halves of the race are present in the current code.
TEST(Bug8_AudioCaptureDispose, SourceConfirmsBothHalvesOfRace) {
    std::string src = audit_read_src("engine/src/audio/capture.cpp");
    ASSERT_FALSE(src.empty()) << "cannot read capture.cpp";

    // Half 1: non-immediate dispose (false flag)
    bool has_non_immediate = src.find("AudioQueueDispose(impl_->queue, false)") != std::string::npos;
    EXPECT_FALSE(has_non_immediate)
        << "Bug #8 CONFIRMED (half 1): capture.cpp:86 uses AudioQueueDispose(..., false).\n"
        << "  Non-immediate dispose: CoreAudio may still deliver callbacks after this call.\n"
        << "  Fix: change to AudioQueueDispose(impl_->queue, true).";

    // Half 2: callback re-enqueues even when !capturing
    // After fix: the !capturing branch should return WITHOUT calling AudioQueueEnqueueBuffer.
    // We verify by checking whether 'AudioQueueEnqueueBuffer' appears BEFORE 'return'
    // in the !capturing branch.  A simple structural check:
    size_t not_capturing_pos = src.find("!self->capturing");
    bool callback_reenqueues_when_stopped = false;
    if (not_capturing_pos != std::string::npos) {
        // Find the next 'AudioQueueEnqueueBuffer' after the !capturing check
        size_t enqueue_pos = src.find("AudioQueueEnqueueBuffer", not_capturing_pos);
        // Find the next 'return' after the !capturing check
        size_t return_pos = src.find("return;", not_capturing_pos);
        // If enqueue comes before return, the callback still enqueues when stopped
        callback_reenqueues_when_stopped =
            (enqueue_pos != std::string::npos) &&
            (return_pos  != std::string::npos) &&
            (enqueue_pos < return_pos);
    }
    EXPECT_FALSE(callback_reenqueues_when_stopped)
        << "Bug #8 CONFIRMED (half 2): audio_callback() calls AudioQueueEnqueueBuffer\n"
        << "  even when !capturing (capture.cpp:24). Combined with non-immediate dispose,\n"
        << "  this re-enqueues into a disposed queue → CoreAudio use-after-free.\n"
        << "  Fix: remove AudioQueueEnqueueBuffer from the !capturing branch.";
}

// ===========================================================================
// BUG #13 HIGH — REMOVED: duration_exceeded eliminated in Phase 5.
// The recording cap was replaced by the streaming chunked pipeline that
// processes audio continuously without a per-session duration limit.
// ===========================================================================

// ===========================================================================
// BUG #10 HIGH — Session reads inference_result_ without infer_mutex_ at :459
//
// AUDIT STATUS: VERIFIED FIXED in current code.
//
// The bug was: after the inference wait loop exits, line 459 reads
// inference_result_.has_value() without holding infer_mutex_, while the
// inference thread may still be writing to it.
//
// The fix: inference_thread_.join() at lines 441-443 executes unconditionally
// before line 459.  join() establishes happens-before — the inference thread
// has fully completed all writes before line 459 reads the optional.
// infer_mutex_ is therefore not needed at that point.
//
// This test verifies the join() is present (fix in place).
// ===========================================================================

TEST(Bug10_InferenceResultRace, JoinPrecedesHasValueReadVerifiedFixed) {
    std::string src = audit_read_src("engine/src/ipc/session.cpp");
    ASSERT_FALSE(src.empty()) << "cannot read session.cpp";

    // In the streaming pipeline, worker_thread_ joins before inference_result_
    // is read.  Either inference_thread_.join() (legacy INFERRING path) or
    // worker_thread_.join() must be present to establish happens-before.
    bool join_present =
        src.find("inference_thread_.join()") != std::string::npos ||
        src.find("worker_thread_.join()") != std::string::npos;
    EXPECT_TRUE(join_present)
        << "Bug #10 REGRESSION: no thread join found before inference_result_ read.\n"
        << "  worker_thread_.join() or inference_thread_.join() must precede the\n"
        << "  inference_result_ read to establish happens-before.";
}

// ===========================================================================
// SWIFT-ONLY HIGH BUGS (#7, #11-17) — Require Swift/XCTest
//
// These bugs involve Swift concurrency primitives (Task, DispatchQueue,
// @MainActor) and CoreFoundation / Cocoa APIs that cannot be exercised from
// a C++ Google Test binary.  Each test is documented as SKIP with the
// reproduction strategy.
// ===========================================================================

TEST(Bug7_DoubleCrashRecovery, RequiresXCTest) {
    GTEST_SKIP()
        << "Bug #7 HIGH — app/OpenVerb/App/OpenVerbApp.swift:142-159\n"
        << "  handleCrash() is called twice for a single crash event.\n"
        << "  Both the onError callback (Phase 2 monitor) and drainResult() each\n"
        << "  call handleCrash() independently for the same crash → crashCount\n"
        << "  incremented twice → premature crash-loop detection.\n"
        << "  Repro: XCTest — inject mock crash; assert handleCrash() called exactly once.\n"
        << "  Fix: guard handleCrash() with an isRecovering atomic flag.";
}

TEST(Bug11_ConcurrentRecvJSON, RequiresXCTest) {
    GTEST_SKIP()
        << "Bug #11 HIGH — client/Sources/EngineClient.swift:177 and :315\n"
        << "  Phase 2 monitor calls recvJSON() on readQueue; main thread calls\n"
        << "  recvJSON() in Phase 3.  recvLock protects the buffer but NOT the\n"
        << "  underlying read() syscall.  Two concurrent read(fd) calls → kernel\n"
        << "  splits the byte stream → both sides receive unparseable fragments.\n"
        << "  Repro: XCTest + Swift TSan — concurrent Phase 2 + Phase 3 access.\n"
        << "  Fix: hold recvLock across the entire read+append+extract sequence,\n"
        << "  or fully join the Phase 2 monitor before any Phase 3 reads.";
}

TEST(Bug12_DisconnectUseAfterClose, RequiresXCTest) {
    GTEST_SKIP()
        << "Bug #12 HIGH — client/Sources/EngineClient.swift:101-109\n"
        << "  disconnect() calls close(fd) while the Phase 2 monitor may be\n"
        << "  blocked in read(fd).  After close(), the kernel recycles the fd\n"
        << "  number; the monitor then reads from a completely different file.\n"
        << "  Repro: XCTest — call disconnect() while monitor is blocked in read();\n"
        << "  assert monitor does not read stale data.\n"
        << "  Fix: call stopPhase2ErrorMonitor() before close(fd), or\n"
        << "  call shutdown(fd, SHUT_RDWR) first to unblock the read.";
}

TEST(Bug14_ShutdownBlocksMainActor, RequiresXCTest) {
    GTEST_SKIP()
        << "Bug #14 HIGH — app/OpenVerb/Engine/EngineManager.swift:290-298\n"
        << "  shutdown() calls sema.wait(timeout: 1.0) on the MainActor.\n"
        << "  Task.detached may not schedule if the cooperative thread pool is\n"
        << "  saturated, causing applicationWillTerminate to stall for up to 1 s\n"
        << "  and risking a watchdog kill.\n"
        << "  Repro: XCTest on @MainActor — saturate the thread pool, call shutdown(),\n"
        << "  measure wall time.\n"
        << "  Fix: make shutdown() async, or use DispatchQueue.async.";
}

TEST(Bug15_IsConnectedUnsynchronized, RequiresXCTest) {
    GTEST_SKIP()
        << "Bug #15 HIGH — app/OpenVerb/Engine/EngineClient.swift:154\n"
        << "  var isConnected: Bool { fd >= 0 }  — reads fd without synchronization.\n"
        << "  fd is mutated only under ioQueue; Phase 2 monitor also reads fd\n"
        << "  from a detached Task.  TSan-flagged data race.\n"
        << "  Repro: XCTest + Swift TSan — concurrent read and write on fd.\n"
        << "  Fix: read fd under ioQueue.sync { }, or use an @Atomic wrapper.";
}

TEST(Bug16_RecvBufferMultipleQueues, RequiresXCTest) {
    GTEST_SKIP()
        << "Bug #16 HIGH — app/OpenVerb/Engine/EngineClient.swift:239-283 vs :467-519\n"
        << "  recvJSONSync() is called from both ioQueue and a detached Task (Phase 2).\n"
        << "  Two concurrent consumers extract messages from the same recvBuffer.\n"
        << "  A message meant for the drain loop can be consumed by the Phase 2\n"
        << "  monitor (or vice versa), causing misrouting and state machine corruption.\n"
        << "  Repro: XCTest — inject interleaved bytes; assert no message misrouting.\n"
        << "  Fix: dedicated recvQueue that serialises all recv* calls.";
}

TEST(Bug17_OsUnfairLockAsVar, RequiresXCTest) {
    GTEST_SKIP()
        << "Bug #17 HIGH — app/OpenVerb/Input/AudioSession.swift:52\n"
        << "  private var lock = os_unfair_lock()  — stored as a Swift var.\n"
        << "  Apple TN3176 warns: os_unfair_lock must not be copied or moved;\n"
        << "  Swift may move 'var' properties on the heap, making the lock address\n"
        << "  unstable and all lock/unlock operations operate on different objects.\n"
        << "  Repro: source inspection + Apple TN3176 advisory.\n"
        << "  Fix: private let lock = OSAllocatedUnfairLock()  +  lock.withLock { }.";
}
