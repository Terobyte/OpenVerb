#include "config/config.h"
#include "config/defaults.h"

#include <nlohmann/json.hpp>  // JSON validation in resolve_config()

#include <getopt.h>   // BSD getopt_long — ships with macOS; compatible for
                      // required_argument / no_argument (avoid optional_argument)
#include <glob.h>     // POSIX glob(3) for filename pattern matching
#include <unistd.h>   // sysconf
#if defined(__APPLE__)
#  include <sys/sysctl.h> // sysctlbyname (macOS physical core count)
#endif

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// File-local helpers (not part of the public API)
// ---------------------------------------------------------------------------
namespace {

/// Expand a leading ~ to the value of $HOME.
std::string expand_tilde(const std::string& path) {
    if (!path.empty() && path[0] == '~') {
        const char* home = std::getenv("HOME");
        if (home && home[0] != '\0') {
            return std::string(home) + path.substr(1);
        }
    }
    return path;
}

/// Return the number of physical (not logical/SMT) CPU cores.
/// Uses macOS-specific sysctlbyname first; falls back to POSIX sysconf.
int physical_cores() {
#if defined(__APPLE__)
    int ncpu = 0;
    size_t len = sizeof(ncpu);
    if (::sysctlbyname("hw.physicalcpu", &ncpu, &len, nullptr, 0) == 0 && ncpu > 0) {
        return ncpu;
    }
#endif
    long n = ::sysconf(_SC_NPROCESSORS_ONLN);
    return (n > 0) ? static_cast<int>(n) : 1;
}

/// Compute automatic thread count: max(1, min(4, physical_cores - 2)).
/// Reserves 2 cores for the OS and UI; caps at 4 to avoid thrashing short
/// audio inference jobs that are not deeply parallelisable.
int auto_threads() {
    int t = physical_cores() - 2;
    if (t < 1) t = 1;
    if (t > 4) t = 4;
    return t;
}

/// Scan `dir` for files matching the shell glob `pattern` and return their
/// absolute paths sorted alphabetically.  No dependency on the inference layer.
std::vector<std::string> find_file_by_glob(const std::string& dir,
                                            const std::string& pattern) {
    std::string full = dir;
    // Ensure trailing slash before appending the pattern
    if (!full.empty() && full.back() != '/') full += '/';
    full += pattern;

    glob_t g{};  // zero-init so globfree is safe regardless of glob() return code
    std::vector<std::string> matches;

    if (::glob(full.c_str(), 0, nullptr, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; ++i) {
            matches.emplace_back(g.gl_pathv[i]);
        }
    }
    ::globfree(&g);

    std::sort(matches.begin(), matches.end());
    return matches;
}

/// Print usage to stderr.
void print_help(const char* prog) {
    std::fprintf(stderr,
        "Usage: %s [OPTIONS]\n"
        "\n"
        "File mode (default):\n"
        "  --file <path>              Audio file to transcribe\n"
        "\n"
        "Daemon mode:\n"
        "  --listen                   Start in daemon mode (listen on Unix socket)\n"
        "  --socket <path>            Unix socket path (default: ~/.openverb/engine.sock)\n"
        "  --model-idle-timeout <n>   Unload model after N idle seconds (0 = never)\n"
        "  --mic                      Use microphone as audio input source\n"
        "\n"
        "Model options:\n"
        "  --model <path>             Path to GGUF model file\n"
        "  --mmproj <path>            Path to mmproj GGUF file\n"
        "  --backend <name>           Inference backend (default: %s)\n"
        "  --threads <n>              CPU threads, -1 = auto (default: -1)\n"
        "  --ctx-size <n>             KV-cache context tokens (default: 4096)\n"
        "\n"
        "Audio options:\n"
        "  --context <json>           Context JSON string\n"
        "  --vad                      Enable voice activity detection\n"
        "  --no-vad                   Disable voice activity detection\n"
        "\n"
        "Output options:\n"
        "  --json                     Emit JSON output\n"
        "  --verbose                  Enable INFO/DEBUG log output\n"
        "  --version                  Print version and exit\n"
        "  --help                     Show this help\n",
        prog, DEFAULT_BACKEND
    );
}

} // namespace

