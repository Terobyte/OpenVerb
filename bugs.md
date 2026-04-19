# OpenVerb Bug Tracker

## C++ Engine — Open Bugs

### C8 — `unload_model()` doesn't null `backend_`; stale `shared_ptr` copy races with model unload

- **File:** `engine/src/engine.cpp:142-148`
- **Category:** Race condition (latent)
- **Severity:** Medium — currently mitigated by caller discipline (`unload_model()` only called when `session_active_` is false)
- **Status:** Open — negative test: `testBugC8_unloadModelDoesNotNullBackend`

`unload_model()` calls `backend_->unload_model()` (which resets the internal `llama_` context) and sets `loaded_ = false`, but leaves `backend_` pointing to the now-hollow Backend object. Any `process_stream()` or `process_file()` call that already grabbed a `shared_ptr<Backend>` copy under `engine_mutex_` and released the lock will call into a Backend whose `llama_` is null:

```
Worker thread:                         Poll loop / GCD handler:
  lock(engine_mutex_)
  be = backend_           ← copy shared_ptr
  unlock(engine_mutex_)
                                        lock(engine_mutex_)
                                        backend_->unload_model()  ← resets llama_ inside Backend
                                        loaded_ = false
                                        unlock(engine_mutex_)
  be->process_stream(...) ← Backend alive (refcount) but llama_ is null → crash
```

Currently safe because all `unload_model()` call sites (GCD CRITICAL handler, idle timeout, WARN force-unload) check `session_active_` before calling. But `Engine` doesn't enforce this — one refactoring that breaks the caller contract causes a crash.

**Fix:** Either null `backend_` in `unload_model()` so stale copies see a dead pointer immediately, or add an abort check inside the Backend's `process_stream`/`process_file` methods.

---

### C9 — Ring buffer `write()` silently drops audio data when full

- **File:** `engine/src/audio/ring_buffer.cpp:6-25`
- **Category:** Silent data loss
- **Severity:** Low — only affects `--mic` mode; IPC streaming path doesn't use RingBuffer
- **Status:** Open — negative test: `testBugC9_ringBufferWriteSilentlyDropsData`

When the producer (audio capture) writes faster than the consumer can drain, `write()` silently returns 0 and discards data. No backpressure signal, no error flag — the transcriber silently receives incomplete audio. The caller in `main.cpp:178-180` logs a warning but proceeds with partial data.

---

### H1 — `stop_requested_` uses `memory_order_relaxed`; worker may delay seeing abort signal

- **File:** `engine/src/ipc/session.cpp:49,102`
- **Category:** Delayed visibility
- **Severity:** Low — worker processes 1-2 extra tokens before noticing; harmless in practice
- **Status:** Open — negative test: `testBugH1_stopRequestedStoreUsesRelaxedOrdering`

`stop_requested_` is a `std::atomic<bool>` accessed with `memory_order_relaxed`. The worker thread reads it in the inference loop; the main thread writes it in `stop()` and error handlers. Relaxed ordering doesn't guarantee the worker sees the store promptly — on weakly-ordered architectures (ARM, which Apple Silicon is), the worker may continue for extra iterations before the store becomes visible.

**Fix:** Use `memory_order_release` for stores and `memory_order_acquire` for loads, or simply `memory_order_seq_cst`.

---

### C1 — Worker thread captures `Engine&` by reference; dangling reference if IpcServer outlives scope

- **File:** `engine/src/ipc/session.cpp` — `worker_thread_` lambda
- **Category:** Use-after-free (latent)
- **Severity:** Medium — `~Session()` calls `stop() → join()` which normally prevents the dangle, but exceptions in adjacent paths can break the ordering
- **Status:** Open — negative test: `testBugC1_workerThreadCapturesEngineByReference`

`worker_thread_` lambda uses `[this, fd, &engine]`. Capturing `engine` (an `Engine&` parameter) by lvalue reference means the worker thread holds a raw alias into the `IpcServer`'s `engine_` member. If the `IpcServer` is destroyed before the worker thread exits, the reference dangles.

**Fix:** Pass engine by value (requires Engine to be movable) or introduce a `std::shared_ptr<Engine>` so the worker captures shared ownership.

---

### C2 — Session thread captures raw `this`; use-after-free if IpcServer destroyed mid-session

- **File:** `engine/src/ipc/server.cpp` — `session_thread_` lambda
- **Category:** Use-after-free (latent)
- **Severity:** High — if `stop()` is never called (e.g., `start()` throws after thread launch), destructor skips join and the thread outlives the `IpcServer` object
- **Status:** Open — negative test: `testBugC2_sessionThreadCapturesIpcServerThisDirectly`

`session_thread_` lambda uses `[this, client_fd, now_sec]`. All accesses to `engine_`, `session_active_`, `pressure_critical_active_`, and `LOG_*` inside the lambda go through the captured raw `this`. `IpcServer::stop()` joins `session_thread_` before the destructor completes, which normally prevents dangling use — but exceptional paths break this guarantee.

**Fix:** Make `IpcServer` inherit from `std::enable_shared_from_this<IpcServer>` and capture `auto self = shared_from_this()` in the lambda, or use a `std::weak_ptr` with a lock guard.

