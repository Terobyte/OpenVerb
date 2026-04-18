# OpenVerb Bug Tracker

## Active Bugs

### Bug 60 — STREAMING_AUDIO cleanup paths missing `stop_requested_` before `join()` — session thread blocks for full inference duration on disconnect
- **File:** `engine/src/ipc/session.cpp` — `ConnectionClosed` catch (~line 368) and `std::runtime_error` catch (~line 375)
- **Severity:** High — primary cause of long "Reconnecting..." spinner after abort-and-restart
- **Status:** Open
- **Negative test:** `testBug60_streamingCleanupMissingStopRequested` — fails while `stop_requested_` is absent before `join()` in STREAMING_AUDIO catch blocks

Both cleanup catch blocks inside `STREAMING_AUDIO` call `worker_thread_.join()` without first setting `stop_requested_ = true`:

```cpp
} catch (const ConnectionClosed&) {
    pipeline_active_.store(false, std::memory_order_relaxed);
    chunk_queue_.shutdown();
    if (worker_thread_.joinable()) worker_thread_.join();  // ← blocks full chunk
    chunker_.reset();
    state = State::DESTROYED;
} catch (const std::runtime_error& e) {
    // ...
    pipeline_active_.store(false, std::memory_order_relaxed);
    chunk_queue_.shutdown();
    if (worker_thread_.joinable()) worker_thread_.join();  // ← blocks full chunk
    chunker_.reset();
    state = State::IDLE;
}
```

The worker thread's inference loop checks `abort_flag = &stop_requested_` at every token decode step. Without setting `stop_requested_ = true`, it runs the current chunk's inference to completion before `join()` returns — 1–30 seconds for a Gemma 4 chunk.

Contrast: `Session::stop()` already does this correctly:

```cpp
void Session::stop() {
    stop_requested_.store(true, std::memory_order_relaxed);  // ← present here
    pipeline_active_.store(false, std::memory_order_relaxed);
    chunk_queue_.shutdown();
    result_cv_.notify_all();
    if (worker_thread_.joinable()) worker_thread_.join();
}
```

Impact chain: on `abortAndRestart()`, Swift calls `disconnect()` → engine sees `ConnectionClosed` → `join()` blocks until inference completes → `server.cpp`'s `session_thread_.join()` in its accept loop also blocks → Swift's `ensureRunning()` connects a new socket but `accept()` is not called until the join finishes → `tryPing()` times out → full engine restart (5 s model reload). User sees "Reconnecting..." for 5–30 s instead of < 1 s.

**Fix:** Add `stop_requested_.store(true, std::memory_order_relaxed)` before `join()` in both catch blocks, identical to what `stop()` already does:

```cpp
} catch (const ConnectionClosed&) {
    stop_requested_.store(true, std::memory_order_relaxed);  // ← add
    pipeline_active_.store(false, std::memory_order_relaxed);
    chunk_queue_.shutdown();
    if (worker_thread_.joinable()) worker_thread_.join();
    chunker_.reset();
    state = State::DESTROYED;
} catch (const std::runtime_error& e) {
    if (std::string(e.what()) == "timeout") {
        send_error(fd, ErrorCode::timeout,
                   first_frame_seen ? "stream stall" : "no audio received");
    }
    stop_requested_.store(true, std::memory_order_relaxed);  // ← add
    pipeline_active_.store(false, std::memory_order_relaxed);
    chunk_queue_.shutdown();
    if (worker_thread_.joinable()) worker_thread_.join();
    chunker_.reset();
    state = State::IDLE;
}
```
