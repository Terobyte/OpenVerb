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
#include "context/context.h"
#include "ipc/progress.h"

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <string_view>
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

    // Overload that accepts a typed Context struct instead of a raw JSON string.
    // Existing callsites using the string overload compile unchanged.
    InferenceResult process_stream(
        const std::vector<int16_t>& pcm,
        int                         sample_rate,
        const Context&              ctx,
        const std::atomic<bool>&    abort_flag,
        ProgressQueue&              progress_queue);

    // ---------------------------------------------------------------------------
    // polish_text — LLM cleanup pass.
    //
    // Runs a short text-only inference (no audio) using the polish system prompt
    // to remove filler words, normalise mid-sentence restarts, and add terminal
    // punctuation.  Uses the same llama.cpp inference path as process_stream but
    // with a text-only prompt (no audio tokens).
    //
    //   raw        — raw transcript to polish.
    //   ctx        — surrounding-text context (before/after cursor) for tone match.
    //   token_cb   — when non-null, invoked once per UTF-8-safe piece as the
    //                model generates tokens. The IPC layer uses this to stream
    //                polish_delta events to the client. The returned final
    //                string is still cleaned via strip_thinking_block + control
    //                token stripping.
    //   abort_flag — when non-null, exits the decode loop early if set.
    //
    // Returns the polished transcript, or raw (unchanged) on error.
    // ---------------------------------------------------------------------------
    std::string polish_text(const std::string& raw, const Context& ctx,
                            std::function<void(std::string_view)> token_cb   = nullptr,
                            const std::atomic<bool>*              abort_flag = nullptr);

private:
    Config                   cfg_;
    std::shared_ptr<Backend> backend_;
    std::atomic<bool>        loaded_{false};
    mutable std::mutex        engine_mutex_;
    // Bug C1 fix: reader/writer lock held for the full duration of inference so
    // unload_model() cannot free model weights while process_stream() is active.
    mutable std::shared_mutex inference_mutex_;
};

}  // namespace openverb
