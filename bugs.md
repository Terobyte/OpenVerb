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
- **Status:** Active
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