// ---------------------------------------------------------------------------
// parse_args — pure CLI parsing, no filesystem access
// ---------------------------------------------------------------------------
Config parse_args(int argc, char** argv) {
    Config cfg;

    // Long-option table.  Short equivalents are single-char sentinels only
    // used internally by getopt_long — we expose no short flags to the user.
    static const struct option long_opts[] = {
        { "file",     required_argument, nullptr, 'f' },
        { "model",    required_argument, nullptr, 'm' },
        { "mmproj",   required_argument, nullptr, 'p' },
        { "context",  required_argument, nullptr, 'c' },
        { "backend",  required_argument, nullptr, 'b' },
        { "threads",  required_argument, nullptr, 't' },
        { "ctx-size", required_argument, nullptr, 's' },
        { "vad",      no_argument,       nullptr, 'V' },
        { "no-vad",   no_argument,       nullptr, 'N' },
        { "json",     no_argument,       nullptr, 'j' },
        { "verbose",  no_argument,       nullptr, 'v' },
        { "version",  no_argument,       nullptr, 'r' },
        { "help",     no_argument,       nullptr, 'h' },
        { "listen",   no_argument,       nullptr, 'L' },
        { "socket",   required_argument, nullptr, 'S' },
        { "model-idle-timeout", required_argument, nullptr, 'T' },
        { "mic",      no_argument,       nullptr, 'M' },
        { nullptr,    0,                 nullptr,  0  }
    };

    // Reset getopt state so parse_args() is safely callable more than once
    // in the same process (unit tests, embedded use).  On BSD/macOS, both
    // optind and optreset must be set: optreset clears the internal optnext
    // pointer (used for short-option clusters) that optind alone does not
    // touch.  Without optreset, a future refactor that adds a short optstring
    // could leave stale optnext state that silently corrupts the next parse.
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
    extern int optreset;
    optreset = 1;
#endif
    ::optind = 1;

    int opt;
    int opt_idx = 0;
    // Empty short-option string: no short flags, only long ones.
    while ((opt = ::getopt_long(argc, argv, "", long_opts, &opt_idx)) != -1) {
        switch (opt) {
            case 'f': cfg.file_path    = optarg; break;
            case 'm': cfg.model_path   = optarg; break;
            case 'p': cfg.mmproj_path  = optarg; break;
            case 'c': cfg.context_json = optarg; break;
            case 'b': cfg.backend      = optarg; break;
            case 't':
                try {
                    cfg.threads = std::stoi(optarg);
                } catch (const std::exception&) {
                    std::fprintf(stderr,
                        "error: --threads requires an integer, got '%s'\n", optarg);
                    std::exit(1);
                }
                if (cfg.threads != -1 && cfg.threads <= 0) {
                    std::fprintf(stderr,
                        "error: --threads must be > 0 (or -1 for auto), got %d\n",
                        cfg.threads);
                    std::exit(1);
                }
                break;
            case 's':
                try {
                    cfg.ctx_size = std::stoi(optarg);
                } catch (const std::exception&) {
                    std::fprintf(stderr,
                        "error: --ctx-size requires an integer, got '%s'\n", optarg);
                    std::exit(1);
                }
                if (cfg.ctx_size <= 0) {
                    std::fprintf(stderr,
                        "error: --ctx-size must be > 0, got %d\n", cfg.ctx_size);
                    std::exit(1);
                }
                break;
            case 'V': cfg.vad_enabled  = true;               break;
            case 'N': cfg.vad_enabled  = false;              break;
            case 'j': cfg.json_output  = true;               break;
            case 'v': cfg.verbose      = true;               break;
            case 'r': cfg.version      = true;               break;
            case 'L': cfg.listen       = true;               break;
            case 'S': cfg.socket_path  = optarg;             break;
            case 'M': cfg.mic          = true;               break;
            case 'T':
                try {
                    cfg.model_idle_timeout_secs = std::stoi(optarg);
                } catch (const std::exception&) {
                    std::fprintf(stderr,
                        "error: --model-idle-timeout requires an integer, got '%s'\n", optarg);
                    std::exit(1);
                }
                if (cfg.model_idle_timeout_secs < 0) {
                    std::fprintf(stderr,
                        "error: --model-idle-timeout must be >= 0, got %d\n",
                        cfg.model_idle_timeout_secs);
                    std::exit(1);
                }
                break;
            case 'h':
                print_help(argv[0]);
                std::exit(0);
            default:
                print_help(argv[0]);
                std::exit(1);
        }
    }

    return cfg;
}

