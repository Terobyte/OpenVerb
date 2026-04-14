// OpenVerb Engine — backend factory

#include "backend.h"
#include "backend_gemma_audio.h"

#include <stdexcept>
#include <string>

// ---------------------------------------------------------------------------
// create_backend — construct a Backend implementation by name.
//
// Currently registered backends:
//   "gemma_audio"  → GemmaAudioBackend  (Gemma 4 E2B via llama.cpp + mtmd)
// ---------------------------------------------------------------------------
std::unique_ptr<Backend> create_backend(const std::string& backend_name,
                                         const std::string& model_path,
                                         const std::string& mmproj_path,
                                         int                threads,
                                         int                ctx_size,
                                         bool               vad_enabled) {
    if (backend_name == "gemma_audio") {
        return std::make_unique<GemmaAudioBackend>(
            model_path, mmproj_path, threads, ctx_size, vad_enabled);
    }

    throw std::invalid_argument(
        "create_backend: unknown backend '" + backend_name + "'. "
        "Available backends: gemma_audio");
}
