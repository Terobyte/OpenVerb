# OpenVerb Bug Tracker

## Active Bugs

### Bug 5 — Data race on `fd` between ioQueue and Phase 2 monitor Task
- **File:** `app/OpenVerb/Engine/EngineClient.swift:30`
- **Severity:** Medium
- **Status:** Open

`private var fd: Int32 = -1` is read/written from `ioQueue` (connect, disconnect, sendAudioFrame) and the Phase 2 monitor `Task.detached` (runPhase2Monitor → recvJSONSync) without synchronization. Non-atomic `Int32` accessed from multiple concurrency domains is a data race under the Swift memory model. Practically safe on ARM64 (atomic Int32 reads/writes), but formally UB.

**Fix:** Wrap `fd` access through `ioQueue.sync` or use an atomic wrapper.

---

### Bug 8 — `EngineManager.shutdown()` blocks MainActor for 500ms
- **File:** `app/OpenVerb/Engine/EngineManager.swift:300-313`
- **Severity:** Medium
- **Status:** Fixed

`shutdown()` calls `waitForProcessExit(timeout: 0.5)` which spins `RunLoop` for up to 500ms on the MainActor. Freezes UI for half a second. Acceptable at app termination (`applicationWillTerminate`) but dangerous if called from any other context.

**Fix:** Move `shutdown()` to a detached Task or background queue.

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

### Bug 18 — `AppSettings` properties published but not all consumed
- **File:** `app/OpenVerb/Settings/AppSettings.swift` vs consumers
- **Severity:** Medium
- **Status:** Partially fixed

Originally six properties were unwired. Current state:

| Property | Consumer | Status |
|----------|----------|--------|
| `hotkeyKeyCode` / `hotkeyModifiers` | `HotkeyManager` | **Fixed** — reads from `AppSettings.shared` in `register()`; Combine observer reinstalls tap on change |
| `language` | `ContextBuilder.build(languageOverride:)` | **Fixed** — passed via `languageOverride: appSettings.language` in `connectAndRecord()` |
| `includeClipboard` | `ContextBuilder.build(includeClipboard:)` | **Fixed** — passed via `includeClipboard: appSettings.includeClipboard` |
| `modelDirectory` | `EngineManager` | **Partially fixed** — read once at `init()` as snapshot (see Bug 23 for live-update issue) |
| `soundEffectsEnabled` | `NSSound.play()` calls | **Open** — sounds play unconditionally |
| `showWaveform` | `RecordingWindow` / `RecordingContentView` | **Open** — waveform always visible |

**Remaining fix:** Guard `NSSound` calls with `appSettings.soundEffectsEnabled`; gate waveform display on `appSettings.showWaveform`.

---

### Bug 22 — `maxRecordingDuration` AppSettings property unconsumed — recordings never auto-stop
- **File:** `app/OpenVerb/Settings/AppSettings.swift:109-115`, `app/OpenVerb/UI/PreferencesView.swift:96-104`
- **Severity:** Medium
- **Status:** Open

`AppSettings.maxRecordingDuration` (default 60 s, UI: Stepper 1–300 s) is persisted and displayed in Preferences → General → Recording but no recording code ever reads it. `startRecording()` / `connectAndRecord()` never schedule a stop timer based on this value. Recordings run until the user manually presses ⌥Space, regardless of the setting.

**Fix:** In `startRecording()`, after transitioning to `.preparing`, schedule a `Task.sleep(for:)` of `appSettings.maxRecordingDuration` seconds that calls `stopRecording()` if still in `.recording` state. Cancel the timer on `handleCancel()` / `abortAndRestart()`.

---

### Bug 23 — `EngineManager.modelDirPath` is a snapshot — model directory changes in Preferences have no effect until app restart
- **File:** `app/OpenVerb/Engine/EngineManager.swift:107-108`, `app/OpenVerb/UI/PreferencesView.swift:220-233`
- **Severity:** Medium
- **Status:** Open

`modelDirPath` is declared `let` and initialised once from `AppSettings.shared.modelDirectory` in `EngineManager.init()`. The Preferences → Backend → Model → "Browse..." button writes a new path to `AppSettings`, but `EngineManager` never re-reads it. All subsequent `launchEngine()` calls (crash recovery, backend switch, sleep/wake) pass the original path to the engine subprocess. Changing the model directory in Preferences has no effect until the app is relaunched.

**Fix:** Change `modelDirPath` to a computed `var` that reads `AppSettings.shared.modelDirectory` (or pass the settings object into EngineManager and read it dynamically in `launchEngine()`).

---

### Bug 24 — `PreferencesWindowController.open()` creates an orphan `EngineManager` if weak reference is nil
- **File:** `app/OpenVerb/UI/PreferencesView.swift:273-276`
- **Severity:** Medium
- **Status:** Open

