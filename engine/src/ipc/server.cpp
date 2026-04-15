#include "ipc/server.h"
#include "ipc/protocol.h"
#include "ipc/session.h"
#include "config/defaults.h"
#include "config/interrupts.h"
#include "config/log.h"
#include "engine.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <poll.h>

#if defined(__APPLE__)
#  include <dispatch/dispatch.h>
#endif

namespace openverb {

IpcServer::IpcServer(Engine& engine, int idle_timeout_secs)
    : engine_(engine), idle_timeout_secs_(idle_timeout_secs) {}

IpcServer::~IpcServer() {
    stop();
}

void IpcServer::write_pid_file(const std::string& pid_path) {
    std::ofstream pf(pid_path);
    if (pf.is_open()) {
        pf << ::getpid() << "\n";
    }
}

void IpcServer::remove_pid_file(const std::string& pid_path) {
    if (!pid_path.empty()) {
        ::unlink(pid_path.c_str());
    }
}

void IpcServer::start(const std::string& socket_path) {
    socket_path_ = socket_path;

    std::string expanded = socket_path;
    if (!expanded.empty() && expanded[0] == '~') {
        const char* home = ::getenv("HOME");
        if (home) expanded = std::string(home) + expanded.substr(1);
    }

    std::string pid_path = DEFAULT_PID_PATH;
    if (!pid_path.empty() && pid_path[0] == '~') {
        const char* home = ::getenv("HOME");
        if (home) pid_path = std::string(home) + pid_path.substr(1);
    }
    pid_path_ = pid_path;

    ::unlink(expanded.c_str());

    listen_fd_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_fd_ < 0) {
        LOG_ERROR("ipc: socket() failed: %s", std::strerror(errno));
        return;
    }

    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, expanded.c_str(), sizeof(addr.sun_path) - 1);

    if (::bind(listen_fd_, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
        LOG_ERROR("ipc: bind() failed: %s", std::strerror(errno));
        ::close(listen_fd_);
        listen_fd_ = -1;
        return;
    }

    ::chmod(expanded.c_str(), 0600);

    if (::listen(listen_fd_, 1) < 0) {
        LOG_ERROR("ipc: listen() failed: %s", std::strerror(errno));
        ::close(listen_fd_);
        ::unlink(expanded.c_str());
        listen_fd_ = -1;
        return;
    }

    write_pid_file(pid_path_);
    running_.store(true, std::memory_order_release);

    // Do NOT reset g_interrupted here.  If a signal arrived before start()
    // was called (e.g. during Engine construction) the flag must remain set
    // so the loop below exits immediately rather than silently swallowing it.

    LOG_INFO("ipc: listening on %s", expanded.c_str());

    // Preload the model in a background thread so the first session doesn't
    // pay the load cost.  The socket is already listening when this starts, so
    // ensureRunning() pings succeed immediately while the model loads.
    // If a session arrives before preload finishes, ensure_loaded() blocks on
    // engine_mutex_ until the background thread releases it — correct behaviour.
    preload_thread_ = std::thread([this]() {
        try {
            LOG_INFO("ipc: preloading model...");
            engine_.ensure_loaded();
            LOG_INFO("ipc: model preloaded");
        } catch (const std::exception& e) {
            LOG_WARN("ipc: preload failed (will retry on first session): %s", e.what());
        }
    });

#if defined(__APPLE__)
    // Register a GCD memory pressure source.  On WARN we schedule a lazy
    // idle unload (checked in the poll timeout branch).  On CRITICAL we
    // unload immediately so jetsam doesn't kill the process.
    {
        auto* self = this;
        mem_queue_ = dispatch_queue_create("com.openverb.mem_pressure", nullptr);
        mem_source_ = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,
            0,
            DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
            mem_queue_);

        if (mem_source_) {
            dispatch_source_set_event_handler(mem_source_, ^{
                unsigned long pressure =
                    dispatch_source_get_data(self->mem_source_);

                if (pressure & DISPATCH_MEMORYPRESSURE_CRITICAL) {
                    LOG_WARN("ipc: CRITICAL memory pressure — aborting session + unloading model");
                    if (self->pressure_critical_active_.load(std::memory_order_acquire)) {
                        // Session is active: calling unload_model() while inference
                        // is running is a use-after-free.  Set g_interrupted to abort
                        // the session and exit the main poll loop; the process will
                        // terminate and the OS reclaims memory.  pressure_force_unload_
                        // is set as a belt-and-suspenders signal (not acted on since
                        // the poll loop exits immediately after g_interrupted is set).
                        g_interrupted.store(true, std::memory_order_relaxed);
                        self->pressure_force_unload_.store(true, std::memory_order_relaxed);
                    } else {
                        // No active session: safe to unload immediately.
                        self->engine_.unload_model();
                        self->pressure_force_unload_.store(false, std::memory_order_relaxed);
                    }
                } else if (pressure & DISPATCH_MEMORYPRESSURE_WARN) {
                    LOG_WARN("ipc: WARN memory pressure — scheduling idle unload");
                    self->pressure_force_unload_.store(true, std::memory_order_relaxed);
                }
            });
            dispatch_resume(mem_source_);
        }
    }
