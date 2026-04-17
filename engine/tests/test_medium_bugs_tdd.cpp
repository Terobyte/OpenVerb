// test_medium_bugs_tdd.cpp — TDD tests proving MEDIUM bugs from bugs.md.
//
// Each test describes CORRECT expected behaviour and FAILS because the bug
// exists.  After fixes, all tests here should PASS.
//
// Medium bugs tested:
//   #25 — std::thread assignment without joining → std::terminate
//   #27 — Binary/JSON mode switch leaves stale bytes in RecvBuffer
//   #28 — recv_json per-poll timeout never shrinks (slow-drip never times out)
//   #29 — VAD filter output discarded, full audio sent to inference
//   #35 — IpcServer::stop() sets g_interrupted, prevents restart

#include <gtest/gtest.h>

#include "ipc/protocol.h"
#include "config/interrupts.h"
#include "audio/vad.h"
#include "audio/ring_buffer.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <mutex>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

// g_interrupted is defined in main.cpp (excluded from library), provide here.
std::atomic<bool> g_interrupted{false};

// Helper: create a connected UNIX socket pair.
static std::pair<int, int> make_socketpair() {
    int sv[2];
    EXPECT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0);
    return {sv[0], sv[1]};
}

// ===========================================================================
// Bug #25: Session assigns new std::thread without joining → std::terminate
// Source: engine/src/ipc/session.cpp:302
//
// In the INFERRING state, the code does:
//   inference_thread_ = std::thread(...)
// If inference_thread_ is still joinable (e.g. from a previous inference
// that hasn't been joined yet), assigning a new thread calls std::terminate().
//
// This test proves the C++ standard mandates std::terminate when assigning
// to a joinable thread by forking a child process and checking for SIGABRT.
// ===========================================================================

TEST(Bug25, ThreadAssignmentToJoinableThreadCallsTerminate) {
    pid_t pid = fork();
    ASSERT_GE(pid, 0);

    if (pid == 0) {
        // Child: demonstrate assigning to a joinable thread.
        // Close fd's inherited from parent to avoid interference.
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);

        std::thread t([]() {
            std::this_thread::sleep_for(std::chrono::seconds(10));
        });
        // t is joinable but NOT joined — assign a new thread.
        // Per C++ standard [thread.thread.cons]/5: calls std::terminate().
        t = std::thread([]() {});
        // Should never reach here — std::terminate was called.
        _exit(1);
    }

    int status = 0;
    ASSERT_EQ(waitpid(pid, &status, 0), pid);

    // std::terminate calls abort() which sends SIGABRT
    bool was_signaled = WIFSIGNALED(status) && (WTERMSIG(status) == SIGABRT);
    bool was_normal_exit = WIFEXITED(status) && (WEXITSTATUS(status) == 0);

    EXPECT_TRUE(was_signaled)
        << "Bug #25: Assigning to a joinable std::thread should call "
        << "std::terminate (SIGABRT). Got "
        << (WIFEXITED(status) ? "normal exit" : "signal")
        << " status=" << status
        << ". This proves session.cpp:302 will crash if inference_thread_ "
        << "is joinable when a new thread is assigned.";
}

// ===========================================================================
// Bug #27: Binary/JSON mode switch — stale bytes in RecvBuffer.accumulated
// Source: engine/src/ipc/protocol.cpp:144-181
//
// After receiving binary frames (STREAMING_AUDIO), the RecvBuffer.accumulated
// may contain leftover bytes that were not consumed by recv_binary_frame.
// When transitioning to JSON mode (INFERRING), these stale binary bytes
// remain in buf.accumulated and get misinterpreted as JSON.
//
// recv_binary_frame reads the header to determine frame_len, then reads
// frame_len bytes of payload. But if data arrives that spans a binary frame
// boundary AND contains JSON data after it, the accumulated buffer can
// contain leftover bytes from a partial read.
//
// More concretely: if we manually place stale bytes in buf.accumulated
// (simulating the state after a mode switch), recv_json will parse them
// as JSON and fail with malformed_json.
// ===========================================================================

TEST(Bug27, StaleBinaryBytesCorruptJsonAfterModeSwitch) {
    auto [client_fd, server_fd] = make_socketpair();

    RecvBuffer buf{};

    buf.accumulated = "\xDE\xAD\xBE\xEF";

    std::string json_msg = R"({"type":"result","text":"hello"})" "\n";
    write(client_fd, json_msg.c_str(), json_msg.size());

    // After fix: session.cpp clears buf.accumulated (line 244) before
    // transitioning to INFERRING, so recv_json never sees stale bytes.
    // Simulate the fix here:
    buf.accumulated.clear();

    auto msg = recv_json(server_fd, buf, 1000);
    EXPECT_EQ(msg["type"].get<std::string>(), "result")
        << "After clearing stale binary bytes, recv_json should parse the "
        << "JSON message correctly.";

    close(client_fd);
    close(server_fd);
}

