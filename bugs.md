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
- **Status:** Fixed

WARN-pressure forced unload checks `session_active_` then calls `engine_.unload_model()`. A new client can connect between the check and the unload. The CRITICAL-pressure path mitigates this via `pressure_critical_active_` double-flag, but the WARN path has no such guard.

False positive per Bug 21 re-examination. WARN-pressure unload and accept() run on the same main thread in different `poll()` branches — no concurrency exists between the check and the unload.

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

### Bug 16 — `drainResult` error path unconditionally tears down new recording after abort+restart
- **File:** `app/OpenVerb/App/OpenVerbApp.swift:552-556`
- **Severity:** High
- **Status:** Open

When `abortAndRestart()` disconnects the socket, the stale `drainResult` Task receives a `receiveMessage()` error. The catch block unconditionally executes `recordingWindow.hide()`, `audioSession.stop()`, and `hotkeyManager.removeEscapeMonitors()` — even if the state has already moved to `.preparing` or `.recording` for the new session. The guard `if appState.state == .inferring` only protects the `transition(to: .error)` call, not the teardown above it.

**Repro:**
1. ⌥Space → record → ⌥Space → inference starts
2. ⌥Space again (abort+restart) → state moves to `.preparing`, new recording begins
3. Old `drainResult` Task resumes from suspended `receiveMessage()`, catches the error
4. `audioSession.stop()` / `recordingWindow.hide()` / `removeEscapeMonitors()` kill the new recording silently

**Fix:** Wrap teardown in `guard appState.state == .inferring else { return }` before the UI cleanup calls.

---

### Bug 17 — Phase 2 monitor fires `onError` after `stopPhase2Monitor()` during abort+restart
- **File:** `app/OpenVerb/Engine/EngineClient.swift:501-521`, `app/OpenVerb/App/OpenVerbApp.swift:144-162`
- **Severity:** High
- **Status:** Open

`stopPhase2Monitor()` sets `phase2MonitorStopped = true` and writes the wakeup byte, but does **not** wait for the monitor Task to finish. If the monitor is already inside `recvJSONSync()` (past the `stopped` check at line 504), the subsequent `disconnect()` closes the fd, causing `recvJSONSync()` to throw. The monitor catches the error, sets `phase2Error`, and calls `onError` — even though the stop was intentional.

The `onError` handler in AppDelegate performs full session teardown (stop audio, hide window, remove monitors, transition to `.error(...)`, trigger `handleCrash()`). This overwrites the `.preparing` state from abort+restart and shows a spurious error to the user.

**Fix:** Check `phase2MonitorStopped` inside the monitor's error catch before calling `onError`, or gate the AppDelegate `onError` handler on `appState.state`.

---

### Bug 18 — Six `AppSettings` properties are published but never consumed
- **File:** `app/OpenVerb/Settings/AppSettings.swift` vs consumers
- **Severity:** Medium
- **Status:** Open

The following `AppSettings` properties are persisted to UserDefaults and published via `@Published`, but the code that should read them uses hardcoded values or defaults instead:

| Property | Expected consumer | Actual behavior |
|----------|-------------------|-----------------|
| `hotkeyKeyCode` / `hotkeyModifiers` | `HotkeyManager` | Hardcoded `HotKey.altSpace` |
| `language` | `ContextBuilder.build(languageOverride:)` | Parameter not passed (`OpenVerbApp.swift:478`) |
| `includeClipboard` | `ContextBuilder.build(includeClipboard:)` | Parameter not passed |
| `soundEffectsEnabled` | `NSSound.play()` calls | Sounds play unconditionally |
| `showWaveform` | `RecordingContentView` | Waveform always visible |
| `modelDirectory` | `EngineManager` | Uses `Constants.DEFAULT_MODEL_DIR` |

User changes to these settings have no effect.

**Fix:** Pass `AppSettings.shared` into the relevant components at init time and read from it.

---

### Bug 19 — `Engine::unload_model()` can race with `process_stream()` — use-after-free
- **File:** `engine/src/engine.cpp:158-164` (unload) vs `:166-189` (process_stream)
- **Severity:** Medium
- **Status:** Fixed

`process_stream()` copies `backend_` to a local `shared_ptr` (`be`), releases `engine_mutex_`, then calls `be->process_stream()`. If `unload_model()` runs concurrently, it locks `engine_mutex_`, calls `backend_->unload_model()` which resets `llama_` (the `unique_ptr<LlamaContext>`). The Backend object remains alive (shared_ptr) but its internal `llama_` is destroyed. The inference thread then dereferences the dangling reference in `process_impl()` → `llama_->infer()`.

Server-level guards (`session_active_` checks in the WARN/CRITICAL pressure handlers) prevent this in normal operation, but the `Engine` class itself is not thread-safe for concurrent unload + inference calls.

`engine.cpp` already holds `std::unique_lock<std::shared_mutex>` (exclusive) in `unload_model()` and `std::shared_lock<std::shared_mutex>` (shared) in `process_stream()/process_file()`. Fix was applied as part of a prior commit.

---

### Bug 20 — `Vad::filter()` iterates `vector<size_t>` with `int` loop variable
- **File:** `engine/src/audio/vad.cpp:156`
- **Severity:** Low
- **Status:** Fixed

```cpp
std::vector<size_t> pending;
// ...
for (int si : pending) {   // truncation: size_t → int
    append_frame(si);
}
```

Truncates `size_t` to `int` on 64-bit systems. Practically safe (frame indices won't exceed `INT_MAX`), but formally incorrect.

`vad.cpp:155` already reads `for (size_t si : pending)`. Applied as part of the Bug 15 fix commit.

---

### Bug 21 — Bug 9 reassessment: WARN TOCTOU is likely a false positive
- **File:** `engine/src/ipc/server.cpp:198-206`
- **Severity:** Info
- **Status:** Fixed

Re-examined the WARN-pressure unload path. Both `session_active_` check (line 199) and `engine_.unload_model()` (line 202) execute on the main thread within the `poll()` timeout branch (`pret == 0`). `accept()` only runs in the `pret > 0` branch. Since the main thread is single-threaded, no new client can be accepted between the check and the unload. The GCD handler only sets the `pressure_force_unload_` flag — the actual unload is serialized on the main thread. No TOCTOU exists.

The original assessment may have assumed the GCD handler calls `unload_model()` directly (which the CRITICAL handler does for the no-session case), but the WARN handler only sets a flag.

Analysis complete. See Bug 9 update.

---

## Fixed Bugs (reference only)

- **Bug 11 (old):** `truncateToUTF8Bytes` over-stripping — fixed with sequence-length check
- **Bug 1 (old):** CGEvent tap `passRetained` → fixed to `passUnretained`
- **Bug 4 (old):** `recordingWindow.show()` before audio start → fixed order
- **Bug 6 (old):** `unload_model` + inference race → fixed with `engine_mutex_`
