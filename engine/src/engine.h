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

#include <functional>
#include <memory>
#include <string>

namespace openverb {

class Engine {
public:
    // -----------------------------------------------------------------------
    // Engine — construct and initialise the inference backend.
    //
    //   cfg — fully resolved Config (model_path, mmproj_path, threads,
    //         ctx_size, backend, vad_enabled must all be populated by
    //         resolve_config() before constructing Engine).
    //
    // Throws std::invalid_argument (via create_backend) if cfg.backend is
    // not recognised, or std::runtime_error if the model files fail to load.
    // -----------------------------------------------------------------------
    explicit Engine(Config cfg);

    // Non-copyable; move is default-generated.
    Engine(const Engine&)            = delete;
    Engine& operator=(const Engine&) = delete;
    Engine(Engine&&)                 = default;
    Engine& operator=(Engine&&)      = default;

    ~Engine() = default;

    // -----------------------------------------------------------------------
    // process_file — load an audio file, gate on silence, resample, infer.
    //
    //   file_path    — path to the audio file.
    //                  Extension is matched case-insensitively:
    //                    .wav / .WAV / .Wav (and any case mix) → read_wav()
    //                    .pcm / .raw                          → read_pcm()
    //                    anything else                        → error exit 1
    //
    //   context_json — caller-supplied desktop context JSON string (from
    //                  --context); pass empty string if not provided.
    //
    // Pipeline:
    //   1. Detect extension (case-insensitive).
    //   2. WAV: call peek_wav_duration_secs() — if > MAX_RECORDING_SECS,
    //           write "error: audio too long: Ns, max 300s" to stderr, exit 1.
    //          Then read_wav() to load sample data.
    //      PCM: read_pcm() to load all samples, then compute duration from
    //           sample count; if > MAX_RECORDING_SECS, error + exit 1.
    //   3. Compute RMS energy of the loaded samples.
    //      If below SILENCE_RMS_THRESHOLD, return empty InferenceResult{}
    //      without calling the backend (avoids wasting GPU on silence).
    //   4. resample() to 16 kHz mono (no-op when already at target).
    //   5. backend_->process() — returns InferenceResult.
    //
    // All error messages go to stderr prefixed with "error: ".
    // -----------------------------------------------------------------------
    InferenceResult process_file(const std::string&         file_path,
                                 const std::string&         context_json,
                                 std::function<void(float)> progress = nullptr);

private:
    Config                   cfg_;
    std::unique_ptr<Backend> backend_;
};

}  // namespace openverb
