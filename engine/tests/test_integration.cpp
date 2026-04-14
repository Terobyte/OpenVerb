// ---------------------------------------------------------------------------
// test_integration.cpp — End-to-end integration test for OpenVerb Engine.
//
// Guarded by the OPENVERB_INTEGRATION_TESTS compile-time flag.
// Enable at cmake configure time:
//
//   cmake -DOPENVERB_INTEGRATION_TESTS=ON <source_dir>
//
// Runtime requirement:
//   OPENVERB_TEST_MODEL — absolute path to a Gemma audio .gguf model file.
//                         The corresponding mmproj .gguf is auto-detected
//                         from the same directory by resolve_config().
//
// If OPENVERB_TEST_MODEL is not set the single test in this file is skipped
// via GTEST_SKIP() so that a plain `ctest` run in CI never requires a model.
// ---------------------------------------------------------------------------

#ifdef OPENVERB_INTEGRATION_TESTS

#include <gtest/gtest.h>

#include <atomic>   // g_interrupted definition (see note below)
#include <cstdlib>  // std::getenv
#include <string>

#include "config/config.h"
#include "engine.h"

// ---------------------------------------------------------------------------
// g_interrupted — required by inference/llama_context.cpp.
//
// In production the symbol is defined in main.cpp (the CLI entry point).
// Test binaries never include main.cpp, so each binary that exercises the
// full Engine → Backend → LlamaContext path must define the symbol itself.
// Initialised to false: integration tests do not install a signal handler,
// so interruption is never requested during the test run.
// ---------------------------------------------------------------------------
std::atomic<bool> g_interrupted{false};

// ---------------------------------------------------------------------------
// Helper: compute the fixtures/ directory relative to this source file.
//
// CMake on macOS passes absolute paths to the compiler, so __FILE__ is
// always absolute — the same pattern used in test_reader.cpp.
// ---------------------------------------------------------------------------
static std::string fixtures_dir() {
    std::string p = __FILE__;
    auto sep = p.find_last_of("/\\");
    return (sep != std::string::npos ? p.substr(0, sep + 1) : std::string("./"))
           + "fixtures/";
}

// ===========================================================================
// Integration tests
// ===========================================================================

// ---------------------------------------------------------------------------
// ProcessFileSineWave
//
// Loads the real model, runs the full audio → inference pipeline on the
// committed sine_440hz.wav fixture, and asserts that:
//   1. The call returns without crashing.
//   2. The result text is non-empty (the model produced output).
//
// Fixture:  engine/tests/fixtures/sine_440hz.wav
//   mono, 44100 Hz, 16-bit PCM, 0.25 s, full-amplitude 440 Hz tone.
//   RMS ≈ 23 170 (int16 scale) — well above SILENCE_RMS_THRESHOLD (50) so
//   the silence gate does not suppress inference.
// ---------------------------------------------------------------------------
TEST(Integration, ProcessFileSineWaveProducesNonEmptyText) {
    // ── Runtime guard: skip cleanly if model path is absent ──────────────
    const char* model_env = std::getenv("OPENVERB_TEST_MODEL");
    if (!model_env || model_env[0] == '\0') {
        GTEST_SKIP() << "OPENVERB_TEST_MODEL is not set; skipping integration test. "
                        "Re-run with: OPENVERB_TEST_MODEL=/path/to/model.gguf ctest";
    }

    const std::string fixture = fixtures_dir() + "sine_440hz.wav";

    // ── Build Config ──────────────────────────────────────────────────────
    // model_path  — from env var (required)
    // mmproj_path — left empty so resolve_config() auto-detects it from the
    //               model's directory (standard deployment layout)
    // file_path   — set so resolve_config()'s early existence check passes
    Config cfg;
    cfg.model_path  = model_env;
    cfg.file_path   = fixture;
    cfg.threads     = -1;    // -1 → auto: resolve_config sets max(1, min(4, cores-2))
    cfg.ctx_size    = 4096;
    cfg.vad_enabled = false; // file mode: no VAD needed

    // resolve_config() expands ~, auto-detects mmproj, and computes threads.
    resolve_config(cfg);

    // ── Construct engine (loads model weights) ────────────────────────────
    openverb::Engine engine(cfg);

    // ── Run full pipeline: WAV read → silence gate → resample → inference ─
    InferenceResult result = engine.process_file(fixture, /*context_json=*/"");

    // ── Assertions ────────────────────────────────────────────────────────
    // The sine fixture has substantial energy; the model must produce output.
    EXPECT_FALSE(result.text.empty())
        << "Engine::process_file returned empty text for a non-silent 440 Hz "
           "sine fixture. model=" << cfg.model_path;
}

#endif  // OPENVERB_INTEGRATION_TESTS
