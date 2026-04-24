#include "ipc/session.h"
#include "ipc/protocol.h"
#include "context/context.h"
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
        case State::SHUTDOWN:        return "SHUTDOWN";
        case State::DESTROYED:       return "DESTROYED";
    }
    return "UNKNOWN";
}

// ---------------------------------------------------------------------------
// ~Session — safety net: ensures threads are signalled before destruction.
// Under normal operation run() joins all threads before returning, so this
// destructor is a no-op.  It fires only if run() exits via an uncaught
// exception.
// ---------------------------------------------------------------------------

Session::~Session() {
    stop();
}

// ---------------------------------------------------------------------------
// stop — signal abort and wake any waiters.
// Worker/inference thread joining is handled inline in run() paths; this
// method only signals so threads can exit on their own schedules.
// ---------------------------------------------------------------------------

void Session::stop() {
    stop_requested_.store(true, std::memory_order_release);
    pipeline_active_.store(false, std::memory_order_release);
    chunk_queue_.shutdown();
    result_cv_.notify_all();
    if (worker_thread_.joinable()) worker_thread_.join();
}

// ---------------------------------------------------------------------------
// handle_connection — static entry point; constructs a Session and delegates
// ---------------------------------------------------------------------------

void Session::handle_connection(int fd, Engine& engine, const SessionConfig& cfg) {
    Session s;
    s.run(fd, engine, cfg);
}

// ---------------------------------------------------------------------------
// run_inference_worker_ — background thread: pop chunks, infer, emit partials.
//
// Runs concurrently with the STREAMING_AUDIO receive loop.  Exits when:
//   • a Chunk with is_final=true is processed, or
//   • pipeline_active_ is false (shutdown / error), or
//   • chunk_queue_ is shut down (ConnectionClosed path).
//
// Stores the accumulated transcript in inference_result_ under infer_mutex_
// and notifies result_cv_ so the STREAMING_AUDIO sentinel handler can read it.
// ---------------------------------------------------------------------------

void Session::run_inference_worker_(int fd, Engine& engine) {
    std::string accumulated;
    auto heartbeat_tp = std::chrono::steady_clock::now();

    // Loop until the queue is drained (pop returns nullopt after shutdown) or
    // the is_final chunk has been processed.  We do NOT check pipeline_active_
    // here because the sentinel handler sets it false *before* joining — if the
    // worker had already started processing chunk N-1, it must still pop and
    // process the is_final chunk N that flush() pushed to the queue.
    // On connection drop: shutdown() causes pop() to return nullopt once the
    // queue is empty, so the worker exits naturally without an explicit flag check.
    while (true) {
        auto chunk_opt = chunk_queue_.pop();
        if (!chunk_opt) break;  // queue shut down and empty

        const Chunk& chunk = *chunk_opt;

        // Run inference on this chunk.
        InferenceResult partial;
        try {
            partial = engine.process_stream(
                chunk.pcm, SAMPLE_RATE, context_,
                stop_requested_, progress_queue_);
        } catch (const std::exception& e) {
            LOG_WARN("session: worker inference error: %s", e.what());
            stop_requested_.store(true, std::memory_order_release);
            break;
        } catch (...) {
            LOG_WARN("session: worker inference non-std exception");
            stop_requested_.store(true, std::memory_order_release);
            break;
        }

        if (!partial.text.empty()) {
            accumulated += partial.text;
        }

        // Emit partial result to the client.
        try {
            LOG_WARN("[diag] session: emit partial_result chunk_id=%d is_final=%d text_len=%zu",
                     chunk.id, chunk.is_final ? 1 : 0, partial.text.size());
            send_partial_result(fd, chunk.id, partial.text, chunk.is_final);
        } catch (...) {
            // Connection closed mid-stream — exit worker quietly.
            break;
        }

        // Update EWMA inference-speed estimate.
        if (chunk.duration_ms > 0) {
            double observed = static_cast<double>(partial.inference_time_ms)
                            / static_cast<double>(chunk.duration_ms);
            infer_speed_ewma_ = INFER_SPEED_EWMA_ALPHA * observed
                              + (1.0 - INFER_SPEED_EWMA_ALPHA) * infer_speed_ewma_;
        }

        // Periodic queue-status heartbeat.
        auto now = std::chrono::steady_clock::now();
        auto elapsed_hb = std::chrono::duration_cast<std::chrono::milliseconds>(
                              now - heartbeat_tp).count();
        if (elapsed_hb >= QUEUE_STATUS_HEARTBEAT_MS) {
            int pending = chunk_queue_.depth();
            int eta_ms  = static_cast<int>(
                static_cast<double>(chunk_queue_.queued_audio_ms()) * infer_speed_ewma_);
            try {
                send_queue_status(fd, pending, 1, eta_ms);
            } catch (...) {
                break;
            }
            heartbeat_tp = now;
        }

        if (chunk.is_final) break;
    }

    // Store accumulated transcript for the sentinel handler to read.
    {
        std::lock_guard<std::mutex> lk(infer_mutex_);
        inference_result_ = InferenceResult{accumulated, "", 0};
    }
    result_cv_.notify_one();
}

