#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

// ---------------------------------------------------------------------------
// ProgressCallback — called periodically during inference so callers can
// display a spinner or progress bar.
//
//   progress — normalised completion estimate in [0.0, 1.0].
//              Exact resolution depends on generation speed; at minimum it
//              is called once at 0.0 (start) and once at 1.0 (finish).
// ---------------------------------------------------------------------------
using ProgressCallback = std::function<void(float)>;

// ---------------------------------------------------------------------------
// TokenCallback — invoked once per UTF-8-safe piece of generated text during
// infer_text().  Each call delivers a `string_view` containing a complete
// UTF-8 sequence (never a partial multi-byte tail).  Used by the IPC layer to
// stream polish_delta events to the client as the model generates tokens.
// ---------------------------------------------------------------------------
using TokenCallback = std::function<void(std::string_view piece)>;

// ---------------------------------------------------------------------------
// LlamaContext — PIMPL wrapper around the llama.cpp / mtmd C API.
//
// Lifecycle:
//   LlamaContext ctx(model_path, mmproj_path, threads, ctx_size);
//   std::string result = ctx.infer(system_xml, audio_pcm, 16000,
//                                  "Output ONLY the final text:", cb);
//
// Thread safety: NOT thread-safe.  Use one LlamaContext per thread.
//
// Throws std::runtime_error on:
//   - Model load failure
//   - OOM during context initialisation
//   - Inference failure
// ---------------------------------------------------------------------------
class LlamaContext {
public:
    // ------------------------------------------------------------------------
    // Constructor — loads model weights + multimodal projector and allocates
    // the KV cache.
    //
    //   model_path   — path to Gemma .gguf model file (required).
    //   mmproj_path  — path to multimodal projector .gguf (required).
    //   threads      — CPU thread count for generation.
    //   ctx_size     — KV-cache token capacity (4096 is ample for short audio
    //                  clips; llama.cpp's 131072 default wastes ~780 MB).
    //
    // Before loading, queries available Metal VRAM via sysctl and logs a
    // warning to stderr if estimated usage exceeds the limit.
    // ------------------------------------------------------------------------
    LlamaContext(const std::string& model_path,
                 const std::string& mmproj_path,
                 int                threads,
                 int                ctx_size);

    ~LlamaContext();

    // Non-copyable; the underlying C context owns heap state.
    LlamaContext(const LlamaContext&)            = delete;
    LlamaContext& operator=(const LlamaContext&) = delete;

    // ------------------------------------------------------------------------
    // infer — transcribe audio and return the model's text output.
    //
    //   text_prompt        — XML-wrapped system context built by prompt_builder.
    //   audio_pcm          — mono signed-16-bit PCM samples at `sample_rate`.
    //   sample_rate        — audio sample rate in Hz (typically 16000).
    //   generation_suffix  — text appended after the audio tokens to steer the
    //                        model (e.g. "Output ONLY the final text:").
    //   progress           — optional callback, invoked every ~500 ms with a
    //                        normalised [0, 1] progress estimate; nullptr = no-op.
    //
    // Returns the model's decoded text with any Gemma 4 thinking block stripped.
    // Throws std::runtime_error on inference failure.
    // Aborts early (returns partial result) if g_interrupted is set.
    // ------------------------------------------------------------------------
    std::string infer(const std::string&         text_prompt,
                      const std::vector<int16_t>& audio_pcm,
                      int                         sample_rate,
                      const std::string&          generation_suffix,
                      ProgressCallback            progress   = nullptr,
                      const std::atomic<bool>*    abort_flag = nullptr);

    // ------------------------------------------------------------------------
    // infer_text — run text-only inference without audio input.
    //
    //   text_prompt        — full text content for the user turn.
    //   generation_suffix  — optional suffix appended after the user turn.
    //   progress           — optional progress callback; nullptr = no-op.
    //   abort_flag         — when non-null, exits early if set to true.
    //   token_cb           — when non-null, invoked once per UTF-8-safe piece
    //                        of generated text as tokens are sampled.  Used to
    //                        stream polish_delta events to the IPC client.
    //                        The final returned string is still cleaned via
    //                        strip_thinking_block + strip_gemma_control_tokens.
    //
    // Builds a Gemma 4 chat prompt without the <__media__> audio placeholder
    // and evaluates it using the standard llama tokenisation path.
    // Throws std::runtime_error on failure.
    // ------------------------------------------------------------------------
    std::string infer_text(const std::string&       text_prompt,
                            const std::string&       generation_suffix,
                            ProgressCallback         progress   = nullptr,
                            const std::atomic<bool>* abort_flag = nullptr,
                            TokenCallback            token_cb   = nullptr);

    // ------------------------------------------------------------------------
    // has_audio_support — true if the loaded mmproj supports audio input.
    // ------------------------------------------------------------------------
    bool has_audio_support() const;

    // ------------------------------------------------------------------------
    // model_name — human-readable model description string from metadata.
    // ------------------------------------------------------------------------
    std::string model_name() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
