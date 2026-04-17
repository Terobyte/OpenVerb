// test_open_bugs_negative.cpp — NEGATIVE tests proving open bugs from bugs.md.
//
// Every test asserts CORRECT expected behaviour and FAILS because the bug
// exists.  If a test turns GREEN the bug was fixed; if it was GREEN before
// the fix that is a FALSE NEGATIVE (test was wrong).
//
// Open bugs covered:
//   Bug 19 — Engine::unload_model() races with process_stream() (use-after-free)
//   Bug 20 — Vad::filter() iterates vector<size_t> with int loop variable
//
// Both tests use source-code verification AND runtime proof.

#include <gtest/gtest.h>

#include "engine.h"
#include "backend/backend.h"
#include "audio/vad.h"
#include "ipc/progress.h"
#include "config/config.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

std::atomic<bool> g_interrupted{false};

#ifndef OPENVERB_SOURCE_DIR
#define OPENVERB_SOURCE_DIR ".."
#endif

static std::string src_path(const char* relative) {
    return std::string(OPENVERB_SOURCE_DIR) + "/src/" + relative;
}

static std::string read_file(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open()) return "";
    return std::string((std::istreambuf_iterator<char>(f)),
                        std::istreambuf_iterator<char>());
}

// ===========================================================================
// BUG 19 (MEDIUM) — Engine::unload_model() can race with process_stream()
//                   use-after-free on Backend internal state
//
// Location: engine.cpp:158-164 (unload) vs :166-189 (process_stream)
//
// process_stream() copies backend_ to a local shared_ptr, releases
// engine_mutex_, then calls be->process_stream().  Meanwhile unload_model()
// acquires engine_mutex_ and calls backend_->unload_model().  Since both
// point to the SAME Backend object, unload_model() destroys internal state
// (llama_ ptr) while process_stream() is still using it.
//
// The shared_ptr keeps the Backend OBJECT alive, but unload_model() can
// destroy the Backend's INTERNAL state (e.g. resetting llama_ unique_ptr)
// while process_impl() dereferences it.
//
// TEST STRATEGY:
//   1. Mock Backend records concurrent access.
//   2. Thread A: process_stream() blocks for 300ms inside the mock.
//   3. Thread B: unload_model() while A is inside process_stream().
//   4. Assert: unload_model() was NOT called during process_stream().
//      This FAILS on current code — proving the race.
// ===========================================================================

namespace {

struct RaceDetectBackend : Backend {
    std::atomic<bool> inside_process_stream{false};
    std::atomic<bool> unload_during_process{false};
    std::atomic<int>  concurrent_count{0};

    InferenceResult process_stream(
        const std::vector<int16_t>&,
        int,
        const std::string&,
        const std::atomic<bool>& abort_flag,
        ProgressQueue&) override
    {
        inside_process_stream.store(true, std::memory_order_seq_cst);
        concurrent_count.fetch_add(1, std::memory_order_seq_cst);

        auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::milliseconds(500);
        while (std::chrono::steady_clock::now() < deadline) {
            if (abort_flag.load(std::memory_order_relaxed)) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }

        concurrent_count.fetch_sub(1, std::memory_order_seq_cst);
        inside_process_stream.store(false, std::memory_order_seq_cst);
        return InferenceResult{"transcript", "", 100};
    }

    void unload_model() override {
        if (inside_process_stream.load(std::memory_order_seq_cst)) {
            unload_during_process.store(true, std::memory_order_seq_cst);
        }
    }

    InferenceResult process(
        const std::vector<int16_t>&, int, const std::string&,
        std::function<void(float)>) override { return {}; }

    std::string name() const override { return "race-detect"; }
};

}  // namespace

