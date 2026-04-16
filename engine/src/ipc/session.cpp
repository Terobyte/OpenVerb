#include "ipc/session.h"
#include "ipc/protocol.h"
#include "engine.h"
#include "config/interrupts.h"
#include "config/defaults.h"
#include "config/log.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <future>
#include <poll.h>
#include <string>
#include <unistd.h>
#include <vector>

namespace openverb {

const char* Session::state_name(State s) {
    switch (s) {
        case State::IDLE:            return "IDLE";
        case State::WAITING_READY:   return "WAITING_READY";
        case State::STREAMING_AUDIO: return "STREAMING_AUDIO";
        case State::INFERRING:       return "INFERRING";
        case State::SHUTDOWN:        return "SHUTDOWN";
        case State::DESTROYED:       return "DESTROYED";
    }
    return "UNKNOWN";
}

// ---------------------------------------------------------------------------
// ~Session — safety net: ensures the inference thread is always joined.
// Under normal operation run() joins inference_thread_ before returning, so
// this destructor is a no-op.  It fires only if run() exits via an uncaught
// exception while the thread is still alive.
// ---------------------------------------------------------------------------

Session::~Session() {
    stop();
}

// ---------------------------------------------------------------------------
// stop — signal abort and block until the inference thread exits.
// Idempotent: safe to call when no thread is running.
// ---------------------------------------------------------------------------

void Session::stop() {
    stop_requested_.store(true, std::memory_order_relaxed);
    result_cv_.notify_all();
    if (inference_thread_.joinable()) {
        inference_thread_.join();
    }
}

// ---------------------------------------------------------------------------
// handle_connection — static entry point; constructs a Session and delegates
// ---------------------------------------------------------------------------

void Session::handle_connection(int fd, Engine& engine, const SessionConfig& cfg) {
    Session s;
    s.run(fd, engine, cfg);
}

// ---------------------------------------------------------------------------
// run — full session state machine on the calling thread
// ---------------------------------------------------------------------------

void Session::run(int fd, Engine& engine, const SessionConfig& cfg) {
    RecvBuffer buf{};
    State state = State::IDLE;
    auto session_start    = std::chrono::steady_clock::now();
    auto last_frame_time  = std::chrono::steady_clock::now();
    bool first_frame_seen = false;

    // Compute max audio seconds allowed by context budget.
    // Clamp effective_ctx so the difference never goes negative (e.g. --ctx-size 100).
    const int effective_ctx = std::max(
        (cfg.ctx_size > 0) ? cfg.ctx_size : DEFAULT_CTX_SIZE,
        SYSTEM_PROMPT_TOKENS_RESERVED + 1);
    const double max_audio_secs =
        static_cast<double>(effective_ctx - SYSTEM_PROMPT_TOKENS_RESERVED)
        / static_cast<double>(AUDIO_TOKENS_PER_SEC);
    bool ctx_warning_sent = false;  // only send the approaching_context_limit once

    auto elapsed_secs = [](auto since) {
        return std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - since).count();
    };

