// ---------------------------------------------------------------------------
// engine.cpp — OpenVerb Engine: audio-to-inference orchestrator.
//
// See engine.h for the full class contract and pipeline description.
// ---------------------------------------------------------------------------

#include "engine.h"

#include "audio/reader.h"
#include "audio/resampler.h"
#include "config/defaults.h"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <functional>
#include <shared_mutex>
#include <string>
#include <vector>

namespace openverb {

// ===========================================================================
// Internal helpers (anonymous namespace)
// ===========================================================================

namespace {

// ---------------------------------------------------------------------------
// extension_lower — extract and lowercase the file extension (including the
// leading dot), e.g. "audio.WAV" → ".wav".
// Returns empty string if there is no extension.
// ---------------------------------------------------------------------------
std::string extension_lower(const std::string& path) {
    auto pos = path.rfind('.');
    if (pos == std::string::npos) return "";
    std::string ext = path.substr(pos);
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return ext;
}

// ---------------------------------------------------------------------------
// rms_energy — root-mean-square amplitude of int16_t samples.
//
// Returns 0.0 for an empty vector.  Values are on the int16_t scale (0–32767).
// ---------------------------------------------------------------------------
static double rms_energy(const std::vector<int16_t>& samples) {
    if (samples.empty()) return 0.0;
    double sum_sq = 0.0;
    for (int16_t s : samples)
        sum_sq += static_cast<double>(s) * static_cast<double>(s);
    return std::sqrt(sum_sq / static_cast<double>(samples.size()));
}

}  // anonymous namespace

// ===========================================================================
// Engine — constructor
// ===========================================================================

// Constructor defers model loading — call ensure_loaded() before the first
// inference (or process_file() will do it automatically).
Engine::Engine(Config cfg) : cfg_(std::move(cfg)) {
    backend_ = nullptr;
    loaded_  = false;
}

Engine::Engine(Config cfg, std::shared_ptr<Backend> backend)
    : cfg_(std::move(cfg)), backend_(std::move(backend)), loaded_(true) {}

// ===========================================================================
// Engine::process_file
// ===========================================================================

InferenceResult Engine::process_file(const std::string&         file_path,
                                     const std::string&         context_json,
                                     std::function<void(float)> progress)
{
    const std::string ext = extension_lower(file_path);

    AudioData audio;

    if (ext == ".wav") {
        audio = read_wav(file_path);

    } else if (ext == ".pcm" || ext == ".raw") {
        audio = read_pcm(file_path);

    } else {
        throw std::runtime_error("unsupported audio extension: " + file_path);
    }

    // ── Silence gate: skip inference on near-silent audio.
    //
    // SILENCE_RMS_THRESHOLD (defined in config/defaults.h) is calibrated
    // against validation/audio/silence.wav and quiet speech samples.
    // Initial value: 50.0 (int16 scale, ≈ 0.15% of full scale).
    // Unvalidated — tune during integration testing.
    if (rms_energy(audio.samples) < SILENCE_RMS_THRESHOLD) {
        return InferenceResult{};
    }

    // ── Resample to 16 kHz mono (no-op if already at target).
    AudioData pcm16k = resample(audio, SAMPLE_RATE);

    // ── Run inference — hold a shared (reader) lock on inference_mutex_ for
    // the entire process() call so unload_model() (which acquires an exclusive
    // write lock) cannot free model weights while inference is in progress.
    // Bug C1 fix: lk_inference stays alive until process() returns.
    std::shared_ptr<Backend> be;
    {
        std::lock_guard<std::mutex> lk(engine_mutex_);
        if (!loaded_.load(std::memory_order_acquire) || !backend_) {
            backend_ = create_backend(cfg_.backend,
                                      cfg_.model_path,
                                      cfg_.mmproj_path,
                                      cfg_.threads,
                                      cfg_.ctx_size,
                                      cfg_.vad_enabled);
            loaded_.store(true, std::memory_order_release);
        }
        be = backend_;
    }
    std::shared_lock<std::shared_mutex> lk_inference(inference_mutex_);
    return be->process(pcm16k.samples,
                       pcm16k.sample_rate,
                       context_json,
                       progress);
}

void Engine::ensure_loaded() {
    std::lock_guard<std::mutex> lk(engine_mutex_);
    if (loaded_.load(std::memory_order_acquire) && backend_) return;
    backend_ = create_backend(cfg_.backend,
                              cfg_.model_path,
                              cfg_.mmproj_path,
                              cfg_.threads,
                              cfg_.ctx_size,
                              cfg_.vad_enabled);
    loaded_.store(true, std::memory_order_release);
}

void Engine::unload_model() {
    std::unique_lock<std::shared_mutex> lk_inference(inference_mutex_);
    std::lock_guard<std::mutex> lk(engine_mutex_);
    if (backend_) {
        backend_->unload_model();
        backend_.reset();
    }
    loaded_.store(false, std::memory_order_release);
}

InferenceResult Engine::process_stream(
    const std::vector<int16_t>& pcm,
    int                         sample_rate,
    const std::string&          context_json,
    const std::atomic<bool>&    abort_flag,
    ProgressQueue&              progress_queue)
{
    std::shared_ptr<Backend> be;
    {
        std::lock_guard<std::mutex> lk(engine_mutex_);
        if (!loaded_.load(std::memory_order_acquire) || !backend_) {
            backend_ = create_backend(cfg_.backend,
                                      cfg_.model_path,
                                      cfg_.mmproj_path,
                                      cfg_.threads,
                                      cfg_.ctx_size,
                                      cfg_.vad_enabled);
            loaded_.store(true, std::memory_order_release);
        }
        be = backend_;
    }
    // Bug C1 fix: hold shared lock across the entire inference call.
    std::shared_lock<std::shared_mutex> lk_inference(inference_mutex_);
    return be->process_stream(pcm, sample_rate, context_json,
                              abort_flag, progress_queue);
}

InferenceResult Engine::process_stream(
    const std::vector<int16_t>& pcm,
    int                         sample_rate,
    const Context&              ctx,
    const std::atomic<bool>&    abort_flag,
    ProgressQueue&              progress_queue)
{
    // Build a minimal JSON string from the typed Context so the backend
    // receives the same wire format it expects.  Only fields that the prompt
    // builder cares about are included to keep the serialised form compact.
    nlohmann::json j;
    if (!ctx.app_identifier.empty())    j["app"]                = ctx.app_identifier;
    if (!ctx.text_before_cursor.empty()) j["surrounding_before"] = ctx.text_before_cursor;
    if (!ctx.text_after_cursor.empty())  j["surrounding_after"]  = ctx.text_after_cursor;

    return process_stream(pcm, sample_rate, j.dump(), abort_flag, progress_queue);
}

std::string Engine::polish_text(const std::string& raw, const Context& ctx) {
    if (raw.empty()) return raw;

    // Build the polish prompt: system instruction + optional surrounding-text
    // snippets (before / after cursor) + raw transcript.
    //
    // The before/after excerpts give the model visibility into the surrounding
    // document so capitalization, punctuation, and tone match. Each side is
    // capped at EXCERPT_BYTES to keep the prompt within POLISH_CONTEXT_TOKENS.
    std::string prompt = POLISH_SYSTEM_PROMPT "\n";
    const std::size_t EXCERPT_BYTES = 200;
    if (!ctx.text_before_cursor.empty()) {
        std::string before = ctx.text_before_cursor.size() > EXCERPT_BYTES
            ? ctx.text_before_cursor.substr(ctx.text_before_cursor.size() - EXCERPT_BYTES)
            : ctx.text_before_cursor;
        prompt += "Text before cursor: \"" + before + "\"\n";
    }
    if (!ctx.text_after_cursor.empty()) {
        std::string after = ctx.text_after_cursor.size() > EXCERPT_BYTES
            ? ctx.text_after_cursor.substr(0, EXCERPT_BYTES)
            : ctx.text_after_cursor;
        prompt += "Text after cursor: \"" + after + "\"\n";
    }
    prompt += POLISH_INSTRUCTION_PREFIX;
    prompt += raw;

    // Run a text-only inference pass via the backend.
    std::shared_ptr<Backend> be;
    {
        std::lock_guard<std::mutex> lk(engine_mutex_);
        if (!loaded_.load(std::memory_order_acquire) || !backend_) {
            // Engine not loaded yet — return raw text unchanged to avoid
            // blocking the caller on a model load.
            return raw;
        }
        be = backend_;
    }

    try {
        InferenceResult result = be->process_text(prompt, nullptr);
        if (!result.text.empty()) return result.text;
    } catch (const std::exception&) {
        // Polish failure is non-fatal — return raw transcript.
    }
    return raw;
}

}  // namespace openverb
