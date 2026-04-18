# OpenVerb Bug Tracker

## Active Bugs

### Bug 1 — `WaveformViewModel.updateAmplitude()` defers append to next run loop — stale amplitudes on immediate read
- **File:** `app/OpenVerb/UI/WaveformView.swift:34`
- **Severity:** Low
- **Status:** Fixed

`updateAmplitude()` is `nonisolated` and wraps `amplitudes.append(rms)` in `DispatchQueue.main.async`. Even when called from a `@MainActor` context, the append is deferred to the next run-loop iteration. Any code that reads `amplitudes` synchronously after calling `updateAmplitude()` sees stale (empty) state. SwiftUI works in practice only because it observes `@Published` changes asynchronously, but synchronous reads (tests, any direct caller) are inconsistent.

**Fix:** Annotate `updateAmplitude()` with `@MainActor` and call `amplitudes.append(rms)` directly. Extract the pure RMS computation into a `nonisolated` helper and call it before the actor hop.

---

### Bug 48 — `handleWake()` → `ensureRunning()` self-deadlock: engine never restarts after wake
- **File:** `app/OpenVerb/Engine/EngineManager.swift:504-527`
- **Severity:** High
- **Status:** Fixed
- **Negative test:** `testBug48_handleWakePrematureStatusStarting` — fails while `status = .starting` present in handleWake()

`handleWake()` sets `status = .starting` at line 506, then the wake Task calls `ensureRunning()` at line 519. Inside `ensureRunning()`, the dedup guard at line 223 sees `status == .starting` and enters the spin loop, interpreting this as "another `ensureRunning()` is already in flight." No other task will ever change status to `.running` — the only code that could do so is `ensureRunning()` itself, which is stuck in the loop. After 10 seconds the spin loop throws `launchTimeout` and the engine is never restarted.

Trigger: system wake after the engine process died during sleep (jetsam, OOM kill). OpenVerb hangs for 10 seconds showing "Loading model..." then shows an error. User must relaunch the app.

**Fix:** Don't pre-set `status = .starting` in `handleWake()` — let `ensureRunning()` own the status transition:
```swift
// handleWake(): remove the premature status = .starting
status = .stopped  // or simply omit — ensureRunning handles it
try await ensureRunning()
```

---

### Bug 49 — `drainResult()` `.error` path missing `disconnect()` — stale socket causes unnecessary engine restart
- **File:** `app/OpenVerb/App/OpenVerbApp.swift:768-774`
- **Severity:** Medium
- **Status:** Fixed

The `.result` path in `drainResult()` calls `engineManager.disconnect()` (line 740), but the `.error` path does not. After an engine error, the socket fd remains open. On the next recording:

1. `ensureRunning()` → `tryPing()` → `engineClient.connect()`
2. `connectSync`: `guard fd == -1` — fd is NOT -1 (stale) → returns immediately without reconnecting
3. If engine idle timeout expired (>15 s since error): `sendPing()` writes to stale socket → EPIPE → `tryPing()` fails → `sendSIGTERM()` kills engine → full restart (5+ s delay for model reload)
4. If engine session still alive (<15 s): old connection is reused, but buffered data from the failed session may still sit in `recvBuffer`

**Fix:** Add `engineManager.disconnect()` in the `.error` path, mirroring the `.result` path.

---

### Bug 31 — `PreferencesView` `keyNames` dictionary missing 10 ANSI punctuation keys
- **File:** `app/OpenVerb/UI/PreferencesView.swift`
- **Severity:** Low
- **Status:** Fixed

