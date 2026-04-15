#pragma once

#include "config/defaults.h"

#include <string>

// ---------------------------------------------------------------------------
// Config — holds all runtime configuration for one openverb-engine invocation.
//
// Lifecycle:
//   Config cfg = parse_args(argc, argv);   // pure CLI parsing, no I/O
//   resolve_config(cfg);                   // expand paths, auto-detect files,
//                                          // compute thread count
// ---------------------------------------------------------------------------

struct Config {
    // --- paths ---
    std::string model_path;       // path to Gemma .gguf model (required after resolve)
    std::string mmproj_path;      // path to multimodal projector .gguf (required after resolve)
    std::string file_path;        // audio file to transcribe (--file)
    std::string context_json;     // caller-supplied context JSON (--context)
    std::string socket_path;      // Unix socket path for daemon mode

    // --- inference ---
    std::string backend  = DEFAULT_BACKEND;   // inference backend identifier
    int         threads  = DEFAULT_THREADS;   // -1 → resolved to auto count
    int         ctx_size = 4096;              // KV-cache context tokens
                                              // 4096 is ample for CLI short audio;
                                              // llama.cpp's 131072 default burns ~780 MB

    // --- behaviour ---
    bool vad_enabled = DEFAULT_VAD_ENABLED_FILE;  // VAD (false = off for file mode)
    bool json_output = false;     // emit JSON instead of plain text
    bool verbose     = false;     // enable INFO / DEBUG log output
    bool version     = false;     // caller should print version string then exit

    // --- daemon / IPC ---
    bool listen      = false;     // --listen: start IPC daemon
    bool mic         = false;     // --mic: microphone input mode
    int  model_idle_timeout_secs = DEFAULT_IDLE_TIMEOUT_SECS;
};

// ---------------------------------------------------------------------------
// parse_args — pure CLI parsing, no filesystem access.
//   Fills Config fields from argc/argv; unset fields keep their defaults.
//   Exits on --help or unrecognised flags.
// ---------------------------------------------------------------------------
Config parse_args(int argc, char** argv);

// ---------------------------------------------------------------------------
// resolve_config — I/O and validation pass (call after parse_args).
//   • Expands leading ~ in all path fields.
//   • If model_path is empty, scans DEFAULT_MODEL_DIR for DEFAULT_MODEL_GLOB
//     and picks the first alphabetically; warns if multiple matches; exits 1
//     if none found.
//   • If mmproj_path is empty, scans the model's directory for DEFAULT_MMPROJ_GLOB;
//     exits 1 if none found.
//   • If threads == DEFAULT_THREADS (-1), sets to max(1, min(4, physical_cores-2)).
// ---------------------------------------------------------------------------
void resolve_config(Config& cfg);
