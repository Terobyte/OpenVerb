#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

class ProgressQueue;

// ---------------------------------------------------------------------------
// InferenceResult — output of one Backend::process() call.
//
//   text              — transcribed / generated text from the model.
//   command           — structured command extracted from model output,
//                       if the prompt requested command formatting;
//                       empty string otherwise (MVP1: always empty).
//   inference_time_ms — wall-clock time from process() entry to return,
//                       in milliseconds.
// ---------------------------------------------------------------------------
struct InferenceResult {
    std::string text;
    std::string command;
    int64_t     inference_time_ms = 0;
};

// ---------------------------------------------------------------------------
// Backend — abstract inference back-end interface.
//
// Implementations own their model state and may be called on any thread,
// but are NOT thread-safe (one Backend per thread).
// ---------------------------------------------------------------------------
class Backend {
public:
    virtual ~Backend() = default;

    // -----------------------------------------------------------------------
    // process — run inference on a single audio clip.
    //
    //   audio_pcm    — mono signed-16-bit PCM at `sample_rate` Hz; already
    //                  resampled to 16 kHz by the Engine layer before this
    //                  call (no resampling here).
    //   sample_rate  — sample rate of audio_pcm (Hz); should be 16000.
    //   context_json — caller-supplied desktop context JSON (from --context);
    //                  empty string if not provided.
    //   progress     — optional progress callback forwarded to the model's
    //                  generation loop; nullptr = no-op.
    //
    // Returns an InferenceResult (never throws on empty audio; throws
    // std::runtime_error on unrecoverable inference failure).
    // -----------------------------------------------------------------------
    virtual InferenceResult process(
        const std::vector<int16_t>&  audio_pcm,
        int                          sample_rate,
        const std::string&           context_json,
        std::function<void(float)>   progress) = 0;

    virtual void unload_model() = 0;

    virtual InferenceResult process_stream(
        const std::vector<int16_t>&  audio_pcm,
        int                          sample_rate,
        const std::string&           context_json,
        const std::atomic<bool>&     abort_flag,
        ProgressQueue&               progress_queue) = 0;

    // -----------------------------------------------------------------------
    // process_text — run text-only inference (no audio input).
    //
    //   prompt   — full text prompt; passed directly to the model without
    //              audio tokenisation.
    //   progress — optional progress callback; nullptr = no-op.
    //
    // Used by Engine::polish_text() which is a text-only operation.
    // Default implementation returns an empty result (safe no-op for mocks
    // and backends that do not support text-only inference).
    // -----------------------------------------------------------------------
    virtual InferenceResult process_text(
        const std::string&         prompt,
        std::function<void(float)> progress) { (void)prompt; (void)progress; return InferenceResult{}; }

    // -----------------------------------------------------------------------
    // name — short identifier for this backend (e.g. "gemma_audio").
    // -----------------------------------------------------------------------
    virtual std::string name() const = 0;
};

// ---------------------------------------------------------------------------
// create_backend — factory that constructs a Backend by name.
//
//   backend_name — identifies the implementation; currently "gemma_audio".
//   model_path   — path to the primary model .gguf file.
//   mmproj_path  — path to the multimodal projector .gguf file.
//   threads      — CPU thread count for inference.
//   ctx_size     — KV-cache token capacity.
//   vad_enabled  — enable VAD silence filter before inference.
//
// Throws std::invalid_argument if backend_name is not recognised,
// listing the available backends in the message.
//
// Implementation in backend.cpp.
// ---------------------------------------------------------------------------
std::unique_ptr<Backend> create_backend(const std::string& backend_name,
                                         const std::string& model_path,
                                         const std::string& mmproj_path,
                                         int                threads,
                                         int                ctx_size,
                                         bool               vad_enabled = false);