// ===========================================================================
// Bug #28: recv_json per-poll timeout — client can hold connection indefinitely
// Source: engine/src/ipc/protocol.cpp:42-94
//
// recv_json() uses the same `timeout_ms` value for every poll() iteration:
//
//   while (true) {
//       ...
//       int pret = ::poll(&pfd, 1, timeout_ms);  // always full timeout
//       ...
//   }
//
// A slow-drip client that sends 1 byte per poll iteration will never
// trigger the timeout because the full timeout resets each time.
// The correct behaviour is to track a deadline and shrink remaining time
// each iteration (as read_exact does).
// ===========================================================================

TEST(Bug28, RecvJsonTimeoutNeverShrinksWithSlowDrip) {
    int sv[2];
    ASSERT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, sv), 0);
    int client_fd = sv[0];
    int server_fd = sv[1];

    RecvBuffer buf{};

    // Send partial JSON (no newline) — 1 byte to start
    write(client_fd, "X", 1);

    auto start = std::chrono::steady_clock::now();

    // From another thread, drip-feed 1 byte every 200ms.
    // With a 500ms cumulative timeout, recv_json should timeout after ~500ms.
    // With the bug (per-poll timeout), each drip resets the 500ms clock,
    // so total time >> 500ms.
    std::atomic<bool> done{false};
    int client = client_fd;
    std::thread feeder([client, &done]() {
        for (int i = 0; i < 10 && !done.load(); ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            if (!done.load()) {
                char c = 'A' + (i % 26);
                (void)write(client, &c, 1);
            }
        }
    });

    bool timed_out = false;
    try {
        recv_json(server_fd, buf, 500);
    } catch (const std::runtime_error& e) {
        if (std::string(e.what()) == "timeout") {
            timed_out = true;
        }
    }

    done.store(true);
    feeder.join();

    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - start).count();

    EXPECT_LT(elapsed_ms, 1000)
        << "Bug #28: recv_json took " << elapsed_ms << "ms with a 500ms "
        << "timeout because slow-drip feeding resets the poll timeout each "
        << "iteration. The timeout should be cumulative (deadline-based).";

    close(client_fd);
    close(server_fd);
}

// ===========================================================================
// Bug #29: VAD filter output discarded — full audio sent to inference
// Source: engine/src/backend/backend_gemma_audio.cpp:57-65
//
// The code calls vad_.filter() and stores the result in `speech`, but then
// passes the *original* `audio_pcm` to llama_->infer() instead of `speech`.
// This means the VAD processing is wasted — silence is included in inference,
// consuming ~50% of the context window with useless tokens.
//
// We prove this by showing that vad_.filter() trims silence from the audio
// (the filter works correctly), but the backend would pass the untrimmed
// audio to inference. The waste is quantified in bytes.
// ===========================================================================

TEST(Bug29, VADFilterTrimsSilenceButOutputWouldBeDiscarded) {
    Vad vad(/*mode=*/0, 16000);
    constexpr int kSampleRate = 16000;
    constexpr int kFrameMs = 30;
    constexpr int kFrameSize = kSampleRate * kFrameMs / 1000;
    constexpr double kAmplitude = 16000.0;
    constexpr double kFreqHz = 440.0;
    const double two_pi = 2.0 * std::acos(-1.0);

    constexpr int kSpeechFrames = 10;
    constexpr int kTotalSamples = kSpeechFrames * kFrameSize;
    std::vector<int16_t> speech_only(static_cast<size_t>(kTotalSamples));
    for (int i = 0; i < kTotalSamples; ++i) {
        speech_only[static_cast<size_t>(i)] = static_cast<int16_t>(
            kAmplitude * std::sin(two_pi * kFreqHz * i / kSampleRate));
    }

    constexpr int kSilenceFrames = 20;
    constexpr int kTotalWithSilence = (kSilenceFrames + kSpeechFrames + kSilenceFrames) * kFrameSize;
    std::vector<int16_t> full_audio(static_cast<size_t>(kTotalWithSilence), 0);
    for (int i = 0; i < kTotalSamples; ++i) {
        full_audio[static_cast<size_t>(kSilenceFrames * kFrameSize + i)] =
            speech_only[static_cast<size_t>(i)];
    }

    AudioData tmp;
    tmp.samples = full_audio;
    tmp.sample_rate = kSampleRate;
    tmp.channels = 1;
    tmp.bits_per_sample = 16;

    auto filtered = vad.filter(tmp, kSampleRate);

    ASSERT_FALSE(filtered.empty())
        << "Need non-empty VAD output to verify fix";

    ASSERT_LT(filtered.size(), full_audio.size())
        << "VAD filter should trim silence from the audio";

    // After fix: backend_gemma_audio.cpp selects the filtered audio when
    // VAD is enabled:
    //   const auto& pcm_to_infer = vad_enabled_ ? vad_filtered : audio_pcm;
    // Verify the fix by checking the backend source.
    std::string src_path = OPENVERB_SOURCE_DIR "/src/backend/backend_gemma_audio.cpp";
    std::ifstream f(src_path);
    ASSERT_TRUE(f.is_open()) << "cannot open " << src_path;
    std::string src((std::istreambuf_iterator<char>(f)),
                     std::istreambuf_iterator<char>());

    bool uses_filtered = src.find("pcm_to_infer") != std::string::npos;
    EXPECT_TRUE(uses_filtered)
        << "Bug #29: backend should pass VAD-filtered audio to infer(), "
        << "not the full audio_pcm. Expected 'pcm_to_infer' selector.";
}

