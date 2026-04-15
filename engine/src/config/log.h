#pragma once

#include <cstdio>

void log_set_verbose(bool verbose);
void log_set_log_file(const char* path);

namespace log_detail {
    bool is_verbose();
    void write(const char* level, const char* fmt, ...)
        __attribute__((format(printf, 2, 3)));
}

#define LOG_ERROR(fmt, ...) \
    ::log_detail::write("ERROR", fmt, ##__VA_ARGS__)

#define LOG_WARN(fmt, ...) \
    ::log_detail::write("WARN", fmt, ##__VA_ARGS__)

#define LOG_INFO(fmt, ...) \
    do { if (::log_detail::is_verbose()) ::log_detail::write("INFO", fmt, ##__VA_ARGS__); } while (0)

#define LOG_DEBUG(fmt, ...) \
    do { if (::log_detail::is_verbose()) ::log_detail::write("DEBUG", fmt, ##__VA_ARGS__); } while (0)
