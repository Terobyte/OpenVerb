#include "config/log.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <mutex>
#include <string>

static std::mutex        s_mutex;
static std::atomic<bool> s_verbose{false};
static FILE*       s_log_file  = nullptr;
static std::string s_log_path;

static constexpr size_t MAX_LOG_SIZE = 10 * 1024 * 1024; // 10 MB

void log_set_verbose(bool verbose) {
    s_verbose.store(verbose, std::memory_order_relaxed);
}

void log_set_log_file(const char* path) {
    std::lock_guard<std::mutex> lock(s_mutex);
    if (s_log_file) {
        std::fclose(s_log_file);
        s_log_file = nullptr;
    }
    s_log_path.clear();
    if (!path) return;
    s_log_path = path;
    s_log_file = std::fopen(path, "a");
}

static void rotate_log() {
    if (s_log_path.empty() || !s_log_file) return;

    long size = std::ftell(s_log_file);
    if (size < 0 || static_cast<size_t>(size) < MAX_LOG_SIZE) return;

    std::fclose(s_log_file);
    s_log_file = nullptr;

    std::string p3 = s_log_path + ".3";
    std::string p2 = s_log_path + ".2";
    std::string p1 = s_log_path + ".1";

    std::remove(p3.c_str());
    std::rename(p2.c_str(), p3.c_str());
    std::rename(p1.c_str(), p2.c_str());
    std::rename(s_log_path.c_str(), p1.c_str());

    s_log_file = std::fopen(s_log_path.c_str(), "a");
    if (!s_log_file) {
        std::fprintf(stderr, "[log] rotate: fopen failed: %s\n", std::strerror(errno));
    }
}

namespace log_detail {

bool is_verbose() {
    return s_verbose.load(std::memory_order_relaxed);
}

void write(const char* level, const char* fmt, ...) {
    time_t now = ::time(nullptr);
    struct tm tm_info;
    ::localtime_r(&now, &tm_info);

    char ts[24];
    ::strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_info);

    // Format the message once into a string using va_copy so both
    // stderr and file writes use the same formatted text.  This also
    // eliminates the va_end/va_start rewind that was UB.
    va_list args;
    va_start(args, fmt);
    va_list args_len;
    va_copy(args_len, args);
    int needed = std::vsnprintf(nullptr, 0, fmt, args_len);
    va_end(args_len);

    std::string msg;
    if (needed > 0) {
        msg.resize(static_cast<size_t>(needed));
        std::vsnprintf(msg.data(), msg.size() + 1, fmt, args);
    }
    va_end(args);

    // Both stderr and file under the mutex — prevents interleaved output
    // from concurrent threads and serialises log rotation.
    std::lock_guard<std::mutex> lock(s_mutex);
    std::fprintf(stderr, "[%s] [%s] %s\n", ts, level, msg.c_str());
    if (s_log_file) {
        std::fprintf(s_log_file, "[%s] [%s] %s\n", ts, level, msg.c_str());
        std::fflush(s_log_file);
    }
    rotate_log(); // always called under lock — prevents double-fclose race
}

} // namespace log_detail