---

### H6 — VadScanner has no synchronization; data race between audio thread and session thread

- **File:** `engine/src/audio/vad_scanner.cpp`
- **Category:** Data race (undefined behaviour)
- **Severity:** High — `push_frame()` called from CoreAudio real-time thread; `flush()`/`reset()` from session main thread; concurrent access to `buffer_ms_`, `silence_ms_`, `in_speech_`, `buffer_`
- **Status:** Open — negative test: `testBugH6_vadScannerHasNoSynchronization`

`vad_scanner.cpp` has no mutex or atomic protection. `push_frame()` is called from the CoreAudio real-time thread; `flush()` and `reset()` are called from the session main thread. `buffer_.insert()` is not thread-safe — concurrent access can produce incorrect VAD boundaries or memory corruption. Detected by TSan.

**Fix:** Add `std::mutex mu_` to `VadScanner` and acquire it at the top of `push_frame()`, `flush()`, and `reset()`.

---

### H7 — ChunkQueue::reset() doesn't notify waiting threads; lost-wakeup hang

- **File:** `engine/src/audio/chunk_queue.cpp`
- **Category:** Lost wakeup / hang
- **Severity:** High — manifests on rapid abort-and-restart (Escape during active inference)
- **Status:** Open — negative test: `testBugH7_chunkQueueResetMissingNotify`

`shutdown()` sets `shut_=true` and calls `notify_all()`. A thread waking in `pop()` re-checks `!queue_.empty() || shut_`. If `reset()` runs between the notify and the re-check, setting `shut_=false`, the thread sees both conditions false and re-waits with no pending notification — hangs indefinitely. No subsequent push arrives in the abort-and-restart scenario, so the worker thread never processes the sentinel chunk.

**Fix:** Add `not_empty_.notify_all(); not_full_.notify_all();` at the end of `reset()`.

---

### 53 — Server joins previous session thread without signalling stop; blocks new client up to 15s

- **File:** `engine/src/ipc/server.cpp`
- **Category:** Blocking / latency
- **Severity:** Medium — mitigated by Bugs 49+52 fixes (client always disconnects on error), so the old session exits in <1ms via `ConnectionClosed`; defense-in-depth C++ signal deferred
- **Status:** Deferred (unreachable after Bugs 49+52 fixed) — negative test: `testBug53_serverJoinWithoutSignallingPreviousSession`

`server.cpp` calls `session_thread_.join()` after `accept()` without signalling the previous session to stop. Under Bug 49/52 conditions (client left old fd open), the prior session polls for up to `idle_timeout_secs` (15 s) before exiting, blocking the new client. The kernel accepts the new fd but the server is stuck in `join()`.

**Fix:** Before `session_thread_.join()`, signal the previous session via `g_interrupted`, a per-session stop flag, or close the old client fd.

---

### NEW-1 — `buf.accumulated` not cleared before JSON→binary mode transition; stale bytes corrupt framing

- **File:** `engine/src/ipc/session.cpp:267`
- **Category:** Protocol fragility
- **Severity:** Medium — only triggered by misbehaving/proxying clients; current Swift client is safe
- **Status:** Open — negative test: `testBugNEW1_accumulatedNotClearedBeforeBinaryMode`

When the session transitions from WAITING_READY (JSON mode) to STREAMING_AUDIO (binary mode), `RecvBuffer::accumulated` is not cleared. If the client pipelined data (sent binary frames before receiving `session.ready`), leftover bytes from JSON parsing would be interpreted as a binary frame header by `recv_binary_frame()`, causing bogus frame lengths or `frame too large` errors.

The reverse transition (STREAMING_AUDIO → IDLE) correctly clears at session.cpp:321.

**Fix:** Add `buf.accumulated.clear()` at session.cpp:268, before the streaming pipeline is initialized:

```cpp
state            = State::STREAMING_AUDIO;
buf.accumulated.clear();  // prevent stale JSON bytes corrupting binary frames
first_frame_seen = false;
```

---

## Swift / macOS — Open Bugs

### 62 — `injectPerCharacter` sets modifier flags on key-down but not key-up; Shift sticks

- **File:** `app/OpenVerb/Output/TextInjector.swift` — `injectPerCharacter()`, lines 189-194
- **Category:** CGEvent protocol violation
- **Severity:** High — uppercase characters leave the Shift modifier logically pressed in the system event stream
- **Status:** Open — negative test: `testBug62_perCharacterInjectionMissingFlagsOnKeyUp`

`injectPerCharacter` calls `keyCodeAndFlags(for:)` to retrieve a `(CGKeyCode, CGEventFlags)` pair and correctly sets `down.flags = flags` on the key-down event. However, the key-up event is posted **without** applying the same flags:

```swift
if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
    if flags != CGEventFlags(rawValue: 0) { down.flags = flags }
    down.post(tap: .cghidEventTap)
}
if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
    up.post(tap: .cghidEventTap)   // ← flags never applied
}
```

