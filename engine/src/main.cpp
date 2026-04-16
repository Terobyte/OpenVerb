// OpenVerb Engine — entry point
// Thin wrapper that links openverb-engine-lib.

#include "config/version.h"
#include "config/interrupts.h"
#include "config/config.h"
#include "config/log.h"
#include "engine.h"
#include "ipc/server.h"
#include "audio/capture.h"
#include "audio/ring_buffer.h"
#include "ipc/progress.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>

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
    size_t i = 0;
    const size_t n = s.size();
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x80) {
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
            ++i;
            continue;
        }
        // Determine expected UTF-8 sequence length from lead byte.
        int seq_len = 0;
        if      ((c & 0xE0) == 0xC0) seq_len = 2;
        else if ((c & 0xF0) == 0xE0) seq_len = 3;
        else if ((c & 0xF8) == 0xF0) seq_len = 4;

        bool valid = (seq_len > 0);
        for (int j = 1; j < seq_len && valid; ++j) {
            if (i + static_cast<size_t>(j) >= n) { valid = false; break; }
            unsigned char cont = static_cast<unsigned char>(s[i + j]);
            if ((cont & 0xC0) != 0x80) valid = false;
        }

        if (valid) {
            for (int j = 0; j < seq_len; ++j)
                out += s[i + j];
            i += seq_len;
        } else {
            // Invalid or orphaned byte — escape as \uXXXX.
            char buf[8];
            std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
            out += buf;
            ++i;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    std::signal(SIGINT,  handle_signal);
    std::signal(SIGTERM, handle_signal);
    std::signal(SIGPIPE, SIG_IGN);

    Config cfg = parse_args(argc, argv);

    if (cfg.version) {
        std::printf("openverb-engine %s\n", OPENVERB_VERSION);
        return 0;
    }

    resolve_config(cfg);
    log_set_verbose(cfg.verbose);

    // --- Daemon mode: --listen ---
    if (cfg.listen) {
        std::string home(getenv("HOME") ? getenv("HOME") : "");
        std::filesystem::create_directories(home + "/.openverb");
        std::filesystem::create_directories(home + "/.openverb/logs");
        std::filesystem::create_directories(home + "/.openverb/models");

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
            openverb::Engine engine(cfg);
            openverb::IpcServer server(engine, cfg.model_idle_timeout_secs);
            server.start(cfg.socket_path);
        } catch (const std::exception& e) {
            if (g_interrupted.load(std::memory_order_relaxed)) return 130;
            std::fprintf(stderr, "error: %s\n", e.what());
            return 1;
        }
        return g_interrupted.load() ? 130 : 0;
    }

    // --- Standalone mic mode: --mic without --listen ---
    if (cfg.mic && !cfg.listen) {
        std::ifstream probe_m(cfg.model_path, std::ios::binary);
        if (!probe_m.is_open()) {
            std::fprintf(stderr, "error: cannot open model file: %s\n",
                         cfg.model_path.c_str());
            return 1;
        }
        std::ifstream probe_mm(cfg.mmproj_path, std::ios::binary);
        if (!probe_mm.is_open()) {
            std::fprintf(stderr, "error: cannot open mmproj file: %s\n",
                         cfg.mmproj_path.c_str());
            return 1;
        }

        RingBuffer ring_buffer;

        AudioCapture capture;
        capture.start([&](const uint8_t* data, size_t len) {
            size_t written = ring_buffer.write(data, len);
            if (written < len) {
                LOG_WARN("main: ring buffer full, dropped %zu bytes", len - written);
            }
        });

        std::fprintf(stderr, "Recording... press Ctrl-C to stop\n");
        while (!g_interrupted.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        capture.stop();

        auto pcm = ring_buffer.read_all();
        if (pcm.empty()) {
            std::fprintf(stderr, "No audio captured\n");
            return 0;
        }

        try {
            openverb::Engine engine(cfg);
            // #53: pass g_interrupted so Ctrl-C aborts inference immediately
            // instead of waiting for the full generation to complete.
            ProgressQueue pq;
            InferenceResult result = engine.process_stream(
                pcm, SAMPLE_RATE, cfg.context_json, g_interrupted, pq);
            if (!result.text.empty()) {
                std::printf("%s\n", result.text.c_str());
            } else if (!result.command.empty()) {
                std::printf("{\"command\":\"%s\"}\n", json_escape(result.command).c_str());
            }
        } catch (const std::exception& e) {
            if (g_interrupted.load(std::memory_order_relaxed)) return 130;
            std::fprintf(stderr, "error: %s\n", e.what());
            return 1;
        }
        return 0;
    }

    // --- CLI mode: --file required ---
    if (cfg.file_path.empty()) {
        std::fprintf(stderr, "error: --file required\n");
        return 1;
    }

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
        openverb::Engine engine(cfg);

        // Constructor no longer loads model; ensure_loaded() triggers the
        // ~4s load here so startup latency is visible before processing.
        engine.ensure_loaded();

        if (g_interrupted.load(std::memory_order_relaxed)) {
            return 130;
        }

        std::function<void(float)> progress_cb;
        if (cfg.verbose) {
            progress_cb = [](float pct) {
                std::fprintf(stderr, "progress: %.0f%%\r", pct * 100.0f);
            };
        } else {
            progress_cb = [](float) {};
        }

        InferenceResult result = engine.process_file(cfg.file_path,
                                                     cfg.context_json,
                                                     progress_cb);

        if (cfg.verbose) {
            std::fprintf(stderr, "inference: %lldms\n",
                         static_cast<long long>(result.inference_time_ms));
        }

        const bool has_text    = !result.text.empty();
        const bool has_command = !result.command.empty();

        if (cfg.json_output) {
            if (has_command) {
                std::printf("{\"text\":null,\"command\":\"%s\"}\n",
                            json_escape(result.command).c_str());
            } else {
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
        }

    } catch (const std::exception& e) {
        if (g_interrupted.load(std::memory_order_relaxed)) {
            return 130;
        }
        std::fprintf(stderr, "error: %s\n", e.what());
        return 1;
    }

    if (g_interrupted.load(std::memory_order_relaxed)) {
        return 130;
    }

    return 0;
}
