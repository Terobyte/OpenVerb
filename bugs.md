# OpenVerb Bug Tracker

Sorted by severity: crashes and data loss first, cosmetic and test gaps last.
`[tested]` = failing red test exists. Green = bug fixed.

---

## High — real crash or data loss under specific conditions

**Bug 86** [tested] — Download progress shows billions of percent when server omits `Content-Length`
`ModelDownloader.swift:187` — `max(totalBytesExpectedToWrite, 1)` converts `-1` (NSURLSessionTransferSizeUnknown) to `1`. With a 1.5 GB file, `progress ≈ 1_500_000_000`. Displayed as `Int(progress * 100)%`.

**Bug 87** [tested] — SHA256 sentinel `"TBD_PIN_BEFORE_RELEASE"` skips all security verification; test never catches it
`ModelDownloader.swift:151–153, ModelDownloaderTests.swift:6–8` — `testSHA256ConstantsExist` only checks `!isEmpty`. Sentinel passes. Release build accepts corrupted or malicious models silently.

**Bug 88** [tested] — Every injection permanently destroys non-string clipboard content (RTF, images, files)
`TextInjector.swift:57–99` — Only `pasteboard.string(forType: .string)` is saved. `clearContents()` removes all types. Restore writes only plain text. Copy a file in Finder, then dictate → file path gone forever.

**Bug 89** [tested] — Key-up CGEvent silently dropped → `V` key stuck system-wide
`TextInjector.swift:111–119` — If key-down posts but key-up `CGEvent` creation returns nil, no key-up is ever sent. `V` is "held" in the HID stream until the user physically presses and releases it.

**Bug 90** [tested] — Transcription text leaked in cleartext clipboard when dictating into a password field
`TextInjector.swift:41–103` — No check for `SecureInputEnabled` or `AXRole`. Full transcription sits on `NSPasteboard.general` for 300 ms in plaintext; any process can read it.

**Bug 91** [tested] — Concurrent `download()` calls both pass `isDownloading` guard — duplicate downloads
`ModelDownloader.swift:82, 95` — Guard reads `isDownloading`; write is deferred to a `MainActor.run` 13 lines later. Second call in that window passes, both calls invalidate each other's session.

**Bug 92** [tested] — Onboarding mic denial deadlocks — user permanently stuck
`OnboardingView.swift:68–79` — `step` only advances on `granted == true`. After denial macOS never re-prompts; tapping button again fires `false` immediately. No error message, no Skip. Onboarding cannot complete.

**Bug 93** [tested] — Engine sends `polishedResult` without `result` → app stuck in `.inferring` for 3 minutes
`OpenVerbApp.swift:852–857` — `polishedResult` is non-terminal. Without a `result` message the while-loop runs for 180 seconds. Escape disabled; user cannot start a new session.

**Bug 94** [tested] — `injectPerCharacter()` shift-detection broken for punctuation (`!@#$%^&*`)
`TextInjector.swift:142–148` — `char != char.lowercased()` returns `false` for all shifted punctuation (no lowercase form). `!` injects as `1`, `@` as `2`, etc.

---

## Medium — real bugs with narrower trigger conditions

**Bug 95** [tested] — `recvJSONSync` races on `fd` between `pollfd` setup and `read()` syscall
`EngineClient.swift:323, 340` — `disconnect()` can close `fd` while `poll()` is blocked; subsequent `read(fd,...)` re-reads `-1` → `EBADF` instead of clean `connectionClosed`.

**Bug 96** [tested] — `ensureRunning()` blocks MainActor 500 ms via synchronous `waitForProcessExit`
`EngineManager.swift:247` — Spins `RunLoop.current.run(until:)` on the main actor for up to 500 ms on every cold-start or crash-recovery. UI is unresponsive during that window.

**Bug 97** [tested] — `handleCrash()` silent-return on dedup — callers can't distinguish dedup from success
`EngineManager.swift:359` — `guard !isRecovering else { return }` returns `Void`. If the first recovery throws `crashLoop`, the second caller sees no error and assumes recovery is running; engine stays dead.

**Bug 98** [tested] — Phase 2 monitor and `drainResult` both fire `onPartialResult` for the same message
`EngineClient.swift:617, OpenVerbApp.swift:846` — No guard equivalent to `callOnErrorIfLive` for partials. During `recording→inferring` handoff the same partial result is appended to `livePartialText` twice.

**Bug 99** [tested] — `livePartialText` appended after idle-transition clear — stale text from previous session
`AppState.swift:91, OpenVerbApp.swift:265–269` — `onPartialResult` enqueues a `Task { @MainActor }`. If the session ends and `livePartialText` is cleared before the Task runs, stale text is appended to the now-idle state.