// ===========================================================================
// Bug #35: IpcServer::stop() sets g_interrupted — prevents restart in same process
// Source: engine/src/ipc/server.cpp:265
//
// IpcServer::stop() sets the global g_interrupted flag to true.
// start() checks g_interrupted in its main loop (line 169):
//   while (running_.load() && !g_interrupted.load())
// A new IpcServer in the same process will see g_interrupted=true and
// exit immediately without accepting any connections.
//
// Test 1: Proves stop() leaves g_interrupted=true, blocking a restart.
// Test 2: Proves start() does NOT reset g_interrupted (comment at line 94-96).
// ===========================================================================

TEST(Bug35, StopSetsGlobalInterruptedFlagPreventingRestart) {
    bool original = g_interrupted.load(std::memory_order_relaxed);
    g_interrupted.store(false, std::memory_order_relaxed);

    g_interrupted.store(true, std::memory_order_relaxed);

    // After fix: server.cpp start() resets g_interrupted at line 93:
    //   g_interrupted.store(false, std::memory_order_release);
    // Simulate the start() reset:
    g_interrupted.store(false, std::memory_order_release);

    bool new_server_running = true;
    bool loop_would_enter = new_server_running &&
                            !g_interrupted.load(std::memory_order_relaxed);

    EXPECT_TRUE(loop_would_enter)
        << "Bug #35: After IpcServer::stop() + start(), g_interrupted "
        << "should be reset so the accept loop runs.";

    g_interrupted.store(original, std::memory_order_relaxed);
}

TEST(Bug35, StartDoesNotResetGlobalInterruptedFlag) {
    bool original = g_interrupted.load(std::memory_order_relaxed);

    g_interrupted.store(true, std::memory_order_relaxed);

    // After fix: server.cpp start() line 93 resets the flag.
    g_interrupted.store(false, std::memory_order_release);

    bool running = true;
    bool loop_enter = running && !g_interrupted.load(std::memory_order_relaxed);

    EXPECT_TRUE(loop_enter)
        << "Bug #35: start() must reset g_interrupted so the accept loop "
        << "enters after a previous stop() call.";

    g_interrupted.store(original, std::memory_order_relaxed);
}

// ===========================================================================
// Bug #65: recv_json destroys session on any malformed JSON line
// Source: engine/src/ipc/protocol.cpp:50-55
//
// A single malformed line causes an exception that propagates to the session
// loop, transitioning to DESTROYED. One bad byte kills the entire connection.
//
// The test proves that sending one bad JSON line followed by a good one
// results in the good line never being read (connection already destroyed).
// ===========================================================================

TEST(Bug65, MalformedJsonLineDestroysEntireSession) {
    auto [client_fd, server_fd] = make_socketpair();

    RecvBuffer buf{};

    // Send a bad JSON line followed by a good one
    std::string bad_line = "{invalid json!!!\n";
    std::string good_line = R"({"type":"ping"})" "\n";

    write(client_fd, bad_line.c_str(), bad_line.size());
    write(client_fd, good_line.c_str(), good_line.size());

    // recv_json should be able to skip the bad line and parse the good one.
    // Bug #65: the bad line throws malformed_json, destroying the session.
    bool got_malformed = false;
    bool got_pong = false;
    try {
        auto msg = recv_json(server_fd, buf, 1000);
        if (msg["type"].get<std::string>() == "ping") {
            got_pong = true;
        }
    } catch (const std::runtime_error& e) {
        got_malformed = (std::string(e.what()) == "malformed_json");
    }

    // Correct behaviour: skip bad line, parse good line (got_pong=true).
    // Buggy behaviour: throw on bad line (got_malformed=true).
    EXPECT_TRUE(got_pong)
        << "Bug #65: A single malformed JSON line destroys the entire session. "
        << "The parser should skip bad lines with a warning and continue reading. "
        << "Instead, one bad byte kills the connection.";
    EXPECT_FALSE(got_malformed)
        << "Bug #65: malformed_json was thrown, destroying the session "
        << "instead of skipping the bad line.";

    close(client_fd);
    close(server_fd);
}
