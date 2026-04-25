#pragma once

#include "audio/chunk_queue.h"
#include "audio/ring_buffer.h"
#include "audio/vad_scanner.h"
#include "backend/backend.h"
#include "config/defaults.h"
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
    ~Session();  // safety net: signals stop and joins worker_thread_ if running

    Session(const Session&)            = delete;
    Session& operator=(const Session&) = delete;

    void run(int fd, Engine& engine, const SessionConfig& cfg);

    // Signals stop, shuts down chunk_queue_, and joins worker_thread_ if
    // still running.  Called from ~Session() as a safety net for the
    // uncaught-exception path; run() joins the worker inline on all normal
    // and expected-exception exits.
    void stop();

    // ---------------------------------------------------------------------------
    // Streaming pipeline members (phases 5-6)
    // ---------------------------------------------------------------------------
    std::optional<VadScanner> chunker_;          // VAD-based chunk emitter
    ChunkQueue                chunk_queue_;      // bounded chunk queue
    std::thread               worker_thread_;   // pops chunks and runs inference
    double                    infer_speed_ewma_ = DEFAULT_CHUNK_INFER_SPEED;
    std::atomic<bool>         pipeline_active_{false};

    // ---------------------------------------------------------------------------
    // Streaming result communication (worker_thread_ → sentinel handler)
    //
    // result_cv_       — notified by worker_thread_ when inference is done.
    // inference_result_ — populated by worker_thread_; read after join().
    // stop_requested_   — abort flag; set by stop() or on timeout/interrupt.
    // ---------------------------------------------------------------------------
    std::mutex                           infer_mutex_;
    std::condition_variable              result_cv_;
    std::optional<InferenceResult>       inference_result_;
    std::atomic<bool>                    stop_requested_{false};
    ProgressQueue progress_queue_;

    // Context JSON supplied by the session.start message (empty if omitted).
    std::string context_;

    // Set by run() before launching worker_thread_ so the lambda only needs
    // to capture `this` rather than holding a lvalue-reference to run()'s
    // Engine& parameter.
    Engine* engine_ptr_ = nullptr;

    enum class State {
        IDLE,
        WAITING_READY,
        STREAMING_AUDIO,
        SHUTDOWN,
        DESTROYED
    };

    // Worker thread that pops chunks from chunk_queue_, runs inference, and
    // emits partial_result + queue_status messages.  Declared here for Phase 6.
    void run_inference_worker_(int fd, Engine& engine);

    static const char* state_name(State s);
};

}