    while (state != State::DESTROYED &&
           !g_interrupted.load(std::memory_order_relaxed)) {

        switch (state) {

        // ==================================================================
        case State::IDLE: {
            try {
                auto msg = recv_json(fd, buf, cfg.idle_timeout_secs * 1000);
                std::string type = msg.value("type", "");

                if (type == "session.start") {
                    // Extract caller-supplied context. The Swift client encodes
                    // context as a JSON object; fall back to a plain string for
                    // CLI / legacy callers that pass it pre-serialised.
                    if (msg.contains("context") && msg.at("context").is_object()) {
                        context_ = msg.at("context").dump();
                    } else {
                        context_ = msg.value("context", "");
                    }
                    state = State::WAITING_READY;
                    LOG_INFO("session: IDLE → WAITING_READY");
                } else if (type == "ping") {
                    send_json(fd, nlohmann::json{{"type", "pong"}});
                } else if (type == "session.shutdown") {
                    state = State::SHUTDOWN;
                }
            } catch (const ConnectionClosed&) {
                state = State::DESTROYED;
            } catch (const std::runtime_error& e) {
                if (std::string(e.what()) == "timeout") {
                    LOG_INFO("session: idle timeout");
                }
                state = State::DESTROYED;
            }
            break;
        }

        // ==================================================================
        case State::WAITING_READY: {
            // Run ensure_loaded() in a background thread so we can enforce
            // a hard deadline.  If the load does not complete within
            // load_timeout_secs the client receives a timeout error and the
            // session returns to IDLE.
            //
            // Note: if wait_for() returns timeout the future destructor will
            // block until ensure_loaded() eventually returns — this is
            // acceptable because the timeout case represents an abnormal
            // situation (load takes >30 s) and the process is degraded anyway.
            bool        load_ok  = false;
            bool        timed_out = false;
            std::string load_err;

            {
                std::promise<void> load_promise;
                auto load_future = load_promise.get_future();
                std::thread load_thread(
                    [&engine, p = std::move(load_promise)]() mutable {
                        try {
                            engine.ensure_loaded();
                            p.set_value();
                        } catch (...) {
                            p.set_exception(std::current_exception());
                        }
                    });

                auto status = load_future.wait_for(
                    std::chrono::seconds(cfg.load_timeout_secs));

                if (status != std::future_status::ready) {
                    timed_out = true;
                    LOG_WARN("session: model load timed out after %ds",
                             cfg.load_timeout_secs);
                    load_thread.join();  // block until done — prevents use-after-free on engine
                } else {
                    load_thread.join();
                    try {
                        load_future.get();
                        load_ok = true;
                    } catch (const std::exception& e) {
                        load_err = e.what();
                    } catch (...) {
                        load_err = "model load failed";
                    }
                }
            }

            if (timed_out) {
                send_error(fd, ErrorCode::timeout, "model load timeout");
                state = State::IDLE;
            } else if (!load_ok) {
                send_error(fd, ErrorCode::model_load_failed, load_err.c_str());
                state = State::IDLE;
            } else {
                send_json(fd, nlohmann::json{{"type", "session.ready"}});
                state             = State::STREAMING_AUDIO;
                session_start     = std::chrono::steady_clock::now();
                last_frame_time   = std::chrono::steady_clock::now();
                first_frame_seen  = false;
                ctx_warning_sent  = false;
                ring_buffer_.reset();
                LOG_INFO("session: WAITING_READY → STREAMING_AUDIO");
            }
            break;
        }

        // ==================================================================
        case State::STREAMING_AUDIO: {
            // Choose timeout: no-first-frame uses idle_timeout_secs (15s),
            // mid-stream stall uses stall_timeout_secs (30s).
            const int timeout_ms = first_frame_seen
                ? cfg.stall_timeout_secs * 1000
                : cfg.idle_timeout_secs * 1000;

            try {
                auto frame = recv_binary_frame(fd, buf, timeout_ms);
                last_frame_time = std::chrono::steady_clock::now();

                // --- Hard duration cap ---
                if (elapsed_secs(session_start) >= MAX_RECORDING_SECS) {
                    send_error(fd, ErrorCode::duration_exceeded,
                               "recording exceeded maximum duration");
                    ring_buffer_.reset();
                    // Drain in-flight binary frames until the client sends the
                    // sentinel (zero-length frame).  Without this, the client
                    // may still stream binary frames while the engine has
                    // already transitioned to IDLE (JSON mode), causing
                    // recv_json() to parse binary data as JSON → session destroyed.
                    try {
                        while (true) {
                            auto f = recv_binary_frame(fd, buf, 5000);
                            if (f.empty()) break;
                        }
                    } catch (...) {}
                    state = State::IDLE;
                    break;
                }

                // --- Zero-length sentinel: end of audio stream ---
                if (frame.empty()) {
                    LOG_INFO("session: sentinel received, bytes_available=%zu",
                             ring_buffer_.bytes_available());

                    if (ring_buffer_.bytes_available() == 0) {
                        // VAD-to-zero: no audio was received — skip inference
                        send_json(fd, nlohmann::json{
                            {"type", "result"}, {"text", ""}, {"command", nullptr}
                        });
                        state = State::IDLE;
                    } else {
                        // #27: clear any leftover binary bytes from the STREAMING_AUDIO
                        // phase before switching to INFERRING (JSON mode).  Without this,
                        // stale binary data in buf.accumulated is misinterpreted as JSON
                        // by recv_json(), causing spurious malformed_json errors.
                        buf.accumulated.clear();
                        state = State::INFERRING;
                    }
                    break;
                }

                first_frame_seen = true;

                // --- Write PCM frame to ring buffer ---
                {
                    size_t written = ring_buffer_.write(frame.data(), frame.size());
                    if (written < frame.size()) {
                        LOG_WARN("session: ring buffer full, dropped %zu bytes",
                                 frame.size() - written);
                    }
                }

                // --- Context limit checks ---
                const double dur = ring_buffer_.duration_secs();
                if (!ctx_warning_sent && dur >= max_audio_secs * 0.8) {
                    send_warning(fd, "approaching_context_limit",
                                 "recording approaching context window limit");
                    ctx_warning_sent = true;
                    LOG_INFO("session: approaching_context_limit at %.1fs", dur);
                }
                if (dur >= max_audio_secs) {
                    send_error(fd, ErrorCode::duration_exceeded,
                               "recording exceeded context window limit");
                    ring_buffer_.reset();
                    try {
                        while (true) {
                            auto f = recv_binary_frame(fd, buf, 5000);
                            if (f.empty()) break;
                        }
                    } catch (...) {}
                    state = State::IDLE;
                    break;
                }

            } catch (const ConnectionClosed&) {
                ring_buffer_.reset();
                state = State::DESTROYED;
            } catch (const std::runtime_error& e) {
                if (std::string(e.what()) == "timeout") {
                    send_error(fd, ErrorCode::timeout,
                               first_frame_seen ? "stream stall" : "no audio received");
                }
                ring_buffer_.reset();
                state = State::IDLE;
            }
            break;
        }

        // ==================================================================
        case State::INFERRING: {
            auto pcm = ring_buffer_.read_all();

            if (pcm.empty()) {
                // Shouldn't happen (guarded above), but handle gracefully.
                send_json(fd, nlohmann::json{
                    {"type", "result"}, {"text", ""}, {"command", nullptr}
                });
                ring_buffer_.reset();
                state = State::IDLE;
                break;
            }

            LOG_INFO("session: INFERRING %zu samples", pcm.size());

            try {
                stop_requested_.store(false, std::memory_order_relaxed);
                inference_result_.reset();
                inference_error_.clear();
                // Discard any stale progress from a previous inference that
                // was aborted; ensures a clean queue for each inference run.
                progress_queue_.drain();

                // #25: guard against assigning to a still-joinable thread.
                // Under normal operation the thread is always joined before we
                // re-enter INFERRING, but a cancelled/aborted prior inference
                // could leave it joinable.  Assigning to a joinable std::thread
                // calls std::terminate, so join defensively here.
                if (inference_thread_.joinable()) inference_thread_.join();

                // Launch inference on the class-owned thread.
                //   infer_cv_  — notified when the thread has started.
                //   result_cv_ — notified when the result (or failure) is ready.
                inference_thread_ = std::thread(
                    [this, pcm = std::move(pcm), &engine]() mutable {
                        try {
                            auto res = engine.process_stream(
                                pcm, SAMPLE_RATE, context_,
                                stop_requested_, progress_queue_);
                            {
                                std::lock_guard<std::mutex> lk(infer_mutex_);
                                inference_result_ = std::move(res);
                            }
                        } catch (const std::exception& e) {
                            LOG_WARN("session: inference exception: %s", e.what());
                            std::lock_guard<std::mutex> lk(infer_mutex_);
                            inference_error_ = e.what();
                            stop_requested_.store(true, std::memory_order_relaxed);
                        } catch (...) {
                            LOG_WARN("session: inference threw non-std exception");
                            std::lock_guard<std::mutex> lk(infer_mutex_);
                            inference_error_ = "non-std exception during inference";
                            stop_requested_.store(true, std::memory_order_relaxed);
                        }
                        result_cv_.notify_one();
                    });

                auto infer_start = std::chrono::steady_clock::now();
                auto last_client_msg_tp = std::chrono::steady_clock::now();
                bool infer_done  = false;

                while (!infer_done &&
                       state == State::INFERRING &&
                       !g_interrupted.load(std::memory_order_relaxed)) {

                    // Wait up to 100 ms for the result to become available.
                    {
                        std::unique_lock<std::mutex> lk(infer_mutex_);
                        infer_done = result_cv_.wait_for(
                            lk, std::chrono::milliseconds(100),
                            [this] {
                                return inference_result_.has_value() ||
                                       stop_requested_.load(std::memory_order_relaxed);
                            });
                    }

                    if (infer_done) break;

                    if (g_interrupted.load(std::memory_order_relaxed)) {
                        stop_requested_.store(true, std::memory_order_relaxed);
                        break;
                    }

                    // Drain and forward progress updates.
                    auto progresses = progress_queue_.drain();
                    for (float pct : progresses) {
                        try {
                            send_json(fd, nlohmann::json{
                                {"type", "progress"}, {"percent", pct}
                            });
                            last_client_msg_tp = std::chrono::steady_clock::now();
                        } catch (const ConnectionClosed&) {
                            stop_requested_.store(true, std::memory_order_relaxed);
                            break;
                        }
                    }

                    // Heartbeat: during the audio-encoding phase the model produces
                    // no progress updates (generation hasn't started yet).  Without a
                    // periodic message the Swift client times out after 30 s.  Send a
                    // synthetic 0 % progress every 5 s to keep the connection alive.
                    if (progresses.empty()) {
                        auto silent_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now() - last_client_msg_tp).count();
                        if (silent_ms >= 5000) {
                            try {
                                send_json(fd, nlohmann::json{
                                    {"type", "progress"}, {"percent", 0.0f}
                                });
                                last_client_msg_tp = std::chrono::steady_clock::now();
                            } catch (const ConnectionClosed&) {
                                stop_requested_.store(true, std::memory_order_relaxed);
                                break;
                            }
                        }
                    }

                    // Inference timeout.
                    if (elapsed_secs(infer_start) >= cfg.inference_timeout_secs) {
                        stop_requested_.store(true, std::memory_order_relaxed);
                        if (inference_thread_.joinable()) inference_thread_.join();
                        send_error(fd, ErrorCode::timeout, "inference timeout");
                        ring_buffer_.reset();
                        state = State::IDLE;
                        break;
                    }

                    // Poll socket for client commands during inference.
                    struct pollfd cpfd{};
                    cpfd.fd     = fd;
                    cpfd.events = POLLIN;
                    if (::poll(&cpfd, 1, 0) > 0 && (cpfd.revents & POLLIN)) {
                        try {
                            auto msg  = recv_json(fd, buf, 1000);
                            auto type = msg.value("type", std::string{});

                            if (type == "session.start") {
                                stop_requested_.store(true, std::memory_order_relaxed);
                                if (inference_thread_.joinable()) inference_thread_.join();
                                // Discard any values pushed by the backend after the
                                // abort flag was set but before join() returned.
                                // Without this drain, stale progress leaks into the
                                // next session's inference stream.
                                progress_queue_.drain();
                                ring_buffer_.reset();
                                // Update context from the new session.start message.
                                if (msg.contains("context") && msg.at("context").is_object()) {
                                    context_ = msg.at("context").dump();
                                } else {
                                    context_ = msg.value("context", "");
                                }
                                state = State::WAITING_READY;
                                break;
                            } else if (type == "session.shutdown") {
                                stop_requested_.store(true, std::memory_order_relaxed);
                                if (inference_thread_.joinable()) inference_thread_.join();
                                ring_buffer_.reset();
                                state = State::SHUTDOWN;
                                break;
                            }
                        } catch (const ConnectionClosed&) {
                            // Client disconnected mid-inference — abort so we
                            // don't burn CPU/GPU for a dead connection.
                            stop_requested_.store(true, std::memory_order_relaxed);
                            if (inference_thread_.joinable()) inference_thread_.join();
                            ring_buffer_.reset();
                            state = State::DESTROYED;
                            break;
                        } catch (...) {}
                    }
                }

                // Ensure the inference thread is joined in all paths.
                if (inference_thread_.joinable()) {
                    inference_thread_.join();
                }

                if (state == State::INFERRING) {
                    // Drain any remaining progress.
                    for (float pct : progress_queue_.drain()) {
                        try {
                            send_json(fd, nlohmann::json{
                                {"type", "progress"}, {"percent", pct}
                            });
                        } catch (const ConnectionClosed&) {
                            stop_requested_.store(true, std::memory_order_relaxed);
                            break;
                        }
                    }

                    if (!inference_result_.has_value()) {
                        const char* err_msg = inference_error_.empty()
                            ? "inference produced no result"
                            : inference_error_.c_str();
                        send_error(fd, ErrorCode::inference_failed, err_msg);
                    } else {
                        const auto& result = *inference_result_;
                        nlohmann::json result_msg;
                        result_msg["type"]              = "result";
                        result_msg["text"]              = result.text;
                        result_msg["inference_time_ms"] = result.inference_time_ms;
                        // command is null when empty, or a structured object
                        if (result.command.empty()) {
                            result_msg["command"] = nullptr;
                        } else {
                            result_msg["command"] = nlohmann::json{{"action", result.command}};
                        }
                        send_json(fd, result_msg);
                        LOG_INFO("session: inference complete → IDLE");
                    }

                    ring_buffer_.reset();
                    state = State::IDLE;
                }
            } catch (const std::exception& e) {
                // Abort and join before error-handling to avoid a dangling thread.
                stop_requested_.store(true, std::memory_order_relaxed);
                result_cv_.notify_all();
                if (inference_thread_.joinable()) inference_thread_.join();
                send_error(fd, ErrorCode::inference_failed, e.what());
                ring_buffer_.reset();
                state = State::IDLE;
            }
            break;
        }

        // ==================================================================
        case State::SHUTDOWN: {
            LOG_INFO("session: SHUTDOWN → DESTROYED");
            state = State::DESTROYED;
            break;
        }

        case State::DESTROYED:
            break;
        }
    }

    LOG_INFO("session: connection ended in state %s", state_name(state));
}

}
