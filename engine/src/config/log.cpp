#include "config/log.h"

#include <cstdarg>
#include <cstdio>
#include <ctime>

// ---------------------------------------------------------------------------
// Module-level verbose flag
// ---------------------------------------------------------------------------
static bool s_verbose = false;

void log_set_verbose(bool verbose) {
    s_verbose = verbose;
}

// ---------------------------------------------------------------------------
// log_detail implementation
// ---------------------------------------------------------------------------
namespace log_detail {

bool is_verbose() {
    return s_verbose;
}

void write(const char* level, const char* fmt, ...) {
    // Build timestamp: [YYYY-MM-DD HH:MM:SS]
    time_t now = ::time(nullptr);
    struct tm tm_info;
    ::localtime_r(&now, &tm_info);  // thread-safe; macOS / POSIX

    char ts[24];
    ::strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_info);

    std::fprintf(stderr, "[%s] [%s] ", ts, level);

    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    va_end(args);

    std::fputc('\n', stderr);
}

} // namespace log_detail