// ---------------------------------------------------------------------------
// resolve_config — I/O and validation (call after parse_args)
// ---------------------------------------------------------------------------
void resolve_config(Config& cfg) {
    if (cfg.listen && !cfg.file_path.empty()) {
        std::fprintf(stderr, "error: --listen and --file are mutually exclusive\n");
        std::exit(1);
    }
    if (cfg.mic && !cfg.file_path.empty()) {
        std::fprintf(stderr, "error: --mic and --file are mutually exclusive\n");
        std::exit(1);
    }

    if (cfg.socket_path.empty() && cfg.listen) {
        cfg.socket_path = DEFAULT_SOCKET_PATH;
    }

    // ---- Validate context JSON if provided -----------------------------
    // The documented schema is a JSON object with optional string fields
    // "app", "window", "clipboard", "selected".  Arrays, scalars, and any
    // other non-object JSON value are rejected here so callers never receive
    // a Config whose context_json does not conform to the object contract.
    if (!cfg.context_json.empty()) {
        try {
            auto j = nlohmann::json::parse(cfg.context_json);
            if (!j.is_object()) {
                std::fprintf(stderr,
                    "error: invalid context JSON: must be a JSON object\n");
                std::exit(1);
            }
        } catch (const nlohmann::json::parse_error& e) {
            std::fprintf(stderr,
                "error: invalid context JSON: %s\n", e.what());
            std::exit(1);
        }
    }

    // ---- Expand ~ in all path fields -----------------------------------
    if (!cfg.model_path.empty())  cfg.model_path  = expand_tilde(cfg.model_path);
    if (!cfg.mmproj_path.empty()) cfg.mmproj_path = expand_tilde(cfg.mmproj_path);
    if (!cfg.file_path.empty())   cfg.file_path   = expand_tilde(cfg.file_path);
    if (!cfg.socket_path.empty()) cfg.socket_path  = expand_tilde(cfg.socket_path);

    // ---- Early existence checks (fail before expensive model scan/load) -
    // Audio file: validate immediately so we don't waste the 4–10 s model
    // load only to discover the input is missing.
    if (!cfg.file_path.empty()) {
        std::ifstream probe(cfg.file_path, std::ios::binary);
        if (!probe.is_open()) {
            std::fprintf(stderr, "error: cannot open audio file: %s\n",
                         cfg.file_path.c_str());
            std::exit(1);
        }
    }

    // ---- Auto-detect model file ----------------------------------------
    if (cfg.model_path.empty()) {
        // Search candidate directories in priority order:
        //   1. User's install directory  (~/.openverb/models/)
        //   2. In-tree validation models (./validation/models/)
        //   3. Bare models dir           (./models/)
        const std::vector<std::string> candidate_dirs = {
            expand_tilde(DEFAULT_MODEL_DIR),
            "validation/models",
            "models",
        };

        std::vector<std::string> matches;
        std::string found_dir;
        for (const auto& dir : candidate_dirs) {
            matches = find_file_by_glob(dir, DEFAULT_MODEL_GLOB);
            if (!matches.empty()) {
                found_dir = dir;
                break;
            }
        }

        if (matches.empty()) {
            std::fprintf(stderr,
                "error: no model found matching '%s'\n"
                "       searched: %s, validation/models, models\n"
                "       use --model <path> to specify a model file\n",
                DEFAULT_MODEL_GLOB,
                expand_tilde(DEFAULT_MODEL_DIR).c_str());
            std::exit(1);
        }

        if (matches.size() > 1) {
            std::fprintf(stderr,
                "warning: multiple models found in '%s' matching '%s':\n",
                found_dir.c_str(), DEFAULT_MODEL_GLOB);
            for (const auto& m : matches) {
                std::fprintf(stderr, "         %s\n", m.c_str());
            }
            std::fprintf(stderr, "         using: %s\n", matches[0].c_str());
        }

        cfg.model_path = std::filesystem::weakly_canonical(matches[0]).string();
    }

    // ---- Auto-detect mmproj file ----------------------------------------
    if (cfg.mmproj_path.empty()) {
        // Derive the model's containing directory
        std::string model_dir;
        auto sep = cfg.model_path.rfind('/');
        model_dir = (sep != std::string::npos)
                    ? cfg.model_path.substr(0, sep)
                    : ".";

        auto matches = find_file_by_glob(model_dir, DEFAULT_MMPROJ_GLOB);

        if (matches.empty()) {
            std::fprintf(stderr,
                "error: no mmproj file found matching '%s'\n"
                "       use --mmproj <path> to specify the projector file\n",
                DEFAULT_MMPROJ_GLOB);
            std::exit(1);
        }

        cfg.mmproj_path = matches[0];
    }

    // ---- Thread count --------------------------------------------------
    if (cfg.threads == DEFAULT_THREADS) {
        cfg.threads = auto_threads();
    }
}
