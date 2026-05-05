// OpenVerb Engine — Gemma 4 audio-native backend

#include "backend_gemma_audio.h"
#include "commands/parser.h"
#include "context/prompt_builder.h"
#include "audio/reader.h"
#include "ipc/progress.h"
#include "config/log.h"

#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
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
// process_impl — core inference logic shared by process() and process_stream()
// ---------------------------------------------------------------------------

InferenceResult GemmaAudioBackend::process_impl(
    const std::vector<int16_t>&  audio_pcm,
    int                          sample_rate,
    const std::string&           context_json,
    std::function<void(float)>   progress,
    const std::atomic<bool>*     abort_flag)
{
    // Bug C2 fix: acquire backend_mutex_ before reading llama_ so that
    // unload_model()'s llama_.reset() cannot race the null-check + dereference.
    std::lock_guard<std::mutex> lk(backend_mutex_);
    // #26: guard against null llama_ (set by unload_model() between process()
    // calls under memory pressure).  A stale shared_ptr from an in-flight call
    // could reach here after the model is unloaded.
    if (!llama_) throw std::runtime_error("model not loaded");

    const auto t_start = std::chrono::steady_clock::now();

    // -----------------------------------------------------------------------
    // Optional VAD filter — trim silence before inference.
    //
    // #29: pass the VAD-filtered audio to infer() so the context window is not
    // wasted on ~50% silent padding.  VAD also acts as a gating filter: if no
    // speech is detected (<200 ms), inference is skipped entirely.
    // -----------------------------------------------------------------------
    std::vector<int16_t> vad_filtered;
    if (vad_enabled_) {
        // Build a temporary AudioData shell so Vad::filter() can inspect it
        AudioData tmp;
        tmp.samples         = audio_pcm;
        tmp.sample_rate     = sample_rate;
        tmp.channels        = 1;
        tmp.bits_per_sample = 16;

        vad_filtered = vad_.filter(tmp, sample_rate);
        if (vad_filtered.empty()) {
            // Less than ~200 ms of detected speech — return empty result
            return InferenceResult{};
        }
    }
    // Use trimmed speech when VAD is enabled, original audio otherwise.
    const std::vector<int16_t>& pcm_to_infer = vad_enabled_ ? vad_filtered : audio_pcm;

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
        pcm_to_infer,
        sample_rate,
        suffix,
        progress,
        abort_flag
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

// ---------------------------------------------------------------------------
// process — public API, delegates to process_impl (no abort flag)
// ---------------------------------------------------------------------------

InferenceResult GemmaAudioBackend::process(
    const std::vector<int16_t>&  audio_pcm,
    int                          sample_rate,
    const std::string&           context_json,
    std::function<void(float)>   progress)
{
    return process_impl(audio_pcm, sample_rate, context_json, progress, nullptr);
}

// ---------------------------------------------------------------------------
// unload_model — releases model weights to free memory
// ---------------------------------------------------------------------------

void GemmaAudioBackend::unload_model()
{
    // Bug C2 fix: acquire backend_mutex_ so llama_.reset() cannot race with
    // process_impl()'s null-check + dereference of llama_.
    std::lock_guard<std::mutex> lk(backend_mutex_);
    llama_.reset();
}

// ---------------------------------------------------------------------------
// process_text — text-only inference, no audio (used by polish_text pass)
// ---------------------------------------------------------------------------

InferenceResult GemmaAudioBackend::process_text(
    const std::string&                          prompt,
    std::function<void(float)>                  progress,
    std::function<void(std::string_view)>       token_cb,
    const std::atomic<bool>*                    abort_flag)
{
    // Match process_impl's lock discipline: hold backend_mutex_ for the full
    // inference duration. Trade-off: unload_model() blocks during polish (~5–7
    // s), but this matches the existing audio-inference contract — not a new
    // regression.  Closes the same race fixed by Bug C2 in process_impl.
    std::lock_guard<std::mutex> lk(backend_mutex_);
    if (!llama_) throw std::runtime_error("model not loaded");
    const auto t_start = std::chrono::steady_clock::now();
    const std::string raw_output = llama_->infer_text(
        prompt, "", progress, abort_flag, token_cb);
    const auto t_end = std::chrono::steady_clock::now();
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        t_end - t_start);
    return InferenceResult{raw_output, "", elapsed.count()};
}

// ---------------------------------------------------------------------------
// process_stream — like process() but with abort support and ProgressQueue
// ---------------------------------------------------------------------------

InferenceResult GemmaAudioBackend::process_stream(
    const std::vector<int16_t>&  audio_pcm,
    int                          sample_rate,
    const std::string&           context_json,
    const std::atomic<bool>&     abort_flag,
    ProgressQueue&               progress_queue)
{
    auto progress_cb = [&progress_queue](float frac) {
        progress_queue.push(frac);
    };
    return process_impl(audio_pcm, sample_rate, context_json,
                        progress_cb, &abort_flag);
}

// ---------------------------------------------------------------------------
// warmup — compile mtmd + llama graphs before the first real session.
//
// Why this exists: mtmd_init_from_file() is configured with warmup=false (see
// llama_context.cpp), so the multimodal projector's compute graphs are not
// compiled until the first mtmd_encode() call.  Without this step, the first
// transcription after engine launch hits a cold audio-encode path that can
// return empty output — the "first run is always empty" symptom.
//
// Bypasses process() / process_impl() on purpose so the backend-level VAD
// cannot short-circuit on silent input.
// ---------------------------------------------------------------------------
void GemmaAudioBackend::warmup()
{
    if (!llama_) return;  // model not loaded — nothing to warm.

    const auto t_start = std::chrono::steady_clock::now();

    // ~100 ms of silent PCM at 16 kHz — enough to force mtmd_encode through
    // its full compile path without producing real tokens to generate from.
    std::vector<int16_t> silence(1600, 0);

    // Safety cap: if the cold-start graph compile is slower than expected the
    // warmup must not block session.ready forever.  Watchdog thread flips the
    // abort flag after 5 s; infer() checks it before tokenise, before eval,
    // and on every generation iteration.
    std::atomic<bool> abort_flag{false};
    std::atomic<bool> warmup_done{false};
    std::thread watchdog([&abort_flag, &warmup_done]() {
        auto start = std::chrono::steady_clock::now();
        while (!warmup_done.load(std::memory_order_relaxed)) {
            if (std::chrono::steady_clock::now() - start
                    > std::chrono::seconds(5)) {
                abort_flag.store(true, std::memory_order_relaxed);
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    });

    try {
        (void)llama_->infer(
            /*text_prompt=*/       "",
            /*audio_pcm=*/         silence,
            /*sample_rate=*/       16000,
            /*generation_suffix=*/ "",
            /*progress=*/          nullptr,
            /*abort_flag=*/        &abort_flag
        );
    } catch (const std::exception& e) {
        LOG_WARN("gemma_audio: warmup exception (non-fatal): %s", e.what());
    } catch (...) {
        LOG_WARN("gemma_audio: warmup non-std exception (non-fatal)");
    }

    warmup_done.store(true, std::memory_order_relaxed);
    if (watchdog.joinable()) watchdog.join();

    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - t_start).count();
    LOG_INFO("gemma_audio: warmup complete (%lldms)",
             static_cast<long long>(elapsed));
}