**Bug 100** [tested] — `remainingInferenceMs` not cleared on `ERROR→PREPARING` — stale countdown in new session
`AppState.swift:234–255` — Only cleared on `.idle`. After `INFERRING→ERROR→PREPARING` retry, the UI shows the countdown from the failed session during the new preparing phase.

**Bug 101** [tested] — `NSPasteboard.string` fallback in `ContextBuilder.build` called off main thread
`ContextBuilder.swift:99` — When `clipboardSnapshot` is nil and `includeClipboard` is true, `NSPasteboard.general.string(forType:)` is called from the cooperative thread pool. NSPasteboard requires main thread.

**Bug 102** [tested] — Surrogate-pair split: UTF-16 cursor offset can bisect an emoji grapheme cluster
`AccessibilityReader.swift:139–148` — `NSString.substring(to: cursorPos)` at a UTF-16 offset inside a surrogate pair produces a lone surrogate → corrupt UTF-8 passed as context to the engine.

**Bug 103** [tested] — `hotkeyKeyCode = 0` (A key) treated as "not set" — binding silently reverts on restart
`AppSettings.swift:208–209` — `defaults.integer(forKey:)` returns `0` for both absent and stored `0x00`. Binding the hotkey to `⌥A` reverts to `⌥Space` on every launch.

**Bug 104** [tested] — `isDownloading` cancel race: rapid double-tap overwrites valid `resumeData` with nil
`ModelDownloader.swift:110–117` — `isDownloading = false` is written async. Second cancel fires `cancel(byProducingResumeData:)` on an already-cancelled task, delivering nil that overwrites the valid resume token.

**Bug 105** [tested] — `configure()` has no retry watchdog — hotkey silently dies on tap failure during reconfiguration
`HotkeyManager.swift:100–103` — `register()` starts the watchdog on failure. `configure()` does not. If the tap fails mid-session (permissions revoked), the hotkey is permanently dead with no recovery.

**Bug 106** [tested] — `showConflictAlert` re-enters `installEventTap` which re-enters `showConflictAlert` — stack overflow on double conflict
`HotkeyManager.swift:365–371, 113–156` — If both the original and alternative key fail tap creation, `NSAlert.runModal()` is called inside an existing `runModal()` session.

**Bug 107** [tested] — `ShortcutCaptureView.deinit` calls `NSEvent.removeMonitor` — may not run on main thread
`ShortcutRecorder.swift:54–58` — `deinit` can run on whichever thread drops the last reference. `NSEvent.removeMonitor` is AppKit — main thread only.

**Bug 108** [tested] — `AppSettings.shared` static let accessible cross-actor — first access may initialize off main actor
`AppSettings.swift:28–29, 37` — Class is `@MainActor` but `static let shared` lazy-initializes on first access. Access from a non-`@MainActor` context runs `init()` off the main actor.

**Bug 109** [tested] — Markdown ordered-list regex never matches — `^\d+\\. ` matches a literal backslash, not a dot
`ClipboardStyle.swift:37` — Raw string `#"^\d+\\. "#` passes `^\d+\\. ` to the regex engine, matching `"1\. "` not `"1. "`. Ordered-list clipboard content is never detected as Markdown.

**Bug 110** [tested] — `onPartialResult` ignores `chunkId` and `isFinal` — no dedup on retransmit
`OpenVerbApp.swift:265–270` — Both fields discarded. Engine retransmit appends text twice. Cumulative partials would produce doubled text in `livePartialText`.

**Bug 111** [tested] — `handleSleep()` sets `.stopped` synchronously before async `disconnect()` closes `fd`
`EngineManager.swift:500–511` — Rapid sleep/wake: `handleWake()` calls `connectSync()` which sees `fd != -1` (disconnect not yet run), returns early believing connected, then `sendPing()` writes to a half-closed socket.

**Bug 112** [tested] — Stale `resumeData` never cleared when next download starts fresh
`ModelDownloader.swift:98–103` — `resumeData` only cleared on SHA256 failure or completion. Cancel → delete partial file → retry attempts to resume from stale data, potentially writing a corrupt model.

**Bug 113** [tested] — `drainResult` processes one message after `abortAndRestart()` bumps `drainGeneration`
`OpenVerbApp.swift:803–847` — While-condition checked at top. After `await receiveMessage()` resumes, one message is processed (including `livePartialText +=`) before stale-generation exit. Text from aborted session leaks into new session.

