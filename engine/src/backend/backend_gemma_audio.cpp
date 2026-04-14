// OpenVerb Engine — Gemma 4 audio-native backend

#include "backend_gemma_audio.h"
#include "commands/parser.h"
#include "context/prompt_builder.h"
#include "audio/reader.h"

#include <chrono>
#include <cstring>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

GemmaAudioBackend::GemmaAudioBackend(const std::string& model_path,
                                     const std::string& mmproj_path,
                                     int                threads,
                                     int                ctx_size,
                                     bool               vad_enabled)
    : llama_(std::make_unique<LlamaContext>(
          model_path, mmproj_path, threads, ctx_size))
    , vad_(/* mode=*/ 3, /* sample_rate=*/ 16000)
    , vad_enabled_(vad_enabled)
{}

// ---------------------------------------------------------------------------
// process
// ---------------------------------------------------------------------------

InferenceResult GemmaAudioBackend::process(
    const std::vector<int16_t>&  audio_pcm,
    int                          sample_rate,
    const std::string&           context_json,
    std::function<void(float)>   progress)
{
    const auto t_start = std::chrono::steady_clock::now();

    // -----------------------------------------------------------------------
    // Optional VAD filter — skip silent / sub-threshold clips.
    //
    // Gemma 4 is audio-native and can handle silence, but for live/daemon
    // mode (--vad) we avoid sending empty recordings to the model.
    // VAD is OFF by default for --file mode to preserve audio quality.
    // -----------------------------------------------------------------------
    if (vad_enabled_) {
        // Build a temporary AudioData shell so Vad::filter() can inspect it
        AudioData tmp;
        tmp.samples         = audio_pcm;
        tmp.sample_rate     = sample_rate;
        tmp.channels        = 1;
        tmp.bits_per_sample = 16;

        const std::vector<int16_t> speech = vad_.filter(tmp, sample_rate);
        if (speech.empty()) {
            // Less than ~200 ms of detected speech — return empty result
            return InferenceResult{};
        }
        // Note: we pass the *original* audio_pcm to infer(), not the trimmed
        // speech, because Gemma 4 processes the full audio natively.
        // VAD here is used only as a gating filter, not for trimming.
    }

    // -----------------------------------------------------------------------
    // Parse context JSON and build the two-part prompt.
    // -----------------------------------------------------------------------
    PromptContext   ctx        = parse_context_json(context_json);
    auto [system_xml, suffix]  = build_prompt(ctx);

    // -----------------------------------------------------------------------
    // Run inference via LlamaContext.
    // -----------------------------------------------------------------------
    const std::string raw_output = llama_->infer(
        system_xml,
        audio_pcm,
        sample_rate,
        suffix,
        progress
    );

    // -----------------------------------------------------------------------
    // Parse command from output.
    //
    // Gemma outputs structural commands as plain text (e.g. "delete that",
    // "undo") when instructed to do so by the system prompt.
    // parse_command() normalises and does a whole-string keyword lookup;
    // returns {text=raw_output, command=""} for plain transcription, or
    // {text="", command="delete_last"} etc. for recognised commands.
    // -----------------------------------------------------------------------
    const ParsedOutput parsed = parse_command(raw_output);

    // -----------------------------------------------------------------------
    // Compute wall-clock inference time.
    // -----------------------------------------------------------------------
    const auto t_end   = std::chrono::steady_clock::now();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        t_end - t_start);

    return InferenceResult{parsed.text, parsed.command, elapsed.count()};
}
