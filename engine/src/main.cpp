// OpenVerb Engine — entry point
// Thin wrapper that links openverb-engine-lib.

#include "config/version.h"
#include "config/interrupts.h"
#include "config/config.h"
#include "config/log.h"
#include "engine.h"

#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <fstream>
#include <stdexcept>
#include <string>

// ---------------------------------------------------------------------------
// g_interrupted — declared extern in config/interrupts.h.
// Defined here (main.cpp) because this is the process entry point.
// Set to true by handle_signal(); the generation loop and LlamaContext
// constructor poll it to abort cleanly on SIGINT / SIGTERM.
// ---------------------------------------------------------------------------
std::atomic<bool> g_interrupted{false};

static void handle_signal(int /*sig*/) {
    g_interrupted.store(true, std::memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// json_escape — minimal UTF-8 → JSON string escaping.
// Handles the five characters that must always be escaped (" \\ \n \r \t)
// plus C0 control characters (emitted as \uXXXX).  Sufficient for MVP1
// model output which never contains embedded NUL or surrogate pairs.
// ---------------------------------------------------------------------------
static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x",
                                  static_cast<unsigned>(c));
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
                break;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    // ── Install signal handlers first — model load can take several seconds
    //    and must be interruptible.
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);

    // ── Parse CLI args (pure, no I/O).
    Config cfg = parse_args(argc, argv);

    // ── --version: print banner and exit before any I/O.
    if (cfg.version) {
        std::printf("openverb-engine %s\n", OPENVERB_VERSION);
        return 0;
    }

    // ── --file is required.
    if (cfg.file_path.empty()) {
        std::fprintf(stderr, "error: --file required\n");
        return 1;
    }

    // ── Resolve paths and auto-detect model files (I/O phase).
    resolve_config(cfg);
    log_set_verbose(cfg.verbose);

    // ── Verify resolved model / mmproj paths are readable before the expensive
    //    Metal compilation + weight load.  This gives a clean, instant error
    //    rather than waiting several seconds for llama.cpp to discover the file
    //    is missing and emit its own diagnostic lines before ours.
    {
        std::ifstream probe(cfg.model_path, std::ios::binary);
        if (!probe.is_open()) {
            std::fprintf(stderr, "error: cannot open model file: %s\n",
                         cfg.model_path.c_str());
            return 1;
        }
    }
    {
        std::ifstream probe(cfg.mmproj_path, std::ios::binary);
        if (!probe.is_open()) {
            std::fprintf(stderr, "error: cannot open mmproj file: %s\n",
                         cfg.mmproj_path.c_str());
            return 1;
        }
    }

    try {
        // ── Construct Engine — loads model weights from disk.
        //    On Apple Silicon this triggers Metal shader compilation which can
        //    take 2-5 s; SIGINT during this window sets g_interrupted.
        openverb::Engine engine(cfg);

        // Check (1): if SIGINT arrived during the multi-second model load,
        // abort before the GPU context is initialised (LlamaContext ctor
        // also checks this flag internally after llama_model_load_from_file).
        if (g_interrupted.load(std::memory_order_relaxed)) {
            return 130;
        }

        // ── Progress callback.
        //    In --verbose mode: print in-place percentage updates to stderr
        //    (carriage return keeps output on one line).
        //    In non-verbose mode: no-op callable (never produces output).
        //
        //    The callback is wired to inference via Engine::process_file →
        //    Backend::process.  Check (2) — the generation loop polls
        //    g_interrupted each token and calls this callback with the
        //    current fraction; aborting the loop stops further callbacks.
        std::function<void(float)> progress_cb;
        if (cfg.verbose) {
            progress_cb = [](float pct) {
                std::fprintf(stderr, "progress: %.0f%%\r", pct * 100.0f);
            };
        } else {
            progress_cb = [](float) {};
        }

        // ── Run the full audio → inference pipeline.
        InferenceResult result = engine.process_file(cfg.file_path,
                                                     cfg.context_json,
                                                     progress_cb);

        // ── Verbose: print inference wall-clock time.
        if (cfg.verbose) {
            std::fprintf(stderr, "inference: %lldms\n",
                         static_cast<long long>(result.inference_time_ms));
        }

        // ── Emit result.
        //
        //    Default mode:
        //      text result    → raw string + \n  (stdout)
        //      command result → {"command":"<action>"}\n  (first char '{' →
        //                       caller can distinguish from plain text)
        //      empty result   → nothing to stdout, exit 0
        //
        //    --json mode (uniform, unambiguous):
        //      text result    → {"text":"<...>","command":null}\n
        //      command result → {"text":null,"command":"<action>"}\n
        //      empty result   → {"text":"","command":null}\n
        //
        //    Both modes always end with \n for clean terminal output.

        const bool has_text    = !result.text.empty();
        const bool has_command = !result.command.empty();

        if (cfg.json_output) {
            if (has_command) {
                std::printf("{\"text\":null,\"command\":\"%s\"}\n",
                            json_escape(result.command).c_str());
            } else {
                // covers both text result and empty result
                std::printf("{\"text\":\"%s\",\"command\":null}\n",
                            json_escape(result.text).c_str());
            }
        } else {
            if (has_command) {
                std::printf("{\"command\":\"%s\"}\n",
                            json_escape(result.command).c_str());
            } else if (has_text) {
                std::printf("%s\n", result.text.c_str());
            }
            // empty result: output nothing, fall through to return 0
        }

    } catch (const std::exception& e) {
        // If SIGINT arrived during the model-load window, LlamaContext::Impl
        // throws to unwind — honour the convention (128 + SIGINT = 130) rather
        // than treating it as an error exit (1).
        if (g_interrupted.load(std::memory_order_relaxed)) {
            return 130;
        }
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }

    // ── On SIGINT received at any point after the try block (e.g. during
    //    output flushing): exit 130 (128 + SIGINT signal number, standard
    //    shell convention for interrupted processes).
    if (g_interrupted.load(std::memory_order_relaxed)) {
        return 130;
    }

    return 0;
}
