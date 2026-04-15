// ---------------------------------------------------------------------------
// engine.cpp — OpenVerb Engine: audio-to-inference orchestrator.
//
// See engine.h for the full class contract and pipeline description.
// ---------------------------------------------------------------------------

#include "engine.h"

#include "audio/reader.h"
#include "audio/resampler.h"
#include "config/defaults.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <functional>
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

Engine::Engine(Config cfg, std::unique_ptr<Backend> backend)
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
        // ── WAV: peek header first to avoid allocating memory for oversized files.
        double dur = peek_wav_duration_secs(file_path);
        if (dur > MAX_RECORDING_SECS) {
            throw std::runtime_error("audio too long: " +
                std::to_string(static_cast<int>(dur)) + "s, max " +
                std::to_string(MAX_RECORDING_SECS) + "s");
        }
        audio = read_wav(file_path);

    } else if (ext == ".pcm" || ext == ".raw") {
        // ── PCM: no header available — load first, then check duration.
        audio = read_pcm(file_path);

        // read_pcm always sets sample_rate = 16000, channels = 1.
        double dur = static_cast<double>(audio.samples.size()) /
                     static_cast<double>(audio.sample_rate);
        if (dur > MAX_RECORDING_SECS) {
            throw std::runtime_error("audio too long: " +
                std::to_string(static_cast<int>(dur)) + "s, max " +
                std::to_string(MAX_RECORDING_SECS) + "s");
        }

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

    // ── Run inference — hold the mutex across load + process to prevent a
    // concurrent unload_model() from destroying backend_ between the two.
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
    return backend_->process(pcm16k.samples,
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
    std::lock_guard<std::mutex> lk(engine_mutex_);
    if (backend_) {
        backend_->unload_model();
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
    return backend_->process_stream(pcm, sample_rate, context_json,
                                    abort_flag, progress_queue);
}

}  // namespace openverb