TEST(Bug19_UnloadModelRacesProcessStream, ConcurrentCallDetected) {
    auto* backend = new RaceDetectBackend();
    openverb::Engine engine(Config{}, std::shared_ptr<Backend>(backend));

    std::atomic<bool> abort_flag{false};
    ProgressQueue pq;
    std::vector<int16_t> pcm(16000, 1000);

    std::thread stream_thread([&]() {
        engine.process_stream(pcm, 16000, "", abort_flag, pq);
    });

    for (int i = 0; i < 200; ++i) {
        if (backend->inside_process_stream.load(std::memory_order_seq_cst)) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    ASSERT_TRUE(backend->inside_process_stream.load(std::memory_order_seq_cst))
        << "process_stream() never entered — test setup failed";

    engine.unload_model();

    abort_flag.store(true, std::memory_order_release);
    stream_thread.join();

    EXPECT_FALSE(backend->unload_during_process.load(std::memory_order_seq_cst))
        << "Bug 19 CONFIRMED: unload_model() was called while process_stream() "
        << "was running on the same Backend object.  The shared_ptr keeps the "
        << "Backend alive but unload_model() destroys internal state (llama_) "
        << "that process_stream() is still using.\n"
        << "Fix: use std::shared_mutex — readers (process_stream, process_file) "
        << "take shared lock, writer (unload_model) takes exclusive lock.";
}

TEST(Bug19_Source, ProcessStreamReleasesMutexBeforeBackendCall) {
    auto content = read_file(src_path("engine.cpp"));
    ASSERT_FALSE(content.empty()) << "Cannot read engine.cpp";

    auto pos_stream = content.find("InferenceResult Engine::process_stream");
    ASSERT_NE(pos_stream, std::string::npos);

    auto body = content.substr(pos_stream);

    auto has_mutex_release = body.find("}") != std::string::npos;
    auto has_backend_call = body.find("be->process_stream(") != std::string::npos;
    ASSERT_TRUE(has_mutex_release && has_backend_call);

    auto unlock_scope_end = body.find("be = backend_;\n    }");
    ASSERT_NE(unlock_scope_end, std::string::npos)
        << "Cannot find the scope end where engine_mutex_ is released before be->process_stream()";

    auto after_unlock = body.substr(unlock_scope_end + 1);
    auto backend_call_pos = after_unlock.find("be->process_stream(");
    ASSERT_NE(backend_call_pos, std::string::npos)
        << "be->process_stream() not found after mutex release";

    auto unload_impl = content.find("void Engine::unload_model()");
    ASSERT_NE(unload_impl, std::string::npos);

    auto unload_body = content.substr(unload_impl);
    auto has_unload_backend_call = unload_body.find("backend_->unload_model()") != std::string::npos;
    ASSERT_TRUE(has_unload_backend_call)
        << "unload_model() does not call backend_->unload_model()";

    // Verify that the fix is in place: process_stream() must hold a shared_lock
    // over the backend call so that unload_model() (exclusive lock) cannot
    // destroy backend state while inference is running.
    EXPECT_NE(body.find("shared_lock"), std::string::npos)
        << "Bug 19 NOT FIXED: process_stream() must acquire a shared_lock on "
        << "backend_rw_mutex_ before calling be->process_stream() so that "
        << "unload_model() (unique_lock) is blocked until inference completes.";

    // Verify that unload_model() uses a unique_lock for exclusive access.
    EXPECT_NE(unload_body.find("unique_lock"), std::string::npos)
        << "Bug 19 NOT FIXED: unload_model() must use a unique_lock on "
        << "backend_rw_mutex_ so it waits for all active inference calls "
        << "to finish before destroying backend state.";
}

// ===========================================================================
// BUG 20 (LOW) — Vad::filter() iterates vector<size_t> with int loop variable
//
// Location: engine/src/audio/vad.cpp:155-157
//
//   std::vector<size_t> pending;
//   ...
//   for (int si : pending) {   // truncation: size_t → int
//       append_frame(si);
//   }
//
// The pending vector holds size_t frame indices, but the end-of-audio flush
// loop iterates with int, causing implicit truncation.  On 64-bit systems
// with frame counts > INT_MAX (extremely unlikely in practice but formally
// incorrect), this loses data.
//
// Note: The main loop at line 126 already uses `for (size_t si : pending)`.
// Only the end-of-audio flush at line 155 uses `int`.
//
// TEST STRATEGY:
//   Source-code verification that `for (int si : pending)` exists at the
//   end-of-audio flush path.
// ===========================================================================

TEST(Bug20_Source, EndOfAudioFlushUsesIntLoopVariable) {
    auto content = read_file(src_path("audio/vad.cpp"));
    ASSERT_FALSE(content.empty()) << "Cannot read vad.cpp";

    auto pending_decl = content.find("std::vector<size_t> pending");
    ASSERT_NE(pending_decl, std::string::npos)
        << "pending vector not declared as vector<size_t>";

    auto end_flush = content.find("if (in_speech && !pending.empty())");
    ASSERT_NE(end_flush, std::string::npos)
        << "End-of-audio flush block not found";

    auto flush_block = content.substr(end_flush, 200);

    auto int_loop = flush_block.find("for (int si : pending)");
    auto size_t_loop = flush_block.find("for (size_t si : pending)");

    EXPECT_EQ(int_loop, std::string::npos)
        << "Bug 20 CONFIRMED: vad.cpp end-of-audio flush uses "
        << "'for (int si : pending)' which truncates size_t → int.\n"
        << "The main loop already correctly uses 'for (size_t si : pending)' "
        << "but the trailing-silence flush at the end of the function was "
        << "missed during the Bug 15 fix.\n"
        << "Fix: change 'for (int si : pending)' to 'for (size_t si : pending)'.";

    EXPECT_NE(size_t_loop, std::string::npos)
        << "After fix, the end-of-audio flush should use 'for (size_t si : pending)'";
}