Per the CGEvent contract, a key-up must carry the same modifier flags as its paired key-down. When `.maskShift` is absent on the key-up, the HID event tap sees a mismatched pair and leaves the Shift modifier in a logically-pressed state, corrupting all subsequent keystrokes until the user physically taps Shift.

**Fix:** Mirror the down-event guard: `if flags != CGEventFlags(rawValue: 0) { up.flags = flags }` before `up.post(...)`.

---

### 63 — `ModelDownloader.download()` has no re-entrance guard; concurrent call silently cancels the in-flight download

- **File:** `app/OpenVerb/Model/ModelDownloader.swift` — `download()`, lines 81-105
- **Category:** State machine violation / silent data loss
- **Severity:** Medium — progress and resume data from the first download are silently discarded
- **Status:** Open — negative test: `testBug63_downloadHasNoReentranceGuard`

`download()` begins by calling `session?.invalidateAndCancel()` (line 90) unconditionally — before checking whether a download is already in progress. A concurrent or rapid second call therefore cancels the first URLSession (and its in-flight download task) and starts fresh, with no error or notification to the caller. `isDownloading` is set to `true` for both calls, making the race invisible to observers.

**Fix:** Guard the function body: `guard !isDownloading else { return }` (or `throw`) immediately after entering.

---

### 64 — `ModelDownloader` removes destination file before moving temp file; crash between the two ops loses the downloaded model

- **File:** `app/OpenVerb/Model/ModelDownloader.swift` — `urlSession(_:downloadTask:didFinishDownloadingTo:)`, lines 212-215
- **Category:** Non-atomic file operation / data loss
- **Severity:** Medium — process kill or I/O error between removeItem and moveItem leaves the user with no model and must re-download
- **Status:** Open — negative test: `testBug64_nonAtomicRemoveBeforeMove`

The finish-download delegate first removes any existing destination file and then moves the URLSession temp file:

```swift
if FileManager.default.fileExists(atPath: destinationURL.path) {
    try FileManager.default.removeItem(at: destinationURL)   // step 1
}
try FileManager.default.moveItem(at: location, to: destinationURL) // step 2
```

If the process is killed, crashes, or encounters a permissions error between step 1 and step 2, the old model is gone and the new one was never written. `moveItem` is also not atomic across volume boundaries (it falls back to copy + delete internally).

**Fix:** Use `replaceItemAt(_:withItemAt:backupItemName:options:)` which is atomic within the same volume, or move to a sibling temp path first and then rename.

---

### 65 — `VadScanner::flush()` emits chunks without enforcing `MIN_CHUNK_MS`; short utterances reach the inference engine

- **File:** `engine/src/audio/vad_scanner.cpp` — `flush()`, lines 32-38
- **Category:** Logic / inconsistent validation
- **Severity:** Medium — sub-minimum utterances (< MIN_CHUNK_MS = 3 s) sent as final chunks produce empty or low-quality transcripts
- **Status:** Open — negative test: `testBug65_flushBypasesMinChunkMs`

`push_frame()` enforces `MIN_CHUNK_MS` at the silence-boundary path (line 25):

```cpp
if (buffer_ms_ - silence_ms_ >= MIN_CHUNK_MS) {
    maybe_emit_chunk(false);
```

`flush()` does not:

```cpp
void VadScanner::flush() {
    if (!buffer_.empty() && in_speech_) {
        maybe_emit_chunk(true);   // ← no MIN_CHUNK_MS check
    }
```

Any utterance that ends before the silence boundary fires (e.g., a user presses stop after 0.5 s) is emitted as `is_final=true` regardless of duration, bypassing the filter that prevents noise/breath bursts from reaching the backend.

**Fix:** Add the same guard: `if (!buffer_.empty() && in_speech_ && (buffer_ms_ - silence_ms_ >= MIN_CHUNK_MS))`.

---

### 66 — `AudioSession.processTapBuffer()` calls `waveformCallback` on the audio tap thread; updates `@Published` off the main thread

- **File:** `app/OpenVerb/Input/AudioSession.swift` — `processTapBuffer()`, line 311
- **Category:** Threading / SwiftUI concurrency
- **Severity:** Medium — unsynchronised mutation of `@Published var amplitudes` from audio thread races with SwiftUI rendering
- **Status:** Open — negative test: `testBug66_waveformCallbackCalledOnAudioThread`

`installTap(onBus:bufferSize:format:)` fires its callback on a real-time audio thread. `processTapBuffer` releases the lock and then calls `waveformCallback` inline:

```swift
for chunk in chunksToDisplay {
    waveformCallback(chunk)   // ← audio thread, not main thread
}
```

The caller in `OpenVerbApp` passes `{ [weak self] chunk in self?.waveformVM.updateAmplitude(chunk) }`, which mutates `@Published var amplitudes` directly on the audio thread. SwiftUI requires `@Published` mutations to happen on the main thread; violating this causes undefined rendering behaviour and Swift concurrency warnings.

**Fix:** Dispatch inside `processTapBuffer` before the callback loop: `DispatchQueue.main.async { waveformCallback(chunk) }`, or document that all `waveformCallback` implementations must dispatch themselves.
