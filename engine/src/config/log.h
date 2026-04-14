#pragma once

// ---------------------------------------------------------------------------
// Logging — MVP1 scope
//
// All output goes to stderr. No file logging or rotation in MVP1.
//
// Levels:
//   LOG_ERROR  — always emitted (fatal / non-fatal errors)
//   LOG_WARN   — always emitted (degraded operation warnings)
//   LOG_INFO   — emitted only when verbose mode is enabled
//   LOG_DEBUG  — emitted only when verbose mode is enabled
//
// Format:  [YYYY-MM-DD HH:MM:SS] [LEVEL] message\n
//
// Activate verbose output by calling log_set_verbose(true) after
// resolve_config() sets cfg.verbose.
// ---------------------------------------------------------------------------

/// Enable / disable INFO and DEBUG output.  Call once after resolve_config().
void log_set_verbose(bool verbose);

// Internal implementation helpers — not part of the public API.
namespace log_detail {
    bool is_verbose();
    void write(const char* level, const char* fmt, ...)
        __attribute__((format(printf, 2, 3)));  // enables -Wformat checks
}

// ---------------------------------------------------------------------------
// Public macros
// ---------------------------------------------------------------------------

#define LOG_ERROR(fmt, ...) \
    ::log_detail::write("ERROR", fmt, ##__VA_ARGS__)

#define LOG_WARN(fmt, ...) \
    ::log_detail::write("WARN", fmt, ##__VA_ARGS__)

#define LOG_INFO(fmt, ...) \
    do { if (::log_detail::is_verbose()) ::log_detail::write("INFO", fmt, ##__VA_ARGS__); } while (0)

#define LOG_DEBUG(fmt, ...) \
    do { if (::log_detail::is_verbose()) ::log_detail::write("DEBUG", fmt, ##__VA_ARGS__); } while (0)