// ---------------------------------------------------------------------------
// run — full session state machine on the calling thread
// ---------------------------------------------------------------------------

void Session::run(int fd, Engine& engine, const SessionConfig& cfg) {
    engine_ptr_ = &engine;
    RecvBuffer buf{};
    State state = State::IDLE;
    bool first_frame_seen = false;
    bool connection_alive = true;

    auto elapsed_secs = [](auto since) {
        return std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - since).count();
    };

    while (state != State::DESTROYED &&
           !stop_requested_.load(std::memory_order_acquire)) {

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
                connection_alive = false;
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
                    load_thread.detach();  // detach so the session is not blocked indefinitely
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
                state            = State::STREAMING_AUDIO;
                buf.accumulated.clear();
                first_frame_seen = false;
                // Initialise streaming pipeline.
                chunk_queue_.reset();
                infer_speed_ewma_ = DEFAULT_CHUNK_INFER_SPEED;
                pipeline_active_.store(true, std::memory_order_release);
                stop_requested_.store(false, std::memory_order_relaxed);
                inference_result_.reset();
                progress_queue_.drain();
                // Fresh session: drop any PCM carried over from a previous run.
                full_pcm_buffer_.clear();
                // VadScanner with callback that pushes completed chunks to the queue.
                chunker_.emplace([this](Chunk c) {
                    if (pipeline_active_.load(std::memory_order_acquire)) {
                        chunk_queue_.push(c);
                    }
                });
                // Launch the inference worker.
                worker_thread_ = std::thread(
                    [this, fd]() { run_inference_worker_(fd, *engine_ptr_); });
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

                // --- Zero-length sentinel: end of audio stream ---
                if (frame.empty()) {
                    LOG_INFO("session: sentinel received");
                    // Flush final chunk (is_final=true) into the worker queue,
                    // then shut down the queue so the worker can always unblock
                    // (even when no speech was detected and flush() emits nothing).
                    if (chunker_) {
                        chunker_->flush();
                    }
                    pipeline_active_.store(false, std::memory_order_release);
                    chunk_queue_.shutdown();
                    if (worker_thread_.joinable()) worker_thread_.join();

                    // Worker's per-chunk accumulated text is used only as a
                    // speech-detected gate: if the worker produced nothing,
                    // VAD saw no speech (or connection dropped) and the
                    // full-buffer re-inference below is skipped.  The final
                    // transcript itself comes from that re-inference, not
                    // from the worker's per-chunk concatenation (which
                    // hallucinates completions on each mid-word boundary).
                    std::optional<InferenceResult> worker_result;
                    {
                        std::lock_guard<std::mutex> lk(infer_mutex_);
                        worker_result = std::move(inference_result_);
                    }
                    const bool worker_had_text =
                        worker_result && !worker_result->text.empty();
                    chunker_.reset();
                    // #27: clear stale binary bytes before returning to JSON mode.
                    buf.accumulated.clear();

                    // Run one coherent inference on the full PCM buffer.  Skip
                    // when no audio was captured (empty session), when VAD
                    // didn't detect speech (worker produced no text), or when
                    // the connection/abort flag tells us to bail.
                    std::string raw_text;
                    if (worker_had_text &&
                        !full_pcm_buffer_.empty() &&
                        connection_alive &&
                        !stop_requested_.load(std::memory_order_relaxed)) {
                        try {
                            InferenceResult final_result = engine.process_stream(
                                full_pcm_buffer_, SAMPLE_RATE, context_,
                                stop_requested_, progress_queue_);
                            raw_text = std::move(final_result.text);
                        } catch (const std::exception& e) {
                            LOG_WARN("session: final full-buffer inference error: %s", e.what());
                        } catch (...) {
                            LOG_WARN("session: final full-buffer inference non-std exception");
                        }
                    }
                    full_pcm_buffer_.clear();

                    if (raw_text.empty()) {
                        send_json(fd, nlohmann::json{
                            {"type", "result"}, {"text", ""}, {"command", nullptr}
                        });
                    } else {
                        // --- Polish pass: LLM cleanup of the final transcript ---
                        openverb::Context ctx;
                        try {
                            ctx = openverb::Context::from_json(context_);
                        } catch (...) {
                            // Malformed context — proceed without surrounding text.
                        }

                        std::string final_text = raw_text;
                        if (connection_alive &&
                            !stop_requested_.load(std::memory_order_relaxed)) {
                            try {
                                send_polish_started(fd);
                                final_text = engine.polish_text(raw_text, ctx);
                                send_polished_result(fd, final_text);
                            } catch (...) {
                                // Polish failure is non-fatal; send the raw transcript.
                            }
                        }

                        nlohmann::json msg;
                        msg["type"]    = "result";
                        msg["text"]    = final_text;
                        msg["command"] = nullptr;
                        send_json(fd, msg);
                    }
                    LOG_INFO("session: streaming inference complete → IDLE");
                    state = State::IDLE;
                    break;
                }

                first_frame_seen = true;

                // --- Feed PCM frame to VadScanner ---
                if (chunker_) {
                    // Guard: frame must have an even byte count for int16_t samples.
                    // An odd byte count means the last byte is incomplete; drop it.
                    if (frame.size() % 2 != 0) {
                        LOG_WARN("session: odd PCM frame size %zu — dropping last byte",
                                 frame.size());
                    }
                    const size_t n_bytes = frame.size() & ~size_t(1);  // round down to even
                    // Use memcpy into an aligned std::vector<int16_t> rather than a raw
                    // reinterpret_cast<const int16_t*> to guarantee alignment (UB on unaligned).
                    std::vector<int16_t> samples_buf(n_bytes / sizeof(int16_t));
                    std::memcpy(samples_buf.data(), frame.data(), n_bytes);
                    int n_samples = static_cast<int>(samples_buf.size());
                    chunker_->push_frame(samples_buf.data(), n_samples);
                    // Accumulate full-session PCM for the final coherent inference
                    // run by the sentinel handler (see end-of-audio branch below).
                    full_pcm_buffer_.insert(full_pcm_buffer_.end(),
                                            samples_buf.begin(), samples_buf.end());
                }

            } catch (const ConnectionClosed&) {
                // Client dropped — clean up the pipeline.
                connection_alive = false;
                stop_requested_.store(true, std::memory_order_release);
                pipeline_active_.store(false, std::memory_order_release);
                chunk_queue_.shutdown();
                if (worker_thread_.joinable()) worker_thread_.join();
                chunker_.reset();
                state = State::DESTROYED;
            } catch (const std::runtime_error& e) {
                if (std::string(e.what()) == "timeout") {
                    send_error(fd, ErrorCode::timeout,
                               first_frame_seen ? "stream stall" : "no audio received");
                }
                stop_requested_.store(true, std::memory_order_release);
                pipeline_active_.store(false, std::memory_order_release);
                chunk_queue_.shutdown();
                if (worker_thread_.joinable()) worker_thread_.join();
                chunker_.reset();
                state = State::SHUTDOWN;
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
