# OpenVerb Bug Tracker

## Active Bugs

### Bug 1 — `WaveformViewModel.reset()` async when it should be sync
- **File:** `app/OpenVerb/UI/WaveformView.swift:44-48`
- **Severity:** High
- **Status:** Fixed

Removed `DispatchQueue.main.async` wrapper; `amplitudes.removeAll()` now called directly on `@MainActor`.

---

### Bug 2 — Phase 2 monitor race with `drainResult()`: two threads reading one fd
- **File:** `app/OpenVerb/Engine/EngineClient.swift:571-591` + `:454-563`
- **Severity:** High
- **Status:** Fixed

Added `socketReadLock: NSLock` that serializes the `poll()+read()+recvBuffer.append()` block inside `recvJSONSync()`. Concurrent callers (monitor Task and drainResult ioQueue) now queue on the lock; the monitor exits the locked section immediately when its `poll()` sees the wakeup signal, so drainResult acquires the lock within µs.

---

### Bug 3 — Auto-clear timer can fire during PREPARING, silently killing the session
- **File:** `app/OpenVerb/State/AppState.swift:271-282`
- **Severity:** High
- **Status:** Fixed

Added `guard !Task.isCancelled else { return }` after the sleep and before `transition(to: .idle)`. Catches the race where `Task.sleep` completes successfully just before `autoClearTimer?.cancel()` is called.

---

### Bug 4 — ContextBuilder.swift incomplete: tests reference unimplemented API
- **File:** `app/OpenVerb/Context/ContextBuilder.swift`
- **Severity:** High
- **Status:** Fixed

All referenced APIs are now fully implemented: `PasteboardReadable` protocol, `build(targetApp:pasteboard:accessibilityReader:accessibilityApp:includeClipboard:languageOverride:)`, and `truncateToUTF8Bytes(_:limit:)`. 25 tests in ContextBuilderTests.swift pass against the complete implementation.

---

### Bug 5 — Data race on `fd` between ioQueue and Phase 2 monitor Task
- **File:** `app/OpenVerb/Engine/EngineClient.swift:30`
- **Severity:** Medium
- **Status:** Open

`private var fd: Int32 = -1` is read/written from `ioQueue` (connect, disconnect, sendAudioFrame) and the Phase 2 monitor `Task.detached` (runPhase2Monitor → recvJSONSync) without synchronization. Non-atomic `Int32` accessed from multiple concurrency domains is a data race under the Swift memory model. Practically safe on ARM64 (atomic Int32 reads/writes), but formally UB.

**Fix:** Wrap `fd` access through `ioQueue.sync` or use an atomic wrapper.

---

### Bug 6 — Misleading "selection" comment instead of "selected"
- **File:** `app/OpenVerb/Context/ContextBuilder.swift:59`
- **Severity:** Low
- **Status:** Fixed (leaving for tracking)

Comment says `"selection" is omitted entirely` but the engine reads key `"selected"` (prompt_builder.cpp:200). Fixed locally — keeping for reference.

---

### Bug 7 — `AppState.preparingSubtitle` public setter breaks encapsulation
- **File:** `app/OpenVerb/State/AppState.swift:80`
- **Severity:** Low
- **Status:** Fixed

Changed to `@Published private(set) var preparingSubtitle: String?`. Updated 3 test sites in AppStateTests.swift to drive subtitle via the `.inferring → .preparing` abort+restart path (sets `"Reconnecting..."` synchronously) instead of direct assignment.

---

### Bug 8 — `EngineManager.shutdown()` blocks MainActor for 500ms
- **File:** `app/OpenVerb/Engine/EngineManager.swift:300-313`
- **Severity:** Medium
- **Status:** Open

`shutdown()` calls `waitForProcessExit(timeout: 0.5)` which spins `RunLoop` for up to 500ms on the MainActor. Freezes UI for half a second. Acceptable at app termination (`applicationWillTerminate`) but dangerous if called from any other context.

**Fix:** Move `shutdown()` to a detached Task or background queue.

---

### Bug 9 — Server memory pressure WARN unload TOCTOU race with new session
- **File:** `engine/src/ipc/server.cpp:198-206`
- **Severity:** Medium
- **Status:** Open

WARN-pressure forced unload checks `session_active_` then calls `engine_.unload_model()`. A new client can connect between the check and the unload. The CRITICAL-pressure path mitigates this via `pressure_critical_active_` double-flag, but the WARN path has no such guard.

---

### Bug 10 — Session inference timeout leaks stale progress into next session
- **File:** `engine/src/ipc/session.cpp:416-423`
- **Severity:** Medium
- **Status:** Fixed

Added `progress_queue_.drain()` after joining the inference thread in the timeout handler, before sending the error response.

---

### Bug 11 — RecordingWindow crossfade shows empty gap during animation
- **File:** `app/OpenVerb/UI/RecordingWindow.swift:116-125`
- **Severity:** Low
- **Status:** Open

During the `.recording` → `.inferring` crossfade (150ms), both WaveformView and ProcessingView are partially transparent simultaneously, revealing the empty background. A matched fade-out/fade-in without overlap would look cleaner.

---

### Bug 12 — `disconnect()` wakeup signal lost after `stopPhase2Monitor()`
- **File:** `app/OpenVerb/Engine/EngineClient.swift:587-588` + `:150`
- **Severity:** Low
- **Status:** Open

`stopPhase2Monitor()` sets `wakeRead = -1; wakeWrite = -1`. Subsequent `disconnect()` checks `self.wakeWrite >= 0` → false → no wakeup signal sent. The monitor task may linger in `poll()` for up to 100ms. Minor latency issue, not correctness.

---

### Bug 13 — `config.cpp` model_path from glob may be relative
- **File:** `engine/src/config/config.cpp:306-311`
- **Severity:** Low
- **Status:** Fixed

Applied `std::filesystem::weakly_canonical()` to the glob result when assigning `cfg.model_path`, converting relative paths to absolute at config-resolution time.

---

### Bug 14 — `main.cpp` empty HOME fallback
- **File:** `engine/src/main.cpp:120`
- **Severity:** Low
- **Status:** Fixed

Replaced silent empty-string fallback with an explicit `getenv("HOME")` null/empty check that prints an error and returns 1, preventing `create_directories("")` UB.

---

### Bug 15 — `Vad::filter` potential integer overflow on very long audio
- **File:** `engine/src/audio/vad.cpp:81`
- **Severity:** Low
- **Status:** Fixed

Changed `num_frames` and all related loop variables/containers to `size_t`, eliminating the `static_cast<int>(pcm.size())` overflow. `pending` is now `std::vector<size_t>` and `append_frame` takes `size_t`.

---

## Fixed Bugs (reference only)

- **Bug 11 (old):** `truncateToUTF8Bytes` over-stripping — fixed with sequence-length check
- **Bug 1 (old):** CGEvent tap `passRetained` → fixed to `passUnretained`
- **Bug 4 (old):** `recordingWindow.show()` before audio start → fixed order
- **Bug 6 (old):** `unload_model` + inference race → fixed with `engine_mutex_`