`hotkeyDescription` has a `keyNames: [UInt16: String]` table mapping virtual key codes to printable labels. Ten ANSI punctuation codes are missing: `0x18` (=), `0x1B` (-), `0x1E` (]), `0x21` ([), `0x27` ('), `0x29` (;), `0x2A` (\\), `0x2B` (,), `0x2C` (/), `0x2F` (.). Hotkeys using these keys fall through to the `"Key(\(keyCode))"` fallback — users see labels like `⌥Key(24)` instead of `⌥=`.

**Fix:** Add all 10 missing entries to the `keyNames` dictionary.

---

### Bug 32 — Audio frame ordering violation in `connectAndRecord()` [HIGH]
- **File:** `app/OpenVerb/App/OpenVerbApp.swift`
- **Severity:** High
- **Status:** Fixed
- **Negative test:** `testBug32_bufferedFramesCanArriveLaterThanLiveFrames` — fails while no `syncOnIOQueue`/`sendBufferedFrames`/`ioQueue.sync` fence is present

`flushAndSetSendCallback()` activates the live send callback and returns buffered chunks atomically. The caller loops over those chunks and dispatches each via `sendAudioFrame` (`ioQueue.async`). Simultaneously, the audio tap fires its live callback which also dispatches to `ioQueue.async`. Both paths compete on the serial queue — a live frame from the audio thread can land in `ioQueue` before a buffered frame dispatched from the MainActor loop, delivering frames out of chronological order and degrading recognition quality.

**Fix:** Add a public `syncOnIOQueue()` to `EngineClient` that executes `ioQueue.sync {}` as a fence (or expose `sendBufferedFrames(_:)` writing frames synchronously). Call it after the buffered-frames loop and before `startPhase2Monitor()`.

---

### Bug 36 — `baseAddress!` force-unwrap in `EngineClient` — crash on empty `Data` [MEDIUM]
- **File:** `app/OpenVerb/Engine/EngineClient.swift:462`
- **Severity:** Medium
- **Status:** Fixed
- **Negative test:** `testBug36_forceUnwrapBaseAddress` — fails while `baseAddress!` exists in EngineClient.swift

`sendJSONSync`, `writeAudioFrameOrDrop`, and the disconnect sentinel all call `data.withUnsafeBytes { try writeFully($0.baseAddress!, count: $0.count) }`. Under Swift's `UnsafeRawBufferPointer` contract, `baseAddress` is `nil` for zero-byte buffers. An empty `Data` input — possible for a malformed `Encodable` or a zero-length audio frame — triggers a fatal crash with no diagnostic.

**Fix:** Replace `$0.baseAddress!` with `guard let base = $0.baseAddress else { return }` at each call site, or add `guard !data.isEmpty else { return }` before `withUnsafeBytes`.

---

### Bug 38 — `ShortcutCaptureView` leaks `NSEvent` monitor on dealloc [MEDIUM]
- **File:** `app/OpenVerb/Input/ShortcutRecorder.swift`
- **Severity:** Medium
- **Status:** Fixed
- **Negative test:** `testBug38_shortcutCaptureViewMissingDeinit` — fails while `ShortcutCaptureView` has no `deinit`

`startRecording()` installs a local `NSEvent` monitor. If the Preferences window closes while `isRecording == true` (user clicked the recorder but hasn't pressed a key yet), SwiftUI tears down the view without calling `stopRecording()`. `NSEvent` retains the monitor block — a new leak accumulates on every open-then-close-while-recording cycle.

**Fix:** Add `deinit { if let m = localMonitor { NSEvent.removeMonitor(m) } }` to `ShortcutCaptureView`, or call `stopRecording()` from `deinit`.

---

### Bug 46 — `drainResult()` `.error` path skips crash recovery [MEDIUM]
- **File:** `app/OpenVerb/App/OpenVerbApp.swift`
- **Severity:** Medium
- **Status:** Fixed
- **Negative test:** `testBug46_drainResultErrorPathMissingCrashRecovery` — fails while `.error` case lacks `handleCrash()`

When the engine sends a structured `.error` message (`model_load_failed`, `inference_failed`), `drainResult()` calls `handleEngineError()` and returns — without calling `engineManager.handleCrash()`. The engine is left dead. The next hotkey press must wait for `ensureRunning()` to detect and restart the dead engine, adding a visible 5+ s delay. The connection-error path a few lines above correctly dispatches `handleCrash()` with exponential backoff; the structured `.error` branch omits it.

**Fix:** In the `.error` case, after `handleEngineError()`, add:
```swift
Task { [weak self] in try? await self?.engineManager.handleCrash() }
```
mirroring the connection-error path.

---

### Bug 51 — `handleCrash()` sends ping to active session socket after sleep — corrupts binary streaming
- **File:** `app/OpenVerb/Engine/EngineManager.swift:356-399` + `app/OpenVerb/App/OpenVerbApp.swift` (all `handleCrash()` call sites)
- **Severity:** High — **primary cause of intermittent "nothing records" symptom**
- **Status:** Fixed

After any engine error (duration_exceeded, inference_failed, connection timeout) `handleCrash()` is spawned as a background Task. It immediately disconnects and sleeps for `backoffDelay(1) = 1 second`, then calls `ensureRunning()` → `tryPing()` → `sendPing()`.

The race:

1. User receives engine error → `handleCrash()` Task spawned (sleeps 1 s).
2. User presses ⌥Space again within ≤1 s → `connectAndRecord()` → `ensureRunning()` succeeds → new session starts on the existing fd (Bug 49 keeps it open) or a freshly reconnected fd.
3. `handleCrash()` wakes after 1 s → `ensureRunning()` → `tryPing()` → `connectSync()` sees `fd != -1` (session active) → returns without creating a new socket → `sendPing()` dispatches `{"type":"ping"}\n` to `ioQueue`.
4. On `ioQueue`: pending audio-frame writes drain first, then the 15-byte ping JSON is written to the active session socket.
5. Engine is in `STREAMING_AUDIO` (binary protocol). It reads the first 4 bytes of the ping JSON (`{`, `"`, `t`, `y` = 0x7B227479 ≈ 2 billion) as a big-endian frame length. It then tries to receive ~2 GB of data. Remaining audio frames and the sentinel are absorbed as the frame body. After no new data for `stall_timeout_secs` (30 s) the engine sends a timeout error.
6. User sees: waveform animated, pressed stop, waited ~30 s, got error. Recording produced no result.

The bug fires whenever the pre-existing session takes > 1 s (i.e., the user records for more than 1 second after a prior error). For short recordings (< 1 s) the sentinel arrives before the ping, and the ping lands in INFERRING where it is silently ignored — so the session accidentally succeeds, explaining the "sometimes it works" observation.

**Fix:** Gate `handleCrash()`'s final `ensureRunning()` on the `canRestartBackend` closure (which returns `appState.state == .idle`). If a new session has started during the sleep, skip the pre-warm — the new session's own `ensureRunning()` already handled reconnection.

```swift
let delay = backoffDelay(attempt: crashCounter)
try await Task.sleep(for: .seconds(delay))
// Skip pre-warm if a new session is already active; pinging an active
// session's socket corrupts the binary streaming protocol (Bug 51).
guard canRestartBackend?() ?? true else { return }
try await ensureRunning()
```

---

### Bug 52 — `connectAndRecord()` catch block missing `disconnect()` — stale fd left open on session-setup failure
- **File:** `app/OpenVerb/App/OpenVerbApp.swift:684-708`
- **Severity:** Medium
- **Status:** Fixed

When `startSession()` or `receiveMessage(timeoutMs: 120_000)` (waiting for `session.ready`) throws inside `connectAndRecord()`, the catch block does not call `engineManager.disconnect()`. The fd remains open.

`handleCrash()` is then spawned and immediately calls `engineClient.disconnect()`, but there is a narrow @MainActor window between the `appState.transition(to: .error(...))` and `handleCrash()` running where the user could press ⌥Space again. If they do, `connectAndRecord()` runs, `connectSync()` sees `fd != -1` and silently reuses the stale socket — which may be mid-way through an unexpected protocol state on the engine side.

The interaction with Bug 51 is also present: the re-spawned `handleCrash()` after the second attempt will again race and send a ping mid-stream.

**Fix:** Add `engineManager.disconnect()` in the catch block of `connectAndRecord()`, immediately before spawning `handleCrash()`:

```swift
} catch {
    audioSession.stop()
    hotkeyManager.removeEscapeMonitors()
    engineManager.disconnect()   // ← add this
    // ... existing error handling ...
}
```

---

### Bug 53 — server.cpp: `session_thread_.join()` after `accept()` stalls new ping for up to 15 s when prior session never received client disconnect
- **File:** `engine/src/ipc/server.cpp:237-239`
- **Severity:** Medium
- **Status:** Fixed (unreachable — Bugs 49 and 52 now always call disconnect() on error)

The IPC server calls `accept()` to get a new client fd, then immediately calls `session_thread_.join()` to wait for the previous session thread to exit before starting the new one. Under Bug 49 / Bug 52 conditions, the prior session on the engine side never received a client `close()` — it is alive in `IDLE` state polling the old socket fd for up to `idle_timeout_secs` (15 s).

Sequence:
1. Engine error → client does not call `disconnect()` (Bug 49/52) → engine session stays in IDLE on old fd.
2. Next recording: client creates a **new** socket and connects (after `handleCrash()` disconnected and `ensureRunning()` creates a fresh connection).
3. `accept()` returns the new fd.
4. `session_thread_.join()` **blocks** until the old session exits. Old session is polling the old fd. Old fd is still open (client side → Bug 49, not closed). Old session waits 15 s for `idle_timeout_secs` before giving up.
5. New client is accepted but not being served. `sendPing()` times out (5 s) → `tryPing()` returns false → `ensureRunning()` SIGTERMs the engine and does a full cold restart (5+ s model reload).
6. User sees up to 20 s of "Preparing..." then either recovery or an error.

This bug only activates when Bug 49 or Bug 52 is present (client left the old fd open). Fixing those two bugs (always calling `disconnect()`) makes Bug 53 unreachable in practice because the old engine session receives `ConnectionClosed` immediately and exits, unblocking `join()` in < 1 ms.

**Fix (primary):** Fix Bugs 49 and 52 so the client always disconnects on error. This makes the old engine session exit immediately and unblocks `join()`.

**Fix (defense-in-depth, C++ side):** After `accept()`, check if the previous session is still running before joining; if so, signal it via the engine's `g_interrupted` or a per-session stop flag before blocking in `join()`. This is a larger change and is not strictly necessary once Bugs 49/52 are fixed.

---

### Bug 50 — `showConflictAlert()` doesn't persist selected hotkey — conflict dialog reappears every launch
- **File:** `app/OpenVerb/Input/HotkeyManager.swift:365-385`
- **Severity:** Medium
- **Status:** Fixed
- **Negative test:** `testBug50_conflictAlertDoesNotPersistHotkey` — fails while settings aren't written after installEventTap

When ⌥Space is already in use by another app, `showConflictAlert()` offers three alternatives and calls `installEventTap(key: newKey)`. This only updates the in-memory `hotKey` property — it never writes to `AppSettings.shared.hotkeyKeyCode` / `hotkeyModifiers`. On next launch, `register()` reads the original conflicting hotkey from UserDefaults, `installEventTap` fails, and the conflict dialog appears again. The user's choice is lost every time.

**Fix:** Persist the selected alternative to AppSettings after installing the tap:
```swift
installEventTap(key: newKey)
settings.hotkeyKeyCode = newKey.virtualKey
settings.hotkeyModifiers = newKey.flags
```

---

### Bug 54 — `TextInjector` leaves transcription on `NSPasteboard` for 300 ms — stale clipboard context in next session
- **File:** `app/OpenVerb/Output/TextInjector.swift:59-102` × `app/OpenVerb/Context/ContextBuilder.swift:91-95`
- **Severity:** High — **primary cause of "writes what I said last time" symptom**
- **Status:** Fixed
- **Negative test:** `testBug54_clipboardCapturedAtStartRecordingNotConnectAndRecord` — fails while `clipboardSnapshot` is not captured in `startRecording()` and `ContextBuilder.build` has no `clipboardSnapshot:` parameter

`TextInjector.inject()` writes the transcribed text to `NSPasteboard.general` at step (2), posts ⌘V, waits 300 ms for the target app to read the clipboard (step 7), then restores the original at step (8). If the user presses ⌥Space again within that 300 ms window, `startRecording()` → `connectAndRecord()` → `ContextBuilder.build()` reads `NSPasteboard.general.string(forType: .string)` and gets the **just-transcribed text from the previous session** as `context["clipboard"]`.

The engine's LLM prompt builder receives the previous transcription as clipboard context. If the current recording is ambiguous, short, or acoustically similar to the previous one, the LLM reproduces the previous transcription verbatim. Additionally, if `changeCount` changed during the paste window (step 8 guard fails), the transcription remains on the clipboard indefinitely, biasing every subsequent session.

**Potentially affects:** every session started within ~300 ms of a successful injection; fast typers / power users who immediately re-dictate after a paste; `abortAndRestart` sequences (the new session starts ~1.5 s later but TextInjector's 300 ms window may still overlap); any session where the original clipboard was nil (restore is a no-op, so the transcription stays on the pasteboard until the user copies something else).

**Fix:** Capture the current clipboard at `startRecording()` time (before `TextInjector` runs), not inside `ContextBuilder.build()` at `connectAndRecord()` time. Alternatively, pass a `clipboardSnapshot` captured during `startRecording()` through to `ContextBuilder`, so the context is always the clipboard content at the moment ⌥Space was pressed — never the text that was just injected.

```swift
// In startRecording(), before the Task:
let clipboardSnapshot = appSettings.includeClipboard
    ? NSPasteboard.general.string(forType: .string)
    : nil

// In connectAndRecord(), replace the ContextBuilder call with:
let context = await ContextBuilder.build(
    targetApp: appState.targetApp,
    accessibilityApp: appState.targetApp,
    clipboardSnapshot: clipboardSnapshot,
    languageOverride: appSettings.language
)
```

---

### Bug 55 — `livePartialText` never updates during `.recording` — partial results only arrive post-stop
- **File:** `app/OpenVerb/App/OpenVerbApp.swift:263-268` × `app/OpenVerb/UI/RecordingWindow.swift:149-160`
- **Severity:** Medium
- **Status:** Fixed
- **Negative test:** `testBug55_livePartialTextDeadDuringRecording` — fails while `runPhase2Monitor` default case doesn't call `onPartialResult` and no live-reader task exists in `connectAndRecord()`

`appState.livePartialText` is populated exclusively by the `onPartialResult` callback, which is invoked only inside `drainResult()`. `drainResult()` is spawned in `stopRecording()` and runs during `.inferring` state. During `.recording`, no code reads `partial_result` messages from the engine socket — the `phase2Monitor` does read them (if the engine sends any during Phase 2), but puts them back at the front of `recvBuffer` via `prepend()` for `drainResult` to consume later.

Consequence: even with `showLiveTranscript = true`, the live transcript remains blank while the user is speaking. Text appears only in a burst after ⌥Space is released (during `.inferring`), not incrementally. The user may also conflate `includeClipboard` (which sends clipboard context to the engine silently) with `showLiveTranscript` (the actual display toggle, which defaults to `false`). Enabling clipboard context changes nothing visible in the UI.

Secondary issue: `showLiveTranscript` defaults to `false` and is shown in Preferences separately from `includeClipboard`. A user who enables `includeClipboard` expecting live text to appear will see no change.

**Potentially affects:** all users who enabled `showLiveTranscript` — the feature is completely non-functional during recording regardless of that setting; users who enabled `includeClipboard` thinking it controls visible output (UX confusion); long recordings where real-time feedback would reduce rerecording — without live text, users cannot tell if the model is capturing their speech correctly until after they stop.

**Fix (display):** During `.recording`, set up a lightweight polling task that calls `receiveMessage` with a short timeout and appends any `partialResult` messages to `livePartialText`. Or, have `phase2Monitor` forward non-error messages directly via the `onPartialResult` callback instead of putting them back in `recvBuffer`.

**Fix (UX):** Add a tooltip or label in Preferences making clear that `includeClipboard` improves accuracy silently, while `showLiveTranscript` controls the visible rolling subtitle.

---

### Bug 56 — `phase2Monitor` `prepend`-spin-loop: non-error Phase 2 messages are infinitely re-read
- **File:** `app/OpenVerb/Engine/EngineClient.swift:608-616`
- **Severity:** High — **probable cause of ~50% empty-result sessions when engine sends partial_result during streaming**
- **Status:** Fixed
- **Negative test:** `testBug56_phase2MonitorPrependSpinLoop` — fails while `default` case in `runPhase2Monitor` has no `continue` after `recvBuffer.prepend()`

When any non-error JSON message (e.g. `partial_result`, `progress`) arrives during Phase 2 binary streaming, `runPhase2Monitor` puts it back into `recvBuffer` via `recvBuffer.prepend(restored)`. On the very next loop iteration the monitor calls `recvJSONSync(timeoutMs: 100)`, which checks the in-memory buffer **before** polling the socket:

```swift
recvLock.lock()
if let msg = recvBuffer.extractMessage() {   // ← finds the message we just prepended
    recvLock.unlock(); return msg             // ← returns the SAME message immediately
}
```

The monitor extracts the same message, classifies it as non-error, and prepends it again — a tight spin-loop. `drainResult` can steal the message from `recvBuffer` during the narrow window between the monitor's `prepend` and its next `extractMessage`, but this is a race: under contention the monitor keeps re-taking the message and `drainResult` starves. If the engine sends `partial_result` messages during Phase 2 (streaming inference), this manifests as:

1. `phase2Monitor` spins on one CPU core consuming ~100 % of that core.
2. `drainResult` struggles to read Phase 3 result messages — each call to `receiveMessage` sees an empty buffer (monitor just extracted), falls through to `socketReadLock`+poll, and blocks for up to 180 s.
3. User experiences: recording seems to work, stop is pressed, long spinner, then either a 180 s timeout error or, on lucky races where `drainResult` wins, a correct result — explaining the ~50 % success rate.

**Fix:** In the `default` case, after `prepend`, do **not** continue to the top of the loop immediately. Instead skip the `recvJSONSync` call and `poll` the socket for fresh data, so the monitor only re-processes socket events — not the already-buffered message it just put back:

```swift
default:
    recvLock.lock()
    var restored = data
    restored.append(UInt8(ascii: "\n"))
    recvBuffer.prepend(restored)
    recvLock.unlock()
    // Bug 56 fix: skip directly to the stopped-check and loop top so the
    // next iteration polls the socket (not the buffer we just refilled).
    phase2Lock.lock()
    stopped = phase2MonitorStopped
    phase2Lock.unlock()
    continue   // ← goes back to while condition → ioQueue.sync(fd >= 0) → poll
```

Because `continue` jumps to the outer `while` check (which calls `ioQueue.sync { fd >= 0 }` and then `poll(&pfds, 2, 100)`), the monitor will wait up to 100 ms before attempting another read, giving `drainResult` an uncontested window to extract the buffered message.

**Potentially affects:** any session where the engine emits `partial_result` or `progress` messages during Phase 2 binary streaming (i.e. while audio is still being sent); the Gemma Audio streaming backend is the primary suspect since it performs streaming inference per chunk and is designed to emit partials incrementally; backends that only emit results after the audio sentinel (Phase 3) are unaffected; the bug also causes elevated CPU on one core for the entire recording duration whenever it fires.

---

### Bug 57 — `Session::stop()` does not join `worker_thread_` — `std::terminate()` on unexpected exception
- **File:** `engine/src/ipc/session.cpp:38-40` × `engine/src/ipc/session.h:38`
- **Severity:** High — **crash: process abort**
- **Status:** Fixed
- **Negative test:** `testBug57_sessionStopDoesNotJoinWorkerThread` — fails while `stop()` has no `worker_thread_.join()`

`Session::stop()` only signals `stop_requested_` and notifies `result_cv_`, but never joins `worker_thread_`. The comment reads "worker_thread_ is joined inline within run()" — and this is true for the two expected exits (loop break after `stop_requested_`, `ConnectionClosed` exception). However, the STREAMING_AUDIO catch block only catches `ConnectionClosed` and `std::runtime_error`. Any other exception — most likely `std::bad_alloc` from `VadScanner::buffer_.insert()` or from any STL container in the hot path — propagates out of `run()` entirely without reaching the join site. The `std::thread` object then goes out of scope while joinable: `std::thread::~thread()` calls `std::terminate()`, crashing the engine process.

Even under low-memory conditions (audio callbacks firing while the system is under pressure), `new` for any internal container can throw `std::bad_alloc`. The STREAMING_AUDIO loop processes audio buffers continuously, making this a realistic failure mode under memory pressure.

**Fix:** Add `if (worker_thread_.joinable()) worker_thread_.join();` to `Session::stop()` — the function that is always called from `~Session()`. Alternatively, widen the STREAMING_AUDIO catch to `catch (const std::exception& e)` or `catch (...)` so all exceptions are handled before the join site.

```cpp
void Session::stop() {
    stop_requested_.store(true, std::memory_order_relaxed);
    result_cv_.notify_all();
    if (worker_thread_.joinable()) worker_thread_.join();  // ← add this
}
```

---

### Bug 58 — `vad.cpp::filter()` trailing-silence loop narrows `size_t` → `int`
- **File:** `engine/src/audio/vad.cpp:155`
- **Severity:** Low
- **Status:** Fixed
- **Negative test:** `testBug58_vadFilterTrailingSilenceNarrowsIndex` — fails while loop uses `int si`

In `VadScanner::filter()`, the trailing-silence flush loop:

```cpp
if (in_speech && !pending.empty()) {
    for (int si : pending) {  // ← si is int; pending is std::vector<size_t>
        append_frame(si);
    }
}
```

`pending` is `std::vector<size_t>` (frame indices). The range-for variable `si` is declared `int`, which silently narrows every `size_t` element. `append_frame` takes `size_t fi`. On a 64-bit target, `size_t` is 8 bytes and `int` is 4 bytes. Frame counts in practice never approach `INT_MAX` (a 30-minute recording at 16 kHz with 512-sample frames is ~3500 frames), so no truncation occurs at runtime — but the type mismatch is a real compiler warning (C4267 / -Wsign-conversion / -Wshorten-64-to-32) and a latent hazard if the audio pipeline ever processes larger buffers.

**Fix:** Change `int si` to `size_t si` (or `const auto si`).

```cpp
for (size_t si : pending) {
    append_frame(si);
}
```

---

### Bug 59 — `polish_text()` passes empty audio to the multimodal backend — polish pass is non-functional in all deployments
- **File:** `engine/src/engine.cpp:223` × `engine/src/backend/backend_gemma_audio.cpp:55-68`
- **Severity:** Medium — **UX: feature appears to work but produces no improvement**
- **Status:** Fixed
- **Negative test:** `testBug59_polishTextPassesEmptySamplesToBackend` — fails while `polish_text()` passes `{}` as samples

`polish_text()` calls the multimodal backend with an empty audio vector:

```cpp
InferenceResult result = be->process(
    /*samples=*/{},          // ← empty — no audio
    /*sample_rate=*/SAMPLE_RATE,
    /*context_json=*/prompt,
    /*progress=*/nullptr);
```

In `GemmaAudioBackend::process_impl()`, when `vad_enabled = false` (the daemon default set by `DEFAULT_VAD_ENABLED_FILE`), the VAD filter is skipped: `pcm_to_infer = audio_pcm` = empty. The code then tries to create an audio bitmap from zero samples:

```cpp
mtmd_bitmap* audio_bmp = mtmd_bitmap_init_from_audio(0, audio_f32.data());
if (!audio_bmp) {
    throw std::runtime_error("LlamaContext::infer: failed to create audio bitmap");
}
```

`mtmd_bitmap_init_from_audio(0, ptr)` almost certainly returns null for zero samples. The resulting `std::runtime_error` is caught in `polish_text()`'s catch block, which silently returns the raw transcript:

```cpp
} catch (const std::exception& e) {
    log_warning("polish_text failed: " + std::string(e.what()));
    return raw_transcript;  // ← original text returned, no polish applied
}
```

The Swift app launches the engine with `["--listen", "--socket", socketPath]` — no `--vad` flag — so `vad_enabled = false` in all real deployments. The UI shows "Polishing…" (the `polish_started` message is sent), but the polish pass never runs. The backend is called with empty audio on a multimodal model, it throws, and the raw transcript is returned as if polished. The feature is silently broken in production.

**Potentially affects:** every user — the polish pass has never functioned in any shipped configuration; the animated "Polishing…" indicator is cosmetic; users may attribute transcription quality improvements to polishing when none occurred, or incorrectly blame the model for not cleaning up filler words.

**Fix:** `polish_text()` is a text-only operation and should not go through the audio backend's `process()`. Options:
1. Add a `process_text(prompt, progress)` method to the `Backend` interface that accepts no audio, and route `polish_text()` through it.
2. Pass a minimal non-empty noise-floor audio vector (e.g. a few zero samples) to suppress the null bitmap check, then suppress the audio tokens in the prompt template — a workaround, not a real fix.
3. If the model supports text-only inference via a system prompt without audio tokens, implement a separate `LlamaContext::infer_text()` that omits the `mtmd` audio embedding path entirely.
