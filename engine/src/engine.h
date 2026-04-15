#pragma once

// ---------------------------------------------------------------------------
// engine.h — OpenVerb Engine: top-level audio-to-inference orchestrator.
//
// Responsibility:
//   Engine owns one Backend and drives the complete audio processing pipeline:
//     file → load → silence gate → resample → inference → InferenceResult
//
// Usage:
//   Config cfg = parse_args(argc, argv);
//   resolve_config(cfg);
//   openverb::Engine engine(cfg);
//   InferenceResult  result = engine.process_file(cfg.file_path,
//                                                  cfg.context_json);
// ---------------------------------------------------------------------------

#include "backend/backend.h"
#include "config/config.h"
#include "ipc/progress.h"

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace openverb {

class Engine {
public:
    explicit Engine(Config cfg);
    Engine(Config cfg, std::shared_ptr<Backend> backend);

    Engine(const Engine&)            = delete;
    Engine& operator=(const Engine&) = delete;
    Engine(Engine&&)                 = delete;
    Engine& operator=(Engine&&)      = delete;

    ~Engine() = default;

    InferenceResult process_file(const std::string&         file_path,
                                 const std::string&         context_json,
                                 std::function<void(float)> progress = nullptr);

    void ensure_loaded();
    void unload_model();

    InferenceResult process_stream(
        const std::vector<int16_t>& pcm,
        int                         sample_rate,
        const std::string&          context_json,
        const std::atomic<bool>&    abort_flag,
        ProgressQueue&              progress_queue);

private:
    Config                   cfg_;
    std::shared_ptr<Backend> backend_;
    std::atomic<bool>        loaded_{false};
    std::mutex                engine_mutex_;
};

}  // namespace openverb
