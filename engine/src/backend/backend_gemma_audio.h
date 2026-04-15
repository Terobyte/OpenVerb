#pragma once

#include "backend.h"
#include "audio/vad.h"
#include "inference/llama_context.h"

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <vector>

class ProgressQueue;

// ---------------------------------------------------------------------------
// GemmaAudioBackend — Backend implementation for Gemma 4 E2B (audio-native).
//
// Owns:
//   llama_  — the LlamaContext wrapping the loaded model + mmproj.
//   vad_    — WebRTC VAD for optional silence filtering.
//
// Lifecycle:
//   GemmaAudioBackend be(model_path, mmproj_path, threads, ctx_size, false);
//   InferenceResult r = be.process(pcm, 16000, ctx_json, nullptr);
//
// Thread safety: NOT thread-safe.  Use one GemmaAudioBackend per thread.
// ---------------------------------------------------------------------------
class GemmaAudioBackend : public Backend {
public:
    // -----------------------------------------------------------------------
    // Constructor — loads the model (heavy; do once at startup).
    //
    //   model_path   — path to the Gemma 4 E2B .gguf model.
    //   mmproj_path  — path to the multimodal projector .gguf.
    //   threads      — CPU thread count for generation.
    //   ctx_size     — KV-cache token capacity (default: 4096).
    //   vad_enabled  — if true, run WebRTC VAD before inference and return an
    //                  empty result when < 200 ms of speech is detected.
    //                  Disabled by default for --file mode (file has defined
    //                  boundaries; VAD would discard too-quiet audio).
    //                  Enable with --vad for future live/daemon mode.
    // -----------------------------------------------------------------------
    GemmaAudioBackend(const std::string& model_path,
                      const std::string& mmproj_path,
                      int                threads,
                      int                ctx_size,
                      bool               vad_enabled = false);

    ~GemmaAudioBackend() override = default;

    // Non-copyable; owns a LlamaContext and Vad instance.
    GemmaAudioBackend(const GemmaAudioBackend&)            = delete;
    GemmaAudioBackend& operator=(const GemmaAudioBackend&) = delete;

    // -----------------------------------------------------------------------
    // process — transcribe one audio clip.
    //
    // Expects already-normalised 16 kHz / 16-bit / mono PCM from the Engine
    // layer; no resampling is performed here.
    //
    // If vad_enabled is set: runs VAD on the PCM; returns an empty
    // InferenceResult (text="", command="") if total detected speech is
    // fewer than 200 ms.
    //
    // Otherwise: parses context_json, builds the XML prompt, calls the
    // LlamaContext, and returns the result.
    // -----------------------------------------------------------------------
    InferenceResult process(
        const std::vector<int16_t>&  audio_pcm,
        int                          sample_rate,
        const std::string&           context_json,
        std::function<void(float)>   progress) override;

    void unload_model() override;

    InferenceResult process_stream(
        const std::vector<int16_t>&  audio_pcm,
        int                          sample_rate,
        const std::string&           context_json,
        const std::atomic<bool>&     abort_flag,
        ProgressQueue&               progress_queue) override;

    std::string name() const override { return "gemma_audio"; }

private:
    // Core inference logic shared by process() and process_stream().
    // abort_flag: when non-null, the generation loop exits early if set.
    InferenceResult process_impl(
        const std::vector<int16_t>&  audio_pcm,
        int                          sample_rate,
        const std::string&           context_json,
        std::function<void(float)>   progress,
        const std::atomic<bool>*     abort_flag);

    std::unique_ptr<LlamaContext> llama_;
    Vad                           vad_;
    bool                          vad_enabled_;
};