#endif

    // Initialise last_inference_sec_ to the current time so the idle-unload
    // timer starts from when the server began accepting connections.
    auto now_sec = [] -> int64_t {
        return std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
    };
    last_inference_sec_.store(now_sec(), std::memory_order_relaxed);
    bool idle_unloaded = false;

    while (running_.load(std::memory_order_relaxed) &&
           !g_interrupted.load(std::memory_order_relaxed)) {

        struct pollfd pfd{};
        pfd.fd      = listen_fd_;
        pfd.events  = POLLIN;

        int pret = ::poll(&pfd, 1, 1000);

        if (!running_.load(std::memory_order_relaxed) ||
            g_interrupted.load(std::memory_order_relaxed)) {
            break;
        }

        if (pret < 0) {
            if (errno == EINTR) continue;
            LOG_ERROR("ipc: poll() error: %s", std::strerror(errno));
            break;
        }

        if (pret == 0) {
            // Only clear the critical-active flag when no session is running.
            // A session thread runs concurrently with this poll loop; the
            // timeout does NOT mean no session is active.
            if (!session_active_.load(std::memory_order_relaxed)) {
                pressure_critical_active_.store(false, std::memory_order_relaxed);
            }

            // Check forced unload from memory pressure WARN handler.
            if (pressure_force_unload_.load(std::memory_order_relaxed)) {
                if (!session_active_.load(std::memory_order_relaxed)) {
                    pressure_force_unload_.store(false, std::memory_order_relaxed);
                    LOG_INFO("ipc: memory pressure — forced idle unload");
                    engine_.unload_model();
                    idle_unloaded = true;
                    last_inference_sec_.store(now_sec(), std::memory_order_relaxed);
                }
                // else: session active — leave flag set, retry next tick
            }

            // Regular idle timeout — only when no session is active.
            if (!idle_unloaded && idle_timeout_secs_ > 0 &&
                !session_active_.load(std::memory_order_relaxed)) {
                int64_t elapsed = now_sec()
                    - last_inference_sec_.load(std::memory_order_relaxed);
                if (elapsed >= idle_timeout_secs_) {
                    LOG_INFO("ipc: idle timeout reached, unloading model");
                    engine_.unload_model();
                    idle_unloaded = true;
                    last_inference_sec_.store(now_sec(), std::memory_order_relaxed);
                }
            }
            continue;
        }

        if (!(pfd.revents & POLLIN)) continue;

        int client_fd = ::accept(listen_fd_, nullptr, nullptr);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            LOG_ERROR("ipc: accept() failed: %s", std::strerror(errno));
            continue;
        }

        // Join the previous session thread.  The thread resets session_active_
        // before it exits, so after join() it is always false.  Any second
        // client that arrived while the session was still running was queued by
        // the kernel (backlog=1) and will be served here without rejection.
        if (session_thread_.joinable()) {
            session_thread_.join();
        }

        idle_unloaded = false;
        pressure_critical_active_.store(true, std::memory_order_release);
        session_active_.store(true, std::memory_order_release);
        LOG_INFO("ipc: session started");

        session_thread_ = std::thread([this, client_fd, now_sec]() {
            try {
                openverb::Session::handle_connection(client_fd, engine_);
            } catch (const std::exception& e) {
                LOG_WARN("ipc: session error: %s", e.what());
            }
            ::close(client_fd);
            pressure_critical_active_.store(false, std::memory_order_relaxed);
            session_active_.store(false, std::memory_order_relaxed);
            last_inference_sec_.store(now_sec(), std::memory_order_relaxed);
            LOG_INFO("ipc: session ended");
        });
    }

    stop();
}

void IpcServer::stop() {
    if (!running_.load(std::memory_order_relaxed)) return;
    running_.store(false, std::memory_order_release);
    g_interrupted.store(true, std::memory_order_relaxed);

    if (preload_thread_.joinable()) {
        preload_thread_.join();
    }

    if (session_thread_.joinable()) {
        session_thread_.join();
    }

#if defined(__APPLE__)
    if (mem_source_) {
        dispatch_source_cancel(mem_source_);
        // Barrier: wait for any in-flight handler to complete.
        // mem_queue_ is serial, so dispatch_sync guarantees the handler
        // has finished before we release the source and access `this`.
        dispatch_sync(mem_queue_, ^{});
        dispatch_release(mem_source_);
        mem_source_ = nullptr;
        dispatch_release(mem_queue_);
        mem_queue_ = nullptr;
    }
#endif

    if (listen_fd_ >= 0) {
        ::close(listen_fd_);
        listen_fd_ = -1;
    }

    if (!socket_path_.empty()) {
        std::string expanded = socket_path_;
        if (!expanded.empty() && expanded[0] == '~') {
            const char* home = ::getenv("HOME");
            if (home) expanded = std::string(home) + expanded.substr(1);
        }
        ::unlink(expanded.c_str());
    }

    remove_pid_file(pid_path_);
    socket_path_.clear();
    pid_path_.clear();
}

bool IpcServer::is_running() const {
    return running_.load(std::memory_order_acquire);
}

}