**Bug 114** [tested] — `waitForProcessExit` busy-waits on cooperative thread — starves thread pool
`EngineManager.swift:344–350` — `RunLoop.current.run(until:)` on a cooperative thread has no sources; spin-waits 50 ms per iteration. Burns a thread pool slot for the full 500 ms on every `shutdown()`.

**Bug 115** [tested] — Language picker shows no selection for unsupported system locales
`AppSettings.swift:221, PreferencesView.swift:77–92` — Picker only offers 6 languages. Any other system locale (Chinese, Arabic, Portuguese) leaves picker with no selection; unrecognized code passed to engine.

**Bug 116** [tested] — Concurrent `inject()` calls interleave clipboard state
`TextInjector.swift:41–103` — No actor isolation. A stale `drainResult` Task can call `inject()` while a new session injects. `savedClipboard` of one call captures transcription text written by the other.

**Bug 117** [tested] — `activate(options: [])` deprecated and more often silently fails on macOS 14+
`CommandExecutor.swift:142, TextInjector.swift:72, 175` — On Sonoma, activation without `.activateIgnoringOtherApps` is restricted more aggressively. Code logs warning and proceeds; injected text silently lost when target app isn't frontmost.

**Bug 118** [tested] — `RecordingHUDBugsTests` resolves source paths against CWD — fails silently on CI
`RecordingHUDBugsTests.swift:12–15` — `URL(fileURLWithPath: relativePath)` fails when CWD ≠ `app/`. Tests report "Cannot read file" instead of the intended assertion, masking actual regressions.

**Bug M2** [tested] — `ring_buffer.cpp`: `reset()` + concurrent `read_all()` — `read_idx_` overtakes `write_idx_`
`ring_buffer.cpp` — Index inversion race produces reads of uninitialized data.

**Bug M6** [tested] — `g_interrupted` global: SIGINT kills entire server instead of per-session isolation
`session.cpp` — A single SIGINT terminates all active sessions. No per-session cancellation.

**Bug M7** [tested] — Polish inference runs on dead connection after `ConnectionClosed` — wasted GPU
`session.cpp:341–347` — Polishing inference not gated on connection liveness.

**Bug M8** [tested] — `reinterpret_cast<int16_t*>` without alignment guarantee + odd-frame truncation
`session.cpp:364–366` — Pointer alignment unchecked; odd byte count silently drops last sample.

**Bug M9** [tested] — `load_thread.join()` blocks indefinitely on hung model load
`session.cpp:226–257` — No timeout. Corrupt model file or I/O stall freezes the session thread permanently.

**Bug M10** [tested] — `strip_trailing_punct` handles ASCII only — CJK punctuation not stripped
`parser.cpp` — `。、）` and other Unicode punctuation appear at end of transcription output.

**Bug M11** [tested] — `infer()` with empty `audio_pcm` and no VAD → null bitmap → crash
`llama_context.cpp` — Zero-length audio without VAD produces null feature bitmap, null-pointer dereference inside inference.

**Bug M12** [tested] — Log rotation: `fclose` → `fopen` failure silently drops all subsequent logs
`log.cpp` — File handle set to null on open failure; all subsequent writes silently discarded.

---

## Low — edge cases, fragile tests, cosmetic issues

**Bug 119** [tested] — `recvBuffer` not cleared if `connectSync` called while already connected — stale bytes
`EngineClient.swift:130–131` — Guard `fd == -1 else { return }` skips buffer reset. Prior session's leftover bytes returned as a new message, triggering spurious protocol errors.

**Bug 120** [tested] — `isConnected` calls `ioQueue.sync` from MainActor — latent deadlock
`EngineClient.swift:200` — Any future `ioQueue` block dispatching back to MainActor would deadlock.

**Bug 121** [tested] — Double `configure()` + `register()` on app launch installs tap twice
`OpenVerbApp.swift:186–199` — Two `CGEvent.tapCreate` calls at startup; first tap torn down immediately. Brief window where a keypress fires `handleCGKeyEvent` with no callbacks assigned.

**Bug 122** [tested] — `autoClearTimer` guard `!Task.isCancelled` after `catch { return }` is dead code
`AppState.swift:302` — `Task.sleep` throws on cancellation; `catch` returns. Post-catch guard is unreachable via cancellation path.

**Bug 123** [tested] — `reset()` skips `modelDirectory` trailing-slash normalization applied in `init()`
`AppSettings.swift:272–273` — Asymmetric stored values between first-launch and post-reset state.