```swift
let em = self.engineManager ?? EngineManager()
```

`self.engineManager` is `weak`. If `open(engineManager:)` is ever called before a managed engine is stored, or if the weak reference is nil, a brand-new `EngineManager()` is created. This orphan:
1. Calls `registerSleepWakeNotifications()` in its `init()` — installs **duplicate** `willSleep`/`didWake` observers that compete with the real engine manager.
2. Has no engine subprocess — any `restartWithBackend()` call triggered from Preferences targets this orphan, not the actual running engine.
3. Sets `backendOverride` on itself — has no effect on the real engine.

The orphan is stored in `PreferencesWindowController.window` (indirect strong reference via NSWindow's `contentViewController`), keeping it alive as long as the Preferences window exists.

**Fix:** Assert / crash in DEBUG if `self.engineManager` is nil. In production, guard early and log an error rather than creating an orphan.

---

### Bug 25 — Backend switching in Preferences not gated on app state — kills active recording session silently
- **File:** `app/OpenVerb/UI/PreferencesView.swift:115-131`, `app/OpenVerb/Engine/EngineManager.swift:399-411`
- **Severity:** High
- **Status:** Open

The backend picker in Preferences can be changed at any time. When a new backend is selected, `restartWithBackend()` immediately:
1. Sets `status = .starting`
2. Calls `shutdown()` + SIGTERM on the engine subprocess
3. Calls `ensureRunning()` (launches a new process with the new backend)

If the user switches backend while in `.recording` or `.inferring` state:
- The engine is killed mid-session
- `drainResult()` receives a socket error — may hit Bug 16/17 paths depending on state
- The active recording is lost with no user feedback beyond the status bar icon change

**Fix:** Disable the backend picker (or show a tooltip) when `appState.state != .idle`. `EngineManager` does not hold a reference to `AppState`, so the guard must be added in `PreferencesView` using an `@ObservedObject var appState: AppState` that is passed into the view.

---

### Bug 26 — `prompt_builder.h` `parse_context_json()` doc omits "clipboard" and "language" fields
- **File:** `engine/src/context/prompt_builder.h:65-74`
- **Severity:** Low
- **Status:** Open

The header comment for `parse_context_json()` lists only three keys in the expected schema:
```cpp
//   {
//     "app":       "<bundle-id>",
//     "window":    "<window-title>",
//     "selected":  "<selected-text>"
//   }
```
The implementation (prompt_builder.cpp:221–234) also reads `"clipboard"` and `"language"`, both of which are actively sent by `ContextBuilder.swift`. A developer reading only the header would not know to include these fields and would observe silent degradation (English-only output regardless of locale; no clipboard context in prompts).

**Fix:** Add `"clipboard"` and `"language"` to the schema comment. The wire-format line at line 15 in the struct block already documents all five fields correctly — the `parse_context_json` doc block should match it.

---

### Bug 27 — `recvJSONSync()` POLLHUP-before-POLLIN loses final engine messages
- **File:** `app/OpenVerb/Engine/EngineClient.swift:277-280` + `:481-489`
- **Severity:** Medium
- **Status:** Open

`recvJSONSync()` checks `POLLHUP | POLLERR` before `POLLIN`. When the engine sends a final message (error/result) and immediately closes the connection, `poll()` returns with both `POLLIN` and `POLLHUP` set. The POLLHUP branch fires first, throwing `connectionClosed` — the data sitting in the socket read buffer is never read. This causes the client to see a generic "connection dropped" error instead of the actual engine error with its diagnostic code and message. The Phase 2 monitor has the same issue at line 481.

**Repro:**
1. Engine encounters an internal error, sends `{"type":"error","code":"inference_failed","message":"..."}` then closes the client socket
2. Client's `poll()` returns `POLLIN | POLLHUP`
3. POLLHUP check fires first → throws `EngineClientError.connectionClosed`
4. Error message is lost; user sees "Connection lost" instead of the real error

**Fix:** Check `POLLIN` first and drain the socket. Only treat `POLLHUP` as a close after `read()` returns 0 (EOF after draining).

---

### Bug 28 — Bug 2 regression: `socketReadLock` absent, Phase 2 monitor and `drainResult()` race on `fd`
- **File:** `app/OpenVerb/Engine/EngineClient.swift:253-301` (recvJSONSync) + `:506-508` (monitor calls recvJSONSync)
- **Severity:** High
- **Status:** Open

Bug 2 was marked "Fixed" with a `socketReadLock: NSLock` serializing the `poll()+read()+recvBuffer.append()` block. The lock is not present in the current code — either the fix was reverted during refactoring or never applied. `recvJSONSync()` is called concurrently from two threads:
1. **ioQueue** — via `receiveMessage()` → `drainResult()`
2. **Detached Task** — via Phase 2 monitor's `runPhase2Monitor()`

The `recvLock` (NSLock) only protects `recvBuffer` mutations. The `poll()` and `read()` system calls on `self.fd` are unprotected. Two threads racing on `read()` can split a single message's bytes between them, producing two incomplete halves that neither thread can decode. Additionally, `stopPhase2Monitor()` does not wait for the monitor Task to exit — `drainResult()` starts reading immediately, overlapping with the monitor's final `recvJSONSync(timeoutMs: 100)` call.

**Repro:**
1. ⌥Space → record → ⌥Space → inference starts, Phase 2 monitor running
2. ⌥Space again (stop recording) → `stopPhase2Monitor()` sets flag, sends wakeup byte
3. `sendEndOfAudio()` → `drainResult()` dispatches `recvJSONSync()` to ioQueue
4. Monitor's last `recvJSONSync(timeoutMs: 100)` is still inside `poll()` or `read()`
5. Both threads race on `read(fd)` — kernel splits bytes between them
6. One or both decode failures → spurious error or lost result

**Fix:** Re-introduce `socketReadLock: NSLock` in `recvJSONSync()` wrapping the entire `poll()+read()+recvBuffer.append()` block. Alternatively, change `stopPhase2Monitor()` to await the monitor Task's completion before returning.

---

### Bug 29 — `ModelDownloader.destinationURL` hardcoded, ignores `AppSettings.modelDirectory`
- **File:** `app/OpenVerb/Model/ModelDownloader.swift:60-64`
- **Severity:** Medium
- **Status:** Open

Related to Bug 23 (EngineManager snapshot) but distinct: `ModelDownloader.init()` always constructs `destinationURL` from `~/.openverb/models/` without reading `AppSettings.shared.modelDirectory`. If the user changes the model directory in Preferences and then triggers a re-download (e.g. deletes the model and relaunches → onboarding), the download writes to `~/.openverb/models/` while `EngineManager` looks at the user's chosen directory. The model is downloaded but not found on the next launch.

```swift
// Current (hardcoded):
let modelDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".openverb/models")

// Should read from settings:
let dir = AppSettings.shared.modelDirectory.isEmpty
    ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openverb/models")
    : URL(fileURLWithPath: AppSettings.shared.modelDirectory)
```

**Fix:** Accept a `modelDirectory: URL` parameter in `init()`. Pass `AppSettings.shared.modelDirectory` from `showOnboarding()`.

---

### Bug 30 — `TextInjector.injectPerCharacter()` missing focus transfer and panel dismissal
- **File:** `app/OpenVerb/Output/TextInjector.swift:151-166`
- **Severity:** Medium
- **Status:** Open

Unlike `inject()`, `injectPerCharacter()` posts CGEvent keystrokes without:
1. Hiding the recording window (`window.orderOut(nil)`)
2. Activating the target app (`targetApp.activate(options: [])`)
3. Waiting for focus transfer (50 ms delay)

If called while the floating panel is still visible, OpenVerb's panel retains key-window status and all keystrokes are delivered to the wrong app (or to no app). The method signature doesn't accept `targetApp` or `window` parameters, making correct usage impossible for any caller.

The requirements (Step 49) note this is NOT auto-triggered and is explicitly callable only, but any future integration point requires focus transfer — the current API makes it impossible to do correctly.

**Fix:** Add `targetApp: NSRunningApplication` and `window: RecordingWindow` parameters. Mirror the focus transfer sequence from `inject()` before the keystroke loop.

---

### Bug 31 — `PreferencesView` hotkey key name table missing ANSI punctuation keys
- **File:** `app/OpenVerb/UI/PreferencesView.swift:200-211`
- **Severity:** Low
- **Status:** Open

The `keyNames` dictionary in `hotkeyDescription` is missing ANSI key codes for common punctuation keys that the ShortcutRecorder can capture:

| keyCode | Key | Current label |
|---------|-----|---------------|
| 0x18 | `=` | `Key(24)` |
| 0x1B | `-` | `Key(27)` |
| 0x1E | `]` | `Key(30)` |
| 0x21 | `[` | `Key(33)` |
| 0x27 | `'` | `Key(39)` |
| 0x29 | `;` | `Key(41)` |
| 0x2A | `\` | `Key(42)` |
| 0x2B | `,` | `Key(43)` |
| 0x2C | `/` | `Key(44)` |
| 0x2F | `.` | `Key(47)` |

If the user records a hotkey like ⌥`=` via ShortcutRecorder, the label reads "⌥Key(24)" instead of "⌥=". The `TextInjector.charToKeyCode` table has the same keys mapped correctly — only the Preferences display is incomplete.

**Fix:** Add the missing entries to the `keyNames` dictionary in `PreferencesView`.
