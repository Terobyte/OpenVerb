#pragma once

#include <atomic>
#include <string>
#include <thread>

#if defined(__APPLE__)
#  include <dispatch/dispatch.h>
#endif

namespace openverb {

class Engine;

class IpcServer {
public:
    IpcServer(Engine& engine, int idle_timeout_secs = 300);
    ~IpcServer();

    IpcServer(const IpcServer&)            = delete;
    IpcServer& operator=(const IpcServer&) = delete;

    void start(const std::string& socket_path);
    void stop();
    bool is_running() const;

private:
    void write_pid_file(const std::string& pid_path);
    void remove_pid_file(const std::string& pid_path);

    Engine&              engine_;
    int                  idle_timeout_secs_;
    std::atomic<bool>    running_{false};
    int                  listen_fd_{-1};
    std::string          socket_path_;
    std::string          pid_path_;

    std::thread          preload_thread_;   // background model preload at startup
    std::thread          session_thread_;
    std::atomic<bool>    session_active_{false};

    // Time of last session completion (seconds since steady_clock epoch).
    // Written by the session thread; read by the main poll loop.
    // Must be atomic to avoid a data race.
    std::atomic<int64_t> last_inference_sec_{0};

    // Memory pressure flags (set by GCD handler, checked in poll loop)
    std::atomic<bool>    pressure_force_unload_{false};   // WARN level
    std::atomic<bool>    pressure_critical_active_{false}; // CRITICAL level

#if defined(__APPLE__)
    dispatch_source_t    mem_source_{nullptr};
    dispatch_queue_t     mem_queue_{nullptr};
#endif
};

}