**Bug 124** [tested] — `hotkeyModifiers = 0` (no modifiers) treated as "not set" on reload
`AppSettings.swift:211–212` — Same sentinel ambiguity as Bug 103 but for modifier flags.

**Bug 125** [tested] — `updateNSView` no-op leaves ShortcutRecorder in recording state after external reset
`ShortcutRecorder.swift:31` — "Reset to Default" fires while recorder active → `updateNSView` ignored; next keypress overwrites the reset value.

**Bug 126** [tested] — `detectFormality` substring match — casual markers fire inside unrelated words
`ClipboardStyle.swift:55–60` — `"lol"` in `"alcohol"`, `"imo"` in Italian `-imo` words. Scientific text misclassified as casual.

**Bug 127** [tested] — Pre-buffer audio silently lost on `audioEngine.start()` failure
`AudioSession.swift:148–163` — Tap fires and fills `preBuffer` before `start()` throws. Rollback clears buffer with no notification; first successful retry sees empty pre-buffer.

**Bug 128** [tested] — Stale waveform callbacks delivered after `stop()` — waveform animates briefly post-recording
`AudioSession.swift:309–315` — Queued `DispatchQueue.main.async` blocks cannot be cancelled. Waveform shows one extra buffer after session ends.

**Bug 129** [tested] — `commitSendCallback` + interim-frame ordering race — out-of-order frame to engine
`AudioSession.swift:198–205, OpenVerbApp.swift:720–729` — Audio thread can dispatch live frame to `ioQueue` before caller's interim for-loop submits interim frames. Chronologically earlier frame arrives later.

**Bug 130** [tested] — `testSetAndGetCustomHotkey` never tests UserDefaults round-trip
`AppSettingsTests.swift:38–43` — Sets and reads from the same in-memory instance. Persistence path completely untested.

**Bug 131** [tested] — Test suite shares one UserDefaults suite name — fragile cross-test isolation
`AppSettingsTests.swift:6–9` — In-memory cache behavior after `removePersistentDomain` is implementation-defined.

**Bug 132** [tested] — `ContextBuilderTests` asserts `ctx["clipboard"]` nil — key never exists; tests vacuously pass
`ContextBuilderTests.swift:73–93` — Production writes `"clipboard_style"`, never `"clipboard"`. All three tests always pass regardless of what production code emits.

**Bug 133** [tested] — `AccessibilityReaderTests` tests only the mock — zero coverage of real implementation
`AccessibilityReaderTests.swift:14–41` — All four tests instantiate `MockAccessibilityReader`. Any regression in the real `AccessibilityReader` is invisible.

**Bug 134** [tested] — `PartialAccumulationTests` never exercises `AppState.livePartialText` accumulation
`PartialAccumulationTests.swift:23–86` — Tests inject a local closure. Production path (`appState.livePartialText += text`) untested.

**Bug 135** [tested] — `testQueueStatusDoesNotFirePartialCallback` is a tautology — always passes
`PartialAccumulationTests.swift:135–151` — `if case .partialResult = queueStatusMsg` can never match. `XCTAssertFalse(fired)` proves nothing.

**Bug 136** [tested] — `livePartialText` not cleared on `.error` transition — stale transcript visible during error window
`AppState.swift:280–305` — `.error` entry effects only clear `preparingSubtitle`. Up to 5 seconds of stale partial transcript visible alongside the error message.

**Bug 137** [tested] — `polishedText` and `remainingInferenceMs` lack `private(set)` — invariant bypass
`AppState.swift:86, 95` — External code can set these without going through state transitions, bypassing cleanup logic in `applyEntryEffects`.

**Bug 138** [tested] — `testBug1` wrong first assertion — fails at wrong line when Bug 1 and Bug 39 coexist
`BugsMDTDDTests.swift:44–55` — Asserts `!vm.amplitudes.isEmpty` at line 49 before reset. If `updateAmplitude` is async (Bug 1), test fails here with misleading message, masking the actual reset bug.

**Bug 139** [tested] — `autoClearTimer` cancellation is timing-sensitive — intermittent test flakiness under load
`AppState.swift:295–305, BugsMDTDDTests.swift:71–85` — If the 50 ms timer fires before `cancel()` is called in `transition(to: .preparing)`, the test incorrectly sees `.idle` instead of `.preparing`.

**Bug 140** [tested] — `testBug27` search window of 3000 chars is fragile against future function growth
`OpenBugsNegativeTests.swift:248` — `recvJSONSync` is already ~3600 chars. Next significant edit pushes POLLHUP/POLLIN guards out of the window; test reports infrastructure failure instead of bug regression.

---

## Deferred

_(none)_
