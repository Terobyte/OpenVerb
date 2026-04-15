#pragma once

#include "audio/ring_buffer.h"
#include "backend/backend.h"
#include "ipc/progress.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace openverb {

class Engine;

struct SessionConfig {
    int idle_timeout_secs      = 15;
    int stall_timeout_secs     = 30;
    int inference_timeout_secs = 180;
    int ctx_size               = 4096;
    int load_timeout_secs      = 120;
};

class Session {
public:
    static void handle_connection(int fd, Engine& engine,
                                  const SessionConfig& cfg = SessionConfig{});

private:
    Session() = default;
    ~Session();  // safety net: joins inference_thread_ via stop()

    Session(const Session&)            = delete;
    Session& operator=(const Session&) = delete;

    void run(int fd, Engine& engine, const SessionConfig& cfg);

    // Signals stop_requested_ and joins inference_thread_ if running.
    // Safe to call at any point; idempotent after the thread has been joined.
    void stop();

    RingBuffer    ring_buffer_;
    ProgressQueue progress_queue_;

    // ---------------------------------------------------------------------------
    // Inference-thread lifetime members
    //
    // inference_thread_ is (re-)created for each INFERRING state entry.
    // result_cv_  — notified by the inference thread when the result is ready.
    // inference_result_ — populated by inference_thread_ under infer_mutex_.
    // stop_requested_   — abort flag; set by stop() or on timeout/interrupt.
    // ---------------------------------------------------------------------------
    std::thread                          inference_thread_;
    std::mutex                           infer_mutex_;
    std::condition_variable              result_cv_;
    std::optional<InferenceResult>       inference_result_;
    std::string                          inference_error_;   // set by catch in lambda
    std::atomic<bool>                    stop_requested_{false};

    // Context JSON supplied by the session.start message (empty if omitted).
    std::string context_;

    enum class State {
        IDLE,
        WAITING_READY,
        STREAMING_AUDIO,
        INFERRING,
        SHUTDOWN,
        DESTROYED
    };

    static const char* state_name(State s);
};

}
