# Parallel Recording Pipeline Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the "warm-up" first-recording failure and back-to-back session failures by decoupling audio capture from engine state via a ring buffer, while adding live partial transcription display.

**Architecture:** An `AudioRingBuffer` (300 s, ~10 MB) is written continuously from the AVAudioEngine tap. A new `AudioPipeline` orchestrator runs a detached consumer Task that tail-follows the ring buffer and streams chunks to the engine live. The engine C++ is fixed to bind the socket only AFTER `ensure_loaded()` completes, inverting the startup invariant.

**Tech Stack:** Swift 5.10+, AVFoundation, C++ (CMake), os_unfair_lock, Swift structured concurrency (Task.detached, CheckedContinuation).

**Spec:** `docs/superpowers/specs/2026-04-21-parallel-recording-pipeline-design.md`

---

## File Map

### New files
| File | Responsibility |
|------|----------------|
| `app/OpenVerb/Input/AudioRingBuffer.swift` | Thread-safe PCM ring buffer: `write` (audio thread), `readNext` async (detached Task), `markStart/markEnd/clear/metrics` per Handle |
| `app/OpenVerb/Pipeline/AudioPipeline.swift` | `@MainActor` orchestrator: state machine + `beginRecording/endRecording/cancel`; `streamLive` private `Task.detached` consumer |
| `app/OpenVerb/UI/SubtitlePanel.swift` | Floating `NSPanel` below `RecordingWindow`, renders `livePartialText` at 16 pt |
| `app/OpenVerbTests/AudioRingBufferTests.swift` | Unit tests for ring buffer |
| `app/OpenVerbTests/AudioPipelineTests.swift` | Unit tests for pipeline state machine (mock EngineClient) |

### Modified files
| File | Change |
|------|--------|
| `engine/src/main.cpp:147-150` | Add `engine.ensure_loaded();` before `IpcServer` construction |
| `engine/src/ipc/server.cpp:97-110, 276-278` | Remove `preload_thread_` launch block and join in `stop()` |
| `engine/src/ipc/server.h:38` | Remove `preload_thread_` field declaration |
| `app/OpenVerb/Engine/EngineManager.swift:272-284` | Poll deadline 5 s → 30 s; update error message |
| `app/OpenVerbTests/EngineManagerTests.swift` | Add `testEnsureRunning_timeout30s` |
| `app/OpenVerb/Engine/Constants.swift` | Phase 5: add `USE_RING_BUFFER_PIPELINE`; Phase 7: remove it |
| `app/OpenVerb/Input/AudioSession.swift` | Phase 5: remove `preBuffer/sendCallback/flushPreBuffer/commitSendCallback/syncOnIOQueue`; write chunks to `AudioRingBuffer` |
| `app/OpenVerb/App/OpenVerbApp.swift` | Phase 6: `startRecording` uses `AudioPipeline.beginRecording`; `stopRecording` uses `endRecording`; remove `drainGeneration/isDraining` |
| `app/OpenVerb/Engine/EngineClient.swift` | Phase 7: remove `startPhase2Monitor/stopPhase2Monitor/runPhase2Monitor/wakeRead/wakeWrite/phase2Error/phase2Lock/phase2MonitorStopped/phase2MonitorTask/callOnErrorIfLive` (~120 lines) |
| `app/OpenVerb/UI/RecordingWindow.swift` | Phase 8: create and show/hide `SubtitlePanel` |
| `app/OpenVerb/Settings/AppSettings.swift` | Phase 8: add `showSubtitlePanel: Bool = true` |

---

## Chunk 1: Engine Pre-warm Fix (Phases 1–2)

### Task 1: Remove preload_thread_ from C++ (server.cpp, server.h, main.cpp)

**Files:**
- Modify: `engine/src/ipc/server.cpp:97-110` (remove launch block)
- Modify: `engine/src/ipc/server.cpp:276-278` (remove join in stop())
- Modify: `engine/src/ipc/server.h:38` (remove field declaration)
- Modify: `engine/src/main.cpp:148-150` (add ensure_loaded before IpcServer)

- [ ] **Step 1.1: Open `engine/src/ipc/server.h`, delete line 38**

  Remove this line:
  ```cpp
  std::thread          preload_thread_;   // background model preload at startup
  ```
  Keep `#include <thread>` in server.h — `session_thread_` on line 39 also requires it.

- [ ] **Step 1.2: Open `engine/src/ipc/server.cpp`, remove preload block (lines 97-110)**

  Delete lines 97–110 inclusive (stopping before the `#if defined(__APPLE__)` memory-pressure block on line 112). The block to remove is:
  ```cpp
      // Preload the model in a background thread so the first session doesn't
      // pay the load cost.  The socket is already listening when this starts, so
      // ensureRunning() pings succeed immediately while the model loads.
      // If a session arrives before preload finishes, ensure_loaded() blocks on
      // engine_mutex_ until the background thread releases it — correct behaviour.
      preload_thread_ = std::thread([this]() {
          try {
              LOG_INFO("ipc: preloading model...");
              engine_.ensure_loaded();
              LOG_INFO("ipc: model preloaded");
          } catch (const std::exception& e) {
              LOG_WARN("ipc: preload failed (will retry on first session): %s", e.what());
          }
      });
  ```
  The `#if defined(__APPLE__)` block immediately after line 110 must NOT be deleted.

- [ ] **Step 1.3: In `engine/src/ipc/server.cpp` stop(), remove the preload join (lines 276-278)**

  Remove:
  ```cpp
      if (preload_thread_.joinable()) {
          preload_thread_.join();
      }
  ```

- [ ] **Step 1.4: In `engine/src/main.cpp`, add `engine.ensure_loaded()` before server construction**

  The `--listen` block currently reads:
  ```cpp
          openverb::Engine engine(cfg);
          openverb::IpcServer server(engine, cfg.model_idle_timeout_secs);
          server.start(cfg.socket_path);
  ```
  Change to:
  ```cpp
          openverb::Engine engine(cfg);
          engine.ensure_loaded();               // blocks 5-10 s; socket binds AFTER model is in RAM
          if (g_interrupted) { return 0; }      // Ctrl+C during load must not be swallowed
          openverb::IpcServer server(engine, cfg.model_idle_timeout_secs);
          server.start(cfg.socket_path);
  ```
  **Important:** `engine.ensure_loaded()` and the `g_interrupted` check must be INSIDE the existing `try { ... }` block (line 147), not before it. The surrounding `try` catches `std::exception` — placing them outside would leave a 5–10 s blocking call unguarded.

- [ ] **Step 1.5: Build the engine with CMake to verify no compilation errors**

  ```bash
  cd engine && cmake --build build 2>&1 | tail -30
  ```
  Expected: `[100%] Built target openverb-engine` with zero errors.

  If build fails because `<thread>` is now missing, add it back to server.h (needed for `session_thread_`).

- [ ] **Step 1.6: Commit**

  ```bash
  git add engine/src/ipc/server.cpp engine/src/ipc/server.h engine/src/main.cpp
  git commit -m "synchronous model preload before socket bind (root cause #1)"
  ```

---

### Task 2: Copy rebuilt binary into app bundle

**Files:**
- Binary: `engine/build/openverb-engine` → `app/OpenVerb/Resources/` (or wherever the Xcode target bundles it)

- [ ] **Step 2.1: Find where the app bundle expects the engine binary**

  ```bash
  find app -name "openverb-engine" 2>/dev/null
  ```
  Typical result: `app/OpenVerb/Resources/openverb-engine` or embedded via a Copy Files build phase.

- [ ] **Step 2.2: Copy the rebuilt binary**

  ```bash
  DEST=$(find app -name openverb-engine -not -path '*/build/*' -not -path '*/.worktree*' | head -1)
  if [ -z "$DEST" ]; then echo "ERROR: no existing openverb-engine found in app/ — check Xcode target Copy Files phase"; exit 1; fi
  cp engine/build/openverb-engine "$DEST"
  ```

- [ ] **Step 2.3: Commit the binary**

  ```bash
  git add -f app/OpenVerb/Resources/openverb-engine   # adjust path from step 2.1
  git commit -m "update bundled engine binary (synchronous preload)"
  ```

---

### Task 3: Swift poll deadline 5 s → 30 s

**Files:**
- Modify: `app/OpenVerb/Engine/EngineManager.swift:272-284`
- Modify: `app/OpenVerbTests/EngineManagerTests.swift`

- [ ] **Step 3.1: Write the failing test first**

  Add to `app/OpenVerbTests/EngineManagerTests.swift` (inside `EngineManagerTests` class):
  ```swift
  func testEnsureRunningPollDeadlineIs30Seconds() {
      // Read EngineManager.swift source and confirm the literal "30" appears
      // in the ensureRunning poll section (not just any random 30).
      let src = try! String(
          contentsOfFile: Bundle(for: EngineManager.self).bundlePath
              + "/../../../OpenVerb/Engine/EngineManager.swift",
          encoding: .utf8)
      XCTAssertTrue(src.contains("addingTimeInterval(30"),    // matches "30.0", "30)", "30 " etc.
                    "ensureRunning poll deadline must be 30 s (not 5 s) to outlast synchronous model load")
      XCTAssertFalse(src.contains("addingTimeInterval(5.0)"),
                     "Old 5-second deadline must be removed")
  }
  ```

- [ ] **Step 3.2: Run test to confirm it fails**

  ```bash
  cd app && swift test --filter EngineManagerTests/testEnsureRunningPollDeadlineIs30Seconds 2>&1 | tail -10
  ```
  Expected: FAIL — `addingTimeInterval(30.0) not found`.

- [ ] **Step 3.3: Update EngineManager.swift**

  In `app/OpenVerb/Engine/EngineManager.swift`, find (around line 272):
  ```swift
          // Poll up to 5 s.
          let deadline = Date().addingTimeInterval(5.0)
          while Date() < deadline {
  ```
  Replace with:
  ```swift
          // Poll up to 30 s — engine now blocks on ensure_loaded() (5-10 s) before socket bind.
          let deadline = Date().addingTimeInterval(30.0)
          while Date() < deadline {
  ```

  Also update the error message (line ~283):
  ```swift
          status = .error("Engine did not respond within 5 seconds")
  ```
  → 
  ```swift
          status = .error("Engine did not respond within 30 seconds")
  ```
  And `EngineManagerError.launchTimeout.description` (line ~617):
  ```swift
          case .launchTimeout:      return "engine did not respond within 5 seconds"
  ```
  →
  ```swift
          case .launchTimeout:      return "engine did not respond within 30 seconds"
  ```

  **Note on the spin-wait branch (line ~240):** There is a separate `spinDeadline = Date().addingTimeInterval(3.0)` loop that fires when a second `ensureRunning()` call arrives while one is already in flight. That deadline is 3 s (for the concurrent-caller spin, not the engine poll) and is intentionally left unchanged — it controls how long a duplicate caller waits, not how long we wait for the engine.

- [ ] **Step 3.4: Run test to confirm it passes**

  ```bash
  cd app && swift test --filter EngineManagerTests/testEnsureRunningPollDeadlineIs30Seconds 2>&1 | tail -10
  ```
  Expected: PASS.

- [ ] **Step 3.5: Run full test suite to confirm no regressions**

  ```bash
  cd app && swift test 2>&1 | tail -20
  ```
  Expected: all suites green.

- [ ] **Step 3.6: Commit**

  ```bash
  git add app/OpenVerb/Engine/EngineManager.swift app/OpenVerbTests/EngineManagerTests.swift
  git commit -m "extend ensureRunning poll timeout to 30 s for synchronous engine preload"
  ```

---

## Chunk 2: AudioRingBuffer (Phase 3)

### Task 4: AudioRingBuffer scaffold + single-handle write/read

**Files:**
- Create: `app/OpenVerb/Input/AudioRingBuffer.swift`
- Create: `app/OpenVerbTests/AudioRingBufferTests.swift`

- [ ] **Step 4.1: Write failing tests for write/read basic behavior**

  Create `app/OpenVerbTests/AudioRingBufferTests.swift`:
  ```swift
  import XCTest
  @testable import OpenVerb

  final class AudioRingBufferTests: XCTestCase {

      func testWriteReadPreservesOrder() async {
          let buf = AudioRingBuffer(capacitySeconds: 10, chunkBytes: 4, sampleRate: 1)
          let h = AudioRingBuffer.Handle(id: UUID())
          buf.markStart(handle: h, timestamp: 0)
          let d1 = Data([1,2,3,4])
          let d2 = Data([5,6,7,8])
          buf.write(d1, timestamp: 1.0, handle: h)
          buf.write(d2, timestamp: 2.0, handle: h)
          let r1 = await buf.readNext(handle: h, afterTimestamp: 0.0, maxWait: .milliseconds(100))
          let r2 = await buf.readNext(handle: h, afterTimestamp: 1.0, maxWait: .milliseconds(100))
          XCTAssertEqual(r1?.0, d1)
          XCTAssertEqual(r1?.1, 1.0)
          XCTAssertEqual(r2?.0, d2)
          XCTAssertEqual(r2?.1, 2.0)
      }

      func testReadNextReturnsNilOnTimeout() async {
          let buf = AudioRingBuffer(capacitySeconds: 10, chunkBytes: 4, sampleRate: 1)
          let h = AudioRingBuffer.Handle(id: UUID())
          buf.markStart(handle: h, timestamp: 0)
          let start = Date()
          let r = await buf.readNext(handle: h, afterTimestamp: 0.0, maxWait: .milliseconds(100))
          XCTAssertNil(r)
          XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09)
      }

      func testReadNextReturnsNilOnInvalidHandle() async {
          let buf = AudioRingBuffer(capacitySeconds: 10, chunkBytes: 4, sampleRate: 1)
          let h = AudioRingBuffer.Handle(id: UUID())
          // Never called markStart — handle unknown
          let r = await buf.readNext(handle: h, afterTimestamp: 0.0, maxWait: .milliseconds(50))
          XCTAssertNil(r)
      }
  }
  ```

- [ ] **Step 4.2: Run tests to confirm they fail**

  ```bash
  cd app && swift test --filter AudioRingBufferTests 2>&1 | tail -10
  ```
  Expected: FAIL — `AudioRingBuffer type not found`.

- [ ] **Step 4.3: Create AudioRingBuffer.swift scaffold**

  Create `app/OpenVerb/Input/AudioRingBuffer.swift`:
  ```swift
  import Foundation
  import os

  private let logger = Logger(subsystem: "io.openverb.app", category: "AudioRingBuffer")

  // AudioRingBuffer — thread-safe ring buffer of timestamped PCM chunks.
  // NOT actor-isolated. All methods safe from any thread (guarded by os_unfair_lock).
  // Capacity: capacitySeconds * sampleRate * 2 bytes, rounded to maxChunks * chunkBytes.
  //
  // Thread safety:
  //   write()    — safe from AVAudioEngine realtime audio thread. os_unfair_lock does
  //                not heap-allocate on lock/unlock. Logger.warning is os_log backed —
  //                async-safe and realtime-safe. continuation.resume() enqueues work on
  //                the cooperative pool (does not run inline) — safe from audio thread.
  //   readNext() — must only be called from a Task (not @MainActor). Blocks via
  //                CheckedContinuation until data arrives or maxWait elapses. Single-fire
  //                guarantee: both write() and the timeout Task operate under the same
  //                lock and nil state.waiter before firing — only one path sees a non-nil
  //                continuation.
  //   clear()    — safe from any thread. Removes the handle entry entirely to prevent
  //                unbounded growth (thousands of sessions → thousands of dead UUIDs).
  final class AudioRingBuffer {

      struct Handle: Hashable { let id: UUID }
      struct Metrics { let overflowCount: Int; let peakDepthChunks: Int }

      private struct Entry {
          let data: Data
          let timestamp: TimeInterval
      }

      private struct HandleState {
          var entries: [Entry] = []
          var startTimestamp: TimeInterval = 0
          var isValid: Bool = true
          var overflowCount: Int = 0
          var peakDepth: Int = 0
          var waiter: CheckedContinuation<(Data, TimeInterval)?, Never>?
          var waiterAfterTs: TimeInterval = 0

          // Custom init so markStart can write `HandleState(startTimestamp: ts)` —
          // Swift's memberwise init won't generate a partial init for a struct with
          // all default-value properties.
          init(startTimestamp: TimeInterval = 0) {
              self.startTimestamp = startTimestamp
          }
      }

      private var states: [UUID: HandleState] = [:]
      private let lock = OSAllocatedUnfairLock()
      private let maxChunks: Int

      init(capacitySeconds: Int = 300, chunkBytes: Int = 4096, sampleRate: Int = 16_000) {
          let bytes = capacitySeconds * sampleRate * 2
          maxChunks = max(1, bytes / chunkBytes)
      }

      // MARK: - Producer API (audio thread)

      func write(_ chunk: Data, timestamp: TimeInterval, handle: Handle) {
          var overflowCount = 0
          lock.lock()
          guard var state = states[handle.id], state.isValid else {
              lock.unlock()
              return
          }
          if state.entries.count >= maxChunks {
              state.entries.removeFirst()
              state.overflowCount += 1
              overflowCount = state.overflowCount
          }
          state.entries.append(Entry(data: chunk, timestamp: timestamp))
          state.peakDepth = max(state.peakDepth, state.entries.count)
          var continuationToFire: CheckedContinuation<(Data, TimeInterval)?, Never>? = nil
          var continuationValue: (Data, TimeInterval)? = nil
          if let waiter = state.waiter, timestamp > state.waiterAfterTs {
              // Single-fire guarantee: nil state.waiter under lock before firing.
              // Timeout Task reads nil and becomes a no-op.
              continuationToFire = waiter
              continuationValue = (chunk, timestamp)
              state.waiter = nil
          }
          states[handle.id] = state
          lock.unlock()
          if overflowCount > 0 {
              // Logger (os_log) is async-signal-safe and realtime-safe — no DispatchQueue needed.
              logger.warning("AudioRingBuffer: overflow #\(overflowCount) — dropped oldest chunk")
          }
          // continuation.resume enqueues on cooperative pool; does NOT run inline.
          continuationToFire?.resume(returning: continuationValue)
      }

      // MARK: - Consumer API (detached Task)

      // Returns (chunk, timestamp) for the next chunk with timestamp > afterTimestamp.
      // Returns nil if handle is invalidated or maxWait elapses.
      // Single-fire: write() and the timeout Task both nil state.waiter under lock before
      // calling resume(). Exactly one of them sees a non-nil continuation.
      func readNext(handle: Handle, afterTimestamp: TimeInterval,
                    maxWait: Duration) async -> (Data, TimeInterval)? {
          // Fast path: already buffered data
          lock.lock()
          if let state = states[handle.id], state.isValid,
             let entry = state.entries.first(where: { $0.timestamp > afterTimestamp }) {
              lock.unlock()
              return (entry.data, entry.timestamp)
          }
          lock.unlock()

          // Slow path: park the caller in a CheckedContinuation until write() or timeout.
          // Uses Task.detached for the timer instead of withTaskGroup to avoid the
          // cancelled-sleep-resumes-continuation structural risk.
          return await withCheckedContinuation { (cont: CheckedContinuation<(Data, TimeInterval)?, Never>) in
              self.lock.lock()
              guard var state = self.states[handle.id], state.isValid else {
                  self.lock.unlock()
                  cont.resume(returning: nil)
                  return
              }
              // TOCTOU window closed: re-check inside lock before parking.
              if let entry = state.entries.first(where: { $0.timestamp > afterTimestamp }) {
                  self.lock.unlock()
                  cont.resume(returning: (entry.data, entry.timestamp))
                  return
              }
              state.waiter = cont
              state.waiterAfterTs = afterTimestamp
              self.states[handle.id] = state
              self.lock.unlock()

              // Timeout: fire nil after maxWait if write()/clear() haven't already fired.
              Task.detached { [weak self] in
                  try? await Task.sleep(for: maxWait)
                  guard let self else { return }
                  var expired: CheckedContinuation<(Data, TimeInterval)?, Never>? = nil
                  self.lock.lock()
                  if var s = self.states[handle.id] {
                      expired = s.waiter   // nil if write() already fired (single-fire)
                      s.waiter = nil
                      self.states[handle.id] = s
                  }
                  self.lock.unlock()
                  expired?.resume(returning: nil)
              }
          }
      }

      // MARK: - Lifecycle

      // markStart: called after AVAudioEngine.start() tap is installed (not at hotkey time).
      func markStart(handle: Handle, timestamp: TimeInterval) {
          lock.lock()
          states[handle.id] = HandleState(startTimestamp: timestamp)
          lock.unlock()
      }

      func markEnd(handle: Handle, timestamp: TimeInterval) {
          lock.lock()
          states[handle.id]?.isValid = false
          lock.unlock()
      }

      func clear(handle: Handle) {
          var waiterToFire: CheckedContinuation<(Data, TimeInterval)?, Never>? = nil
          lock.lock()
          guard let state = states[handle.id] else {
              lock.unlock()
              return
          }
          waiterToFire = state.waiter
          states.removeValue(forKey: handle.id)   // remove entirely — prevents unbounded growth
          lock.unlock()
          waiterToFire?.resume(returning: nil)
      }

      func metrics(handle: Handle) -> Metrics {
          lock.lock()
          defer { lock.unlock() }
          guard let state = states[handle.id] else {
              return Metrics(overflowCount: 0, peakDepthChunks: 0)
          }
          return Metrics(overflowCount: state.overflowCount, peakDepthChunks: state.peakDepth)
      }
  }
  ```

- [ ] **Step 4.4: Run tests**

  ```bash
  cd app && swift test --filter AudioRingBufferTests 2>&1 | tail -15
  ```
  Expected: all 3 tests PASS.

- [ ] **Step 4.5: Commit**

  ```bash
  git add app/OpenVerb/Input/AudioRingBuffer.swift app/OpenVerbTests/AudioRingBufferTests.swift
  git commit -m "add AudioRingBuffer with write/readNext/markStart/clear"
  ```

---

### Task 5: AudioRingBuffer overflow + concurrent correctness

**Files:**
- Modify: `app/OpenVerbTests/AudioRingBufferTests.swift`

- [ ] **Step 5.1: Write overflow and concurrent tests**

  Append to `AudioRingBufferTests`:
  ```swift
      func testOverflowDropsOldest() {
          // capacitySeconds=1, sampleRate=1, chunkBytes=4 → maxChunks = (1*1*2)/4 = 0 → max(1,0)=1
          // Use sampleRate=2 → maxChunks = (1*2*2)/4 = 1 chunk max
          let buf = AudioRingBuffer(capacitySeconds: 1, chunkBytes: 4, sampleRate: 2)
          let h = AudioRingBuffer.Handle(id: UUID())
          buf.markStart(handle: h, timestamp: 0)
          buf.write(Data([1,2,3,4]), timestamp: 1.0, handle: h)
          buf.write(Data([5,6,7,8]), timestamp: 2.0, handle: h)  // overflows, drops first
          let m = buf.metrics(handle: h)
          XCTAssertEqual(m.overflowCount, 1)
      }

      func testOverflowOldestReadReturnsNewer() async {
          let buf = AudioRingBuffer(capacitySeconds: 1, chunkBytes: 4, sampleRate: 2)
          let h = AudioRingBuffer.Handle(id: UUID())
          buf.markStart(handle: h, timestamp: 0)
          buf.write(Data([1,2,3,4]), timestamp: 1.0, handle: h)
          buf.write(Data([5,6,7,8]), timestamp: 2.0, handle: h)  // evicts first
          // Consumer asks for ts > 0 — should get the surviving chunk (ts=2.0)
          let r = await buf.readNext(handle: h, afterTimestamp: 0.0, maxWait: .milliseconds(50))
          XCTAssertEqual(r?.1, 2.0, "After overflow, oldest surviving chunk is returned")
      }

      func testClearInvalidatesHandle() async {
          let buf = AudioRingBuffer(capacitySeconds: 10, chunkBytes: 4, sampleRate: 1)
          let h = AudioRingBuffer.Handle(id: UUID())
          buf.markStart(handle: h, timestamp: 0)
          buf.write(Data([1,2,3,4]), timestamp: 1.0, handle: h)
          buf.clear(handle: h)
          let r = await buf.readNext(handle: h, afterTimestamp: 0.0, maxWait: .milliseconds(50))
          XCTAssertNil(r, "clear() must invalidate handle — readNext must return nil")
      }

      func testClearWakesBlockedReader() async {
          let buf = AudioRingBuffer(capacitySeconds: 10, chunkBytes: 4, sampleRate: 1)
          let h = AudioRingBuffer.Handle(id: UUID())
          buf.markStart(handle: h, timestamp: 0)
          async let reader = buf.readNext(handle: h, afterTimestamp: 0.0, maxWait: .seconds(10))
          // Give reader ample time to park in continuation (20ms is too tight on a busy CI
          // host — 200ms is still fast and much more reliable).
          try? await Task.sleep(for: .milliseconds(200))
          buf.clear(handle: h)
          let r = await reader
          XCTAssertNil(r, "clear() must wake blocked readNext with nil (not hang)")
      }

      func testConcurrentWriteRead_noCorruption() async {
          // Use default capacity (2343 chunks at 16 kHz) so 200 writes never overflow.
          // sampleRate: 1 would give only 150-chunk capacity → 50 overflows → reader times out.
          let buf = AudioRingBuffer()
          let h = AudioRingBuffer.Handle(id: UUID())
          buf.markStart(handle: h, timestamp: 0)
          let total = 200
          // Writer Task: writes 200 chunks on a background thread
          let writer = Task.detached {
              for i in 0..<total {
                  buf.write(Data([UInt8(i & 0xFF), 0, 0, 0]),
                            timestamp: TimeInterval(i + 1), handle: h)
                  try? await Task.sleep(for: .microseconds(100))
              }
          }
          // Reader Task: reads 200 chunks sequentially.
          // maxWait: .seconds(1) — each write takes ~100 µs, 1 s is ample.
          // Do NOT use .seconds(5) — 200 chunks × 5 s = 16 min worst-case test time.
          var lastTs: TimeInterval = 0
          var readCount = 0
          for _ in 0..<total {
              guard let r = await buf.readNext(handle: h, afterTimestamp: lastTs,
                                               maxWait: .seconds(1)) else {
                  XCTFail("readNext timed out at chunk \(readCount)")
                  break
              }
              XCTAssertGreaterThan(r.1, lastTs, "timestamps must be strictly increasing")
              lastTs = r.1
              readCount += 1
          }
          await writer.value
          XCTAssertEqual(readCount, total, "All \(total) chunks must be received in order")
      }
  ```

- [ ] **Step 5.2: Run tests**

  ```bash
  cd app && swift test --filter AudioRingBufferTests 2>&1 | tail -20
  ```
  Expected: all tests PASS. If `testConcurrentWriteRead_noCorruption` is flaky, check the lock usage in `write()`.

- [ ] **Step 5.3: Commit**

  ```bash
  git add app/OpenVerbTests/AudioRingBufferTests.swift
  git commit -m "add ring buffer overflow and concurrent correctness tests"
  ```

---

## Chunk 3: AudioPipeline — State Machine (Phase 4)

### Task 6: AudioPipeline skeleton + state machine

**Files:**
- Create: `app/OpenVerb/Pipeline/AudioPipeline.swift`
- Create: `app/OpenVerbTests/AudioPipelineTests.swift`

First, note that `AudioPipeline` needs a mock-friendly `EngineClient`. Since `EngineClient` is a concrete class (not a protocol), tests will use the real class with a bad socket path to simulate a disconnected engine.

- [ ] **Step 6.1: Write failing tests for state transitions**

  Create `app/OpenVerbTests/AudioPipelineTests.swift`:
  ```swift
  import XCTest
  @testable import OpenVerb

  // AudioPipelineTests — exercises state machine transitions without a real engine.
  // All tests are @MainActor because AudioPipeline is @MainActor.
  @MainActor
  final class AudioPipelineTests: XCTestCase {

      private var ringBuffer: AudioRingBuffer!
      private var pipeline: AudioPipeline!

      override func setUp() async throws {
          ringBuffer = AudioRingBuffer()
          pipeline = AudioPipeline(ringBuffer: ringBuffer)
      }

      override func tearDown() async throws {
          pipeline = nil
          ringBuffer = nil
      }

      func testInitialStateIsIdle() {
          XCTAssertEqual(pipeline.state, .idle)
      }

      func testBeginRecordingTransitionsToCapturing() {
          let h = pipeline.beginRecording()
          XCTAssertEqual(pipeline.state, .capturing)
          XCTAssertNotNil(h)
      }

      func testBeginRecordingWhileCapturingIsNoOp() {
          let h1 = pipeline.beginRecording()
          let h2 = pipeline.beginRecording()  // second call while capturing
          XCTAssertEqual(pipeline.state, .capturing, "Double beginRecording must not change state")
          XCTAssertNil(h2, "Second beginRecording must return nil (no-op)")
          _ = h1
      }

      func testCancelFromCapturingTransitionsToIdle() {
          let h = pipeline.beginRecording()!
          pipeline.cancel(handle: h)
          XCTAssertEqual(pipeline.state, .idle)
      }

      func testStaleHandleIsNoOp() {
          let h = pipeline.beginRecording()!
          pipeline.cancel(handle: h)  // → idle
          XCTAssertEqual(pipeline.state, .idle)
          // Call with stale handle — must not crash or change state
          pipeline.cancel(handle: h)
          XCTAssertEqual(pipeline.state, .idle, "Stale handle cancel must be no-op")
      }

      func testEndRecordingFromIdleIsNoOp() {
          let staleHandle = AudioRingBuffer.Handle(id: UUID())
          pipeline.endRecording(handle: staleHandle)  // must not crash
          XCTAssertEqual(pipeline.state, .idle)
      }
  }
  ```

- [ ] **Step 6.2: Run tests to confirm they fail**

  ```bash
  cd app && swift test --filter AudioPipelineTests 2>&1 | tail -10
  ```
  Expected: FAIL — `AudioPipeline type not found`.

- [ ] **Step 6.3: Create `app/OpenVerb/Pipeline/` directory and AudioPipeline.swift**

  ```bash
  mkdir -p app/OpenVerb/Pipeline
  ```

  Create `app/OpenVerb/Pipeline/AudioPipeline.swift`:
  ```swift
  import Foundation
  import os

  private let logger = Logger(subsystem: "io.openverb.app", category: "AudioPipeline")

  // AudioPipeline — @MainActor orchestrator for a single recording session.
  //
  // Public API is @MainActor. The private consumer coroutine (streamLive) runs
  // as Task.detached so it never blocks the main actor between chunks.
  //
  // State machine:
  //   idle → capturing → streaming → finalizing → idle
  //                              ↘ error → streaming (retry)
  //   cancel(handle) from any state → idle

  @MainActor
  final class AudioPipeline {

      enum State: Equatable {
          case idle
          case capturing
          case streaming
          case finalizing
          case error(String)
      }

      private(set) var state: State = .idle
      // private(set) so AppDelegate can read activeHandle to call cancel/endRecording
      private(set) var activeHandle: AudioRingBuffer.Handle?

      private let ringBuffer: AudioRingBuffer

      var onResult: ((_ text: String, _ command: Command?) -> Void)?
      var onError: ((_ message: String) -> Void)?

      init(ringBuffer: AudioRingBuffer) {
          self.ringBuffer = ringBuffer
      }

      // MARK: - Public API

      // Returns a new Handle and transitions to .capturing.
      // Returns nil (no-op) if not in .idle state.
      @discardableResult
      func beginRecording() -> AudioRingBuffer.Handle? {
          guard state == .idle else {
              logger.debug("beginRecording: ignored (state = \(String(describing: state)))")
              return nil
          }
          let handle = AudioRingBuffer.Handle(id: UUID())
          activeHandle = handle
          state = .capturing
          ringBuffer.markStart(handle: handle, timestamp: Date().timeIntervalSince1970)
          logger.info("beginRecording: handle \(handle.id)")
          return handle
      }

      // Transitions streaming → finalizing. Consumer drains and awaits .result.
      // No-op if handle is stale or state is not .streaming/.capturing.
      func endRecording(handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle else {
              logger.debug("endRecording: stale handle, ignored")
              return
          }
          guard state == .streaming || state == .capturing else {
              logger.debug("endRecording: wrong state (\(String(describing: state))), ignored")
              return
          }
          state = .finalizing
          ringBuffer.markEnd(handle: handle, timestamp: Date().timeIntervalSince1970)
          logger.info("endRecording: handle \(handle.id)")
      }

      // Cancels session from any state → idle. Clears ring buffer for handle.
      func cancel(handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle else {
              logger.debug("cancel: stale handle, ignored")
              return
          }
          ringBuffer.clear(handle: handle)
          activeHandle = nil
          state = .idle
          logger.info("cancel: handle \(handle.id)")
      }

      // MARK: - Internal (called by streamLive Task)

      func transitionToStreaming(handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle, state == .capturing else { return }
          state = .streaming
      }

      func transitionToError(_ message: String, handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle else { return }
          state = .error(message)
      }

      func transitionToIdle(handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle else { return }
          ringBuffer.clear(handle: handle)
          activeHandle = nil
          state = .idle
      }
  }
  ```

- [ ] **Step 6.4: Run tests**

  ```bash
  cd app && swift test --filter AudioPipelineTests 2>&1 | tail -15
  ```
  Expected: all 6 state machine tests PASS.

- [ ] **Step 6.5: Commit**

  ```bash
  git add app/OpenVerb/Pipeline/AudioPipeline.swift app/OpenVerbTests/AudioPipelineTests.swift
  git commit -m "add AudioPipeline state machine (idle/capturing/streaming/finalizing/error)"
  ```

---

### Task 7: AudioPipeline consumer (streamLive) and integration wiring

The `streamLive` consumer is a private `Task.detached` coroutine. In this task, add the full engine interaction loop. Tests for the full path are integration tests (see Chunk 5); this task only adds the implementation.

**Files:**
- Modify: `app/OpenVerb/Pipeline/AudioPipeline.swift`

- [ ] **Step 7.0: Expose socketPath in EngineManager (access fix)**

  In `app/OpenVerb/Engine/EngineManager.swift`, line 62:
  ```swift
  // Before:
  private let socketPath: String
  // After (remove `private` — it's internal to the same module):
  let socketPath: String
  ```
  AudioPipeline.streamLive reads `engineManager.socketPath`; the current `private` access blocks compilation.

  Build to confirm:
  ```bash
  cd app && swift build 2>&1 | grep -E "error:|Build complete"
  ```

- [ ] **Step 7.1: Replace AudioPipeline.swift with full implementation (engine + streamLive)**

  This replaces the Task 6 state-machine-only scaffold entirely. If you skipped Task 6, create the file fresh. **Replacing the scaffold is intentional** — Task 6 existed only to make the state machine tests compile. Task 7 supersedes it. All Task 6 tests must still pass after this replacement.

  Replace the entire `AudioPipeline.swift` with:
  ```swift
  import Foundation
  import os

  private let logger = Logger(subsystem: "io.openverb.app", category: "AudioPipeline")

  @MainActor
  final class AudioPipeline {

      enum State: Equatable {
          case idle
          case capturing
          case streaming
          case finalizing
          case error(String)
      }

      private(set) var state: State = .idle
      // private(set) so AppDelegate can read activeHandle to call cancel/endRecording
      private(set) var activeHandle: AudioRingBuffer.Handle?

      private let ringBuffer: AudioRingBuffer
      private weak var engineManager: EngineManager?
      private weak var engineClient: EngineClient?

      var onResult: ((_ text: String, _ command: Command?) -> Void)?
      var onError: ((_ message: String) -> Void)?

      // Injected context builder callback (set by AppDelegate).
      // Declared `async` because ContextBuilder.build is async — called from
      // inside the Task.detached consumer, not from @MainActor directly.
      var contextProvider: (() async -> [String: String])?

      init(ringBuffer: AudioRingBuffer,
           engineManager: EngineManager? = nil,
           engineClient: EngineClient? = nil) {
          self.ringBuffer = ringBuffer
          self.engineManager = engineManager
          self.engineClient = engineClient
      }

      // MARK: - Public API

      @discardableResult
      func beginRecording() -> AudioRingBuffer.Handle? {
          guard state == .idle else {
              logger.debug("beginRecording: ignored (state = \(String(describing: state)))")
              return nil
          }
          let handle = AudioRingBuffer.Handle(id: UUID())
          activeHandle = handle
          state = .capturing
          ringBuffer.markStart(handle: handle, timestamp: Date().timeIntervalSince1970)
          // contextProvider is async — capture it inside the Task so await works.
          Task.detached(priority: .userInitiated) { [weak self] in
              let context = await self?.contextProvider?() ?? [:]
              await self?.streamLive(handle: handle, context: context)
          }
          logger.info("beginRecording: handle \(handle.id)")
          return handle
      }

      func endRecording(handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle else {
              logger.debug("endRecording: stale handle, ignored")
              return
          }
          guard state == .streaming || state == .capturing else {
              logger.debug("endRecording: wrong state (\(String(describing: state))), ignored")
              return
          }
          state = .finalizing
          ringBuffer.markEnd(handle: handle, timestamp: Date().timeIntervalSince1970)
          logger.info("endRecording: handle \(handle.id)")
      }

      func cancel(handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle else {
              logger.debug("cancel: stale handle, ignored")
              return
          }
          ringBuffer.clear(handle: handle)
          activeHandle = nil
          state = .idle
          logger.info("cancel: handle \(handle.id)")
      }

      // MARK: - Internal helpers (called from streamLive Task via MainActor.run)

      func transitionToStreaming(handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle, state == .capturing else { return }
          state = .streaming
      }

      func transitionToError(_ message: String, handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle else { return }
          state = .error(message)
      }

      func transitionToIdle(handle: AudioRingBuffer.Handle) {
          guard handle == activeHandle else { return }
          ringBuffer.clear(handle: handle)
          activeHandle = nil
          state = .idle
      }

      // MARK: - Private consumer (runs as Task.detached, NOT on MainActor)

      // streamLive: tail-follow consumer. Connects to engine, waits for .ready,
      // then streams chunks from ringBuffer until endRecording signals finalizing.
      // On engine error: calls handleCrash and resumes from lastSentTimestamp.
      nonisolated private func streamLive(handle: AudioRingBuffer.Handle,
                                          context: [String: String]) async {
          guard let engineManager = await MainActor.run(body: { [weak self] in
              self?.engineManager
          }) else { return }

          guard let client = await MainActor.run(body: { [weak self] in
              self?.engineClient
          }) else { return }

          // Wait for engine to be running (handles cold-start case)
          var waitAttempts = 0
          while await MainActor.run(body: { engineManager.status }) != .running {
              guard await MainActor.run(body: { [weak self] in self?.activeHandle == handle }) else {
                  return  // cancelled
              }
              try? await Task.sleep(for: .milliseconds(200))
              waitAttempts += 1
              if waitAttempts > 150 { // 30 s
                  await MainActor.run { [weak self] in
                      self?.transitionToError("Engine did not start within 30 s", handle: handle)
                  }
                  return
              }
          }

          // engineManager.socketPath must be `internal` (not `private`). See note in
          // Task 7: add `internal(set)` or remove `private` from EngineManager.socketPath.
          let socketPath = await MainActor.run(body: { engineManager.socketPath })

          // Connect and start session
          do {
              try await client.connect(path: socketPath)
              try await client.startSession(context: context)
              let readyMsg = try await client.receiveMessage(timeoutMs: 10_000)
              guard case .ready = readyMsg else {
                  await MainActor.run { [weak self] in
                      self?.transitionToError("Engine did not send .ready", handle: handle)
                  }
                  return
              }
          } catch {
              await MainActor.run { [weak self] in
                  self?.transitionToError("Engine connect failed: \(error)", handle: handle)
              }
              return
          }

          await MainActor.run { [weak self] in
              self?.transitionToStreaming(handle: handle)
          }

          // Stream chunks from ring buffer to engine
          var lastSentTimestamp: TimeInterval = 0
          let chunkMaxWait: Duration = .milliseconds(200)

          chunkLoop: while true {
              // Check if we should stop
              let currentState = await MainActor.run(body: { [weak self] in self?.state })
              guard currentState != .idle else { break chunkLoop }

              // Check handle still active
              guard await MainActor.run(body: { [weak self] in self?.activeHandle == handle }) else {
                  break chunkLoop
              }

              let chunk = await ringBuffer.readNext(handle: handle,
                                                   afterTimestamp: lastSentTimestamp,
                                                   maxWait: chunkMaxWait)
              guard let (data, ts) = chunk else {
                  // Timeout — check if finalizing
                  let st = await MainActor.run(body: { [weak self] in self?.state })
                  if st == .finalizing { break chunkLoop }
                  continue
              }

              // Send chunk to engine
              client.sendAudioFrame(data)
              lastSentTimestamp = ts
          }

          // Drain: send end-of-audio sentinel and await result
          let state = await MainActor.run(body: { [weak self] in self?.state })
          if state == .finalizing {
              do {
                  client.sendEndOfAudio()   // fire-and-forget (Void, non-throwing)
                  // Receive result (up to 3 min)
                  var done = false
                  while !done {
                      let msg = try await client.receiveMessage(timeoutMs: 180_000)
                      switch msg {
                      case .result(let text, let command):
                          done = true
                          await MainActor.run { [weak self] in
                              self?.onResult?(text, command)
                              self?.transitionToIdle(handle: handle)
                          }
                      case .progress(let pct):
                          logger.debug("Engine progress: \(pct)%")
                      case .partialResult(let text, _, _):
                          logger.debug("Partial: \(text)")
                      case .error(let code, let message):
                          // EngineClientError.engineError takes positional args — no labels
                          throw EngineClientError.engineError(code, message)
                      default:
                          break
                      }
                  }
              } catch {
                  logger.error("streamLive drain error: \(error)")
                  await MainActor.run { [weak self] in
                      self?.transitionToError("Drain failed: \(error)", handle: handle)
                      self?.onError?("Recording failed: \(error.localizedDescription)")
                  }
              }
          } else {
              // Cancelled mid-stream
              await MainActor.run { [weak self] in
                  self?.transitionToIdle(handle: handle)
              }
          }
      }
  }
  ```

  **Confirmed API signatures (verified against EngineClient.swift):**
  - `startSession(context:)` — exact name, takes `[String: String]`
  - `sendEndOfAudio()` — exact name, `Void` non-throwing (no `try`)
  - `receiveMessage(timeoutMs:)` — exact name, throwing async
  - `.partialResult(text: String, chunkId: Int, isFinal: Bool)` — labeled enum case; match as `.partialResult(let text, _, _)`
  - `EngineClientError.engineError` — positional `(String, String)`, **no labels**

  **Crash recovery note (issue #12 — Phase 2 monitor replacement):**
  The Phase 2 monitor previously detected engine crashes between sessions via POLLHUP. In AudioPipeline:
  - Mid-session crash: `receiveMessage(timeoutMs:)` throws → `transitionToError` + `onError` surfaces to user
  - Between-session crash: the next `client.connect(path:)` in the next `streamLive` call fails → same error path
  The user sees an error notification either way and can retry. EngineManager relaunches the engine on the next `ensureRunning()` call. No silent swallowing.

  **handleResult sync requirement (issue #7):**
  `onResult` is declared as `(String, Command?) -> Void` — a **synchronous** closure. `handleResult(text:command:)` extracted in Step 9.2 **must NOT be declared `async`**. If any of its sub-calls are async (e.g., if `engineManager.disconnect()` is async), wrap them in `Task { }` inside the sync method. The closure is called from `await MainActor.run { self?.onResult?(text, command) }` — the body of that closure is sync.

- [ ] **Step 7.2: Build to check for compile errors**

  ```bash
  cd app && swift build 2>&1 | tail -20
  ```
  Fix any type errors. The `Command` type, `ServerMessage` enum cases, and `EngineClientError` must match what's in `EngineClient.swift`.

- [ ] **Step 7.3: Run test suite**

  ```bash
  cd app && swift test 2>&1 | tail -20
  ```
  Expected: existing tests still PASS. AudioPipelineTests state machine tests PASS.

- [ ] **Step 7.4: Commit**

  ```bash
  git add app/OpenVerb/Pipeline/AudioPipeline.swift
  git commit -m "add streamLive consumer coroutine to AudioPipeline"
  ```

---

## Chunk 4: AudioSession Migration (Phase 5)

### Task 8: Feature flag + AudioSession writing to ring buffer

**Files:**
- Modify: `app/OpenVerb/Engine/Constants.swift`
- Modify: `app/OpenVerb/Input/AudioSession.swift`

- [ ] **Step 8.1: Add feature flag to Constants.swift**

  In `app/OpenVerb/Engine/Constants.swift`, add inside `enum Constants`:
  ```swift
      // Phase 5 migration flag. Flip to false to restore old preBuffer path.
      // Removed in Phase 7 after AudioPipeline proven stable in production.
      static let USE_RING_BUFFER_PIPELINE = true
  ```

- [ ] **Step 8.2: Write failing test for the new AudioSession ring buffer path**

  Add to `app/OpenVerbTests/AudioSessionTests.swift` (inside the existing test class):
  ```swift
  func testAudioSessionWritesToRingBufferWhenFlagEnabled() throws {
      // This test is a source-scan negative test — it verifies that when
      // USE_RING_BUFFER_PIPELINE is true, AudioSession writes to the ring buffer
      // rather than preBuffer. We scan the source for the expected patterns.
      guard Constants.USE_RING_BUFFER_PIPELINE else {
          throw XCTSkip("USE_RING_BUFFER_PIPELINE is false — ring buffer path not active")
      }
      let src = try String(
          contentsOfFile: Bundle(for: AudioSession.self).bundlePath
              + "/../../../OpenVerb/Input/AudioSession.swift",
          encoding: .utf8)
      XCTAssertTrue(src.contains("ringBuffer.write("),
                    "AudioSession must call ringBuffer.write() when flag is enabled")
      XCTAssertFalse(src.contains("preBuffer.append"),
                     "preBuffer.append must be removed when flag is enabled")
  }
  ```

- [ ] **Step 8.3: Run to confirm it fails**

  ```bash
  cd app && swift test --filter AudioSessionTests/testAudioSessionWritesToRingBufferWhenFlagEnabled 2>&1 | tail -10
  ```
  Expected: FAIL — `ringBuffer.write( not found`.

- [ ] **Step 8.4: Refactor AudioSession.swift**

  **What to remove** (when `USE_RING_BUFFER_PIPELINE == true`):
  - `private var preBuffer: [Data] = []` (keep declaration for `false` path or remove entirely under flag)
  - `private var sendCallback: ((Data) -> Void)?`
  - `flushPreBuffer()` method
  - `commitSendCallback()` method
  - The `preBuffer` append/cap logic in `processTapBuffer`
  - The `sendCallback` dispatch in `processTapBuffer`

  **Note:** `syncOnIOQueue()` is on `EngineClient`, NOT on `AudioSession` — do not look for it in AudioSession.

  **What to add**:

  `ringBuffer` and `ringBufferHandle` must be protected against the data race between the
  `@MainActor` writer (AppDelegate) and the realtime audio tap reader. Use `OSAllocatedUnfairLock`:
  ```swift
  var ringBuffer: AudioRingBuffer?   // written before tap installed — no race

  private let _handleLock = OSAllocatedUnfairLock()
  private var _ringBufferHandle: AudioRingBuffer.Handle?
  var ringBufferHandle: AudioRingBuffer.Handle? {
      get { _handleLock.withLock { _ringBufferHandle } }
      set { _handleLock.withLock { _ringBufferHandle = newValue } }
  }
  ```

  In `processTapBuffer`, after forming `chunk`:
  ```swift
  // Guard against nil handle — drop chunk rather than create a phantom UUID.
  guard let handle = ringBufferHandle else {
      logger.error("AudioSession: ringBufferHandle nil — dropping audio chunk")
      return
  }
  ringBuffer?.write(chunk, timestamp: Date().timeIntervalSince1970, handle: handle)
  ```

  `OSAllocatedUnfairLock` (macOS 13+) does not heap-allocate on lock/unlock — safe from the realtime audio thread.

  The `start()` signature stays the same (still has `waveformCallback`). The waveform callback still fires for each chunk. Only the send path changes.

  **Implementation approach**: Add `if Constants.USE_RING_BUFFER_PIPELINE { ... } else { /* old preBuffer logic */ }` inside `processTapBuffer` to enable rollback via flag flip. Remove the flag entirely in Phase 7.

  In `stop()`, under the flag, remove `sendCallback = nil` and `preBuffer.removeAll()`.

  After refactoring, `AudioSession.swift` should compile with `ringBuffer: AudioRingBuffer?` and `ringBufferHandle: AudioRingBuffer.Handle?` as `var` properties (injected pre-start by `AppDelegate`).

- [ ] **Step 8.5: Run tests**

  ```bash
  cd app && swift test --filter AudioSessionTests 2>&1 | tail -20
  ```
  Expected: all existing `AudioSessionTests` pass; new ring buffer test passes.

- [ ] **Step 8.6: Commit**

  ```bash
  git add app/OpenVerb/Engine/Constants.swift app/OpenVerb/Input/AudioSession.swift \
          app/OpenVerbTests/AudioSessionTests.swift
  git commit -m "migrate AudioSession to write to AudioRingBuffer (flag on)"
  ```

---

## Chunk 5: AppDelegate Integration (Phase 6)

### Task 9: Wire AudioPipeline into AppDelegate

**Files:**
- Modify: `app/OpenVerb/App/OpenVerbApp.swift`

This is the largest change. It replaces `flushPreBuffer`, `commitSendCallback`, `startPhase2Monitor`, `drainGeneration`, and `isDraining` with `AudioPipeline.beginRecording/endRecording/cancel`.

- [ ] **Step 9.1: Add AudioPipeline and AudioRingBuffer as lazy properties of AppDelegate**

  Add to AppDelegate's lazy property section:
  ```swift
  private lazy var ringBuffer = AudioRingBuffer()
  private lazy var audioPipeline = AudioPipeline(
      ringBuffer: ringBuffer,
      engineManager: engineManager,
      engineClient: engineManager.engineClient
  )
  ```

- [ ] **Step 9.2: Extract `handleResult(text:command:)` from drainResult**

  This step must happen BEFORE wiring `audioPipeline.onResult` (Step 9.3).
  In `OpenVerbApp.swift`, find the `.result(let text, let command)` case inside `drainResult()` — currently it calls `TextInjector.inject`, updates `appState`, and calls `engineManager.disconnect()`. Extract that entire block into:
  ```swift
  private func handleResult(text: String, command: Command?) {
      // Move the full .result case body here verbatim.
      // It includes: TextInjector.inject, appState.transition(.idle),
      // engineManager.disconnect(), maxDurationTimer?.cancel().
  }
  ```

- [ ] **Step 9.3: Wire AudioPipeline callbacks and AudioSession ring buffer**

  In `applicationDidFinishLaunching`, after `audioSession` is initialized but before `hotkeyManager.register()`:
  ```swift
  audioSession.ringBuffer = ringBuffer
  // ringBufferHandle is assigned in startRecording() just before audioSession.start()

  // ContextBuilder.build is `async` — contextProvider must be async.
  // Actual signature: build(targetApp:accessibilityApp:pasteboard:accessibilityReader:
  //                        clipboardSnapshot:includeClipboard:languageOverride:) async
  // pasteboard and accessibilityReader have defaults, so only 5 args are required.
  audioPipeline.contextProvider = { [weak self] in
      guard let self else { return [:] }
      return await ContextBuilder.build(
          targetApp:         self.appState.targetApp,
          accessibilityApp:  self.appState.targetApp as? NSRunningApplication,
          clipboardSnapshot: self.appSettings.includeClipboard
                               ? NSPasteboard.general.string(forType: .string)
                               : nil,
          includeClipboard:  self.appSettings.includeClipboard,
          languageOverride:  self.appSettings.language
      )
  }
  audioPipeline.onResult = { [weak self] text, command in
      guard let self else { return }
      self.handleResult(text: text, command: command)
  }
  audioPipeline.onError = { [weak self] message in
      guard let self else { return }
      self.appState.transition(to: .error(message))
  }
  ```

- [ ] **Step 9.4: Extract `scheduleMaxDurationTimer()` from connectAndRecord**

  The current `connectAndRecord()` contains inline timer scheduling (around lines 756-770 in `OpenVerbApp.swift` — run `grep -n "maxDurationTimer" app/OpenVerb/App/OpenVerbApp.swift` to find exact lines). Extract it into a private method before rewriting `startRecording()`:
  ```swift
  private func scheduleMaxDurationTimer() {
      // Move the existing maxDurationTimer = Task { ... } block here verbatim.
  }
  ```

- [ ] **Step 9.5: Replace startRecording() body**

  Find `private func startRecording()` in AppDelegate. Replace the entire body with:
  ```swift
  private func startRecording() {
      let handle = audioPipeline.beginRecording()
      guard let handle else { return }  // already recording (no-op)
      audioSession.ringBufferHandle = handle
      do {
          try audioSession.start(waveformCallback: { [weak self] chunk in
              self?.waveformVM.updateFromChunk(chunk)
          })
      } catch {
          logger.error("AudioSession.start failed: \(error)")
          audioPipeline.cancel(handle: handle)
          appState.transition(to: .error("Microphone error: \(error.localizedDescription)"))
          return
      }
      appState.transition(to: .recording)
      scheduleMaxDurationTimer()
  }
  ```

  **Comprehensive removal of `isDraining` / `drainGeneration` / `drainResult` (all 8+ sites):**

  These appear at the following approximate lines in `OpenVerbApp.swift` (run `grep -n "isDraining\|drainGeneration\|drainResult"` to get exact numbers):
  - Property declarations (~lines 85-93): `drainGeneration: UInt64`, `isDraining: Bool`
  - `startRecording` body (~lines 438-442): `isDraining = false`, `drainGeneration &+= 1`
  - `stopRecording` body (~line 484): `guard !isDraining`, `isDraining = true`
  - `stopRecording` body (~line 492): `engineManager.engineClient.stopPhase2Monitor()` — remove
  - `abortAndRestart` body (~lines 527-528): `drainGeneration &+= 1`, `let gen = drainGeneration`
  - `abortAndRestart` body (~line 545): `isDraining = false`
  - `abortAndRestart` body (~line 555): `engineManager.engineClient.stopPhase2Monitor()` — remove
  - `handleCancel` (~line 559): `drainGeneration &+= 1`
  - Other cancel paths (~line 625): `engineManager.engineClient.stopPhase2Monitor()` — remove
  - The **entire `drainResult()` function** (~lines 718-900): delete it entirely

  Also remove `syncOnIOQueue` call sites in `OpenVerbApp.swift` (they call `engineManager.engineClient.syncOnIOQueue()` — not relevant after AudioPipeline takes over the send path).

  Run `grep -n "syncOnIOQueue\|stopPhase2Monitor\|startPhase2Monitor\|isDraining\|drainGeneration\|drainResult"` before and after to confirm all are gone.

- [ ] **Step 9.6: Replace stopRecording() body**

  ```swift
  private func stopRecording() {
      guard let handle = audioPipeline.activeHandle else { return }
      audioSession.stop()
      audioPipeline.endRecording(handle: handle)
      appState.transition(to: .inferring)
      maxDurationTimer?.cancel()
      maxDurationTimer = nil
  }
  ```
  `audioPipeline.onResult` fires asynchronously via the `streamLive` Task; no explicit `drainResult` Task needed.

- [ ] **Step 9.7: Replace handleCancel() / abortAndRestart() cancel paths**

  Wherever `audioSession.stop()` is called and the session is cancelled, also call:
  ```swift
  if let handle = audioPipeline.activeHandle {
      audioPipeline.cancel(handle: handle)
  }
  ```
  Remove `isDraining = false` and `drainGeneration &+= 1` from abortAndRestart.

- [ ] **Step 9.8: Build**

  ```bash
  cd app && swift build 2>&1 | tail -30
  ```
  `audioPipeline.activeHandle` is `private(set)` — readable by AppDelegate. `ContextBuilder.build` signature confirmed in Step 9.3. Fix any remaining errors.

- [ ] **Step 9.9: Run test suite**

  ```bash
  cd app && swift test 2>&1 | tail -20
  ```
  Expected: all tests pass.

- [ ] **Step 9.10: Commit**

  ```bash
  git add app/OpenVerb/App/OpenVerbApp.swift
  git commit -m "wire AudioPipeline into AppDelegate (phase 6 integration)"
  ```

---

### Task 10: Bug-fix audit (pre-Phase 7)

Before removing the Phase 2 monitor, audit all "Bug N:" comments in the files modified by this refactor to ensure no regression.

**Files to scan:**
- `app/OpenVerb/Input/AudioSession.swift`
- `app/OpenVerb/Engine/EngineClient.swift`
- `app/OpenVerb/Engine/EngineManager.swift`
- `app/OpenVerb/App/OpenVerbApp.swift`

- [ ] **Step 10.1: List all Bug N comments in scope**

  ```bash
  grep -rn "Bug [0-9]" \
      app/OpenVerb/Input/AudioSession.swift \
      app/OpenVerb/Engine/EngineClient.swift \
      app/OpenVerb/Engine/EngineManager.swift \
      app/OpenVerb/App/OpenVerbApp.swift 2>&1 | sort
  ```

- [ ] **Step 10.2: For each bug comment, classify:**

  | Category | Action |
  |----------|--------|
  | Fix is in code that will be deleted | Verify new code handles the same invariant; add negative test |
  | Fix is in code that remains unchanged | Port the comment + verify its test still passes |
  | Fix is irrelevant (different feature area) | Leave comment in place |
  | Duplicate (same invariant now handled by new mechanism) | Delete comment; add note in commit |

  Document the classification inline as a comment in the file, or in the commit message.

- [ ] **Step 10.3: Add negative tests for any moved/deleted bug fixes**

  For each bug whose fix is in deleted code, add a `prove_bugN_stays_fixed` test in `app/OpenVerbTests/OpenBugsNegativeTests.swift` asserting the new mechanism covers the same invariant.

  Example — Bug 16 (drainGeneration cross-session stale drain):
  ```swift
  func prove_bug16_staleHandleIsNoOp() {
      // AudioPipeline.cancel(handle:) with a stale handle must not affect state.
      // Replaces the drainGeneration guard removed from AppDelegate.
      // Uses a random Handle (never registered) to avoid launching streamLive,
      // which would complicate the test with an async side-effect.
      let pipeline = AudioPipeline(ringBuffer: AudioRingBuffer())
      let staleHandle = AudioRingBuffer.Handle(id: UUID())   // never registered
      pipeline.cancel(handle: staleHandle)   // stale — must be no-op
      XCTAssertEqual(pipeline.state, .idle, "Unregistered handle cancel must not alter state (Bug 16 invariant)")
  }

  func prove_bug81_doubleStopIsNoOp() {
      // Was: isDraining guard in stopRecording. Now: endRecording on stale handle is no-op.
      let pipeline = AudioPipeline(ringBuffer: AudioRingBuffer())
      let h = pipeline.beginRecording()!
      pipeline.endRecording(handle: h)  // → finalizing
      pipeline.endRecording(handle: h)  // stale (state != streaming) — no-op
      XCTAssertEqual(pipeline.state, .finalizing, "Double endRecording must not corrupt state (Bug 81 invariant)")
  }
  ```

- [ ] **Step 10.4: Run full suite**

  ```bash
  cd app && swift test 2>&1 | tail -20
  ```
  Expected: all tests pass including new negative tests.

- [ ] **Step 10.5: Commit**

  ```bash
  git add app/OpenVerbTests/OpenBugsNegativeTests.swift
  git commit -m "add negative tests for bugs 16 and 81 under AudioPipeline"
  ```

---

## Chunk 6: Phase 2 Monitor Removal + Flag Cleanup (Phase 7)

### Task 11: Delete Phase 2 monitor from EngineClient.swift

This task should only be done after Phase 6 has been live in production for ≥1 week (per the spec rollback policy). Skip to Task 12 (feature flag removal) if the 1-week validation window has not passed yet.

**Files:**
- Modify: `app/OpenVerb/Engine/EngineClient.swift`

- [ ] **Step 11.1: Identify Phase 2 monitor code to delete**

  ```bash
  grep -n "phase2\|wakeRead\|wakeWrite\|callOnErrorIfLive\|Phase 2 monitor\|stopPhase2\|startPhase2\|runPhase2" \
      app/OpenVerb/Engine/EngineClient.swift | head -40
  ```

- [ ] **Step 11.2: Delete the Phase 2 monitor code from EngineClient.swift**

  Remove all of:
  - `private var phase2Error: ServerMessage?`
  - `private let phase2Lock = NSLock()`
  - `private var phase2MonitorTask: Task<Void, Never>?`
  - `private var phase2MonitorStopped = false`
  - `private var wakeRead: Int32 = -1`
  - `private var wakeWrite: Int32 = -1`
  - `func startPhase2Monitor()`
  - `func stopPhase2Monitor()`
  - `private func runPhase2Monitor()`
  - `private func callOnErrorIfLive(_:)`
  - Any references to them

  Also remove from `connect(path:)` or `disconnect()` any cleanup of the wake pipe.

- [ ] **Step 11.2b: Remove Phase 2 monitor call sites in OpenVerbApp.swift and EngineManager.swift**

  Five call sites remain outside EngineClient after Step 11.2 (confirmed via grep in Step 9.5):
  - `OpenVerbApp.swift ~line 492`: `engineManager.engineClient.stopPhase2Monitor()`
  - `OpenVerbApp.swift ~line 555`: `engineManager.engineClient.stopPhase2Monitor()`
  - `OpenVerbApp.swift ~line 625`: `engineManager.engineClient.stopPhase2Monitor()`
  - `OpenVerbApp.swift ~line 744`: `engineManager.engineClient.startPhase2Monitor()` (inside connectAndRecord being deleted)
  - `EngineManager.swift ~line 570`: `engineClient.stopPhase2Monitor()`

  These are all removed as part of the larger connectAndRecord/drainResult deletion (Step 9.5) and the EngineManager cleanup. Confirm with:
  ```bash
  grep -rn "Phase2Monitor" app/OpenVerb/ 2>/dev/null
  ```
  Expected: no results.

- [ ] **Step 11.2c: Update negative tests that scan for deleted code (issues #31-33)**

  Negative tests that source-scan for code removed in Phases 6-7 will fail with a false
  positive "pattern found" (or "pattern absent" if they looked for removed code). Find them:
  ```bash
  grep -n "drainGeneration\|isDraining\|phase2\|flushPreBuffer\|commitSendCallback" \
      app/OpenVerbTests/OpenBugsNegativeTests.swift
  ```
  For each match:
  - If the test scans for code **that was removed**: delete the test (the negative no longer applies — the old mechanism is gone)
  - If the test verifies an invariant **now covered by AudioPipeline**: replace the source-scan with a state machine assertion (e.g., stale handle is no-op)

  Typical tests to remove or update after Phases 6-7:
  - Bug 16 (drainGeneration): replaced by `prove_bug16_staleHandleIsNoOp` (added in Task 10)
  - Bug 81 (isDraining): replaced by `prove_bug81_doubleStopIsNoOp` (added in Task 10)
  - Bugs 17, 27, 28 (phase2 monitor): no longer applicable — remove the source-scan tests

- [ ] **Step 11.3: Build**

  ```bash
  cd app && swift build 2>&1 | tail -20
  ```
  Fix any remaining references to the deleted methods.

- [ ] **Step 11.4: Run test suite**

  ```bash
  cd app && swift test 2>&1 | tail -20
  ```
  Expected: all suites green.

- [ ] **Step 11.5: Commit**

  ```bash
  git add app/OpenVerb/Engine/EngineClient.swift
  git commit -m "remove phase 2 monitor from EngineClient (replaced by AudioPipeline)"
  ```

---

### Task 12: Remove USE_RING_BUFFER_PIPELINE feature flag

**Files:**
- Modify: `app/OpenVerb/Engine/Constants.swift`
- Modify: `app/OpenVerb/Input/AudioSession.swift`
- Modify: `app/OpenVerbTests/AudioSessionTests.swift`

- [ ] **Step 12.1: Remove flag from Constants.swift**

  Delete the `USE_RING_BUFFER_PIPELINE` line from `enum Constants`.

- [ ] **Step 12.2: Remove flag guards from AudioSession.swift**

  Replace all `if Constants.USE_RING_BUFFER_PIPELINE { ... } else { ... }` blocks with the `true` branch content. Delete the `false` branch (old preBuffer logic) entirely.

- [ ] **Step 12.3: Update or delete flag-dependent test**

  Remove `testAudioSessionWritesToRingBufferWhenFlagEnabled` (which checked for the flag's existence). Replace with a simpler assertion:
  ```swift
  func testAudioSessionDoesNotUsePreBuffer() throws {
      let src = try String(
          contentsOfFile: Bundle(for: AudioSession.self).bundlePath
              + "/../../../OpenVerb/Input/AudioSession.swift",
          encoding: .utf8)
      XCTAssertFalse(src.contains("preBuffer.append"),
                     "preBuffer.append must not exist after Phase 7 cleanup")
      XCTAssertTrue(src.contains("ringBuffer.write("),
                    "ringBuffer.write must be the only audio send path")
  }
  ```

- [ ] **Step 12.4: Build + test**

  ```bash
  cd app && swift build 2>&1 | tail -10
  cd app && swift test 2>&1 | tail -20
  ```
  Expected: clean build, all tests green.

- [ ] **Step 12.5: Commit**

  ```bash
  git add app/OpenVerb/Engine/Constants.swift app/OpenVerb/Input/AudioSession.swift \
          app/OpenVerbTests/AudioSessionTests.swift
  git commit -m "remove USE_RING_BUFFER_PIPELINE feature flag (phase 7 cleanup)"
  ```

---

## Chunk 7: SubtitlePanel + Live Subtitle Diagnosis (Phases 8–9)

### Task 13: SubtitlePanel implementation

**Files:**
- Create: `app/OpenVerb/UI/SubtitlePanel.swift`
- Modify: `app/OpenVerb/Settings/AppSettings.swift`

- [ ] **Step 13.1: Add showSubtitlePanel to AppSettings**

  First, add a key constant to the existing `Key` enum inside `AppSettings.swift` (same pattern as other keys):
  ```swift
  static let showSubtitlePanel = "showSubtitlePanel"
  ```

  Then add the `@Published` property (in the published settings section):
  ```swift
  @Published var showSubtitlePanel: Bool = true {
      didSet {
          guard !isResetting else { return }
          defaults.set(showSubtitlePanel, forKey: Key.showSubtitlePanel)
      }
  }
  ```

  In `init(defaults:)`, restore using the safe bool accessor (not a force-cast):
  ```swift
  // defaults.bool(forKey:) returns false for missing keys, so use object(forKey:) to distinguish
  // missing (use default true) from explicitly set false.
  showSubtitlePanel = defaults.object(forKey: Key.showSubtitlePanel) != nil
      ? defaults.bool(forKey: Key.showSubtitlePanel)
      : true
  ```

- [ ] **Step 13.2: Write SubtitlePanel**

  Create `app/OpenVerb/UI/SubtitlePanel.swift`:
  ```swift
  import AppKit
  import SwiftUI
  import Combine
  import os

  private let logger = Logger(subsystem: "io.openverb.app", category: "SubtitlePanel")

  // SubtitlePanel — floating NSPanel that shows live partial transcription text.
  // Positioned directly below RecordingWindow.
  // Visible during .recording and .inferring.
  // Text: livePartialText from AppState, 16 pt, no truncation, auto-scroll.
  final class SubtitlePanel {

      private var panel: NSPanel?
      private var hostingView: NSHostingView<SubtitleView>?
      private var cancellables = Set<AnyCancellable>()

      deinit { cancellables.removeAll() }

      // Create the panel and position it below `anchor`.
      // Call from RecordingWindow.init after the window is placed.
      func setup(anchorWindow: NSWindow, appState: AppState, settings: AppSettings) {
          guard settings.showSubtitlePanel else { return }
          let view = SubtitleView(appState: appState)
          let hosting = NSHostingView(rootView: view)
          hosting.setFrameSize(NSSize(width: 480, height: 80))
          // wantsLayer + clear backgroundColor required for transparency to show through.
          // Without these the NSHostingView renders with an opaque white backing layer.
          hosting.wantsLayer = true
          hosting.layer?.backgroundColor = .clear
          let p = NSPanel(
              contentRect: NSRect(x: 0, y: 0, width: 480, height: 80),
              styleMask: [.nonactivatingPanel, .borderless],
              backing: .buffered,
              defer: false
          )
          p.contentView = hosting
          p.isOpaque = false
          p.backgroundColor = .clear
          p.level = .floating
          p.ignoresMouseEvents = true
          p.collectionBehavior = [.canJoinAllSpaces, .stationary]
          reposition(panel: p, below: anchorWindow)
          // ordered: .above gives the SubtitlePanel a higher z-order than the parent,
          // so it stays visible. `.below` would place it behind the parent window.
          anchorWindow.addChildWindow(p, ordered: .above)
          panel = p
          hostingView = hosting

          // Reposition when anchor moves
          NotificationCenter.default.publisher(for: NSWindow.didMoveNotification,
                                               object: anchorWindow)
              .receive(on: DispatchQueue.main)
              .sink { [weak self, weak p, weak anchorWindow] _ in
                  guard let self, let p, let anchor = anchorWindow else { return }
                  self.reposition(panel: p, below: anchor)
              }
              .store(in: &cancellables)
      }

      private func reposition(panel: NSPanel, below anchor: NSWindow) {
          let anchorFrame = anchor.frame
          let panelFrame = NSRect(
              x: anchorFrame.minX,
              y: anchorFrame.minY - panel.frame.height - 8,
              width: anchorFrame.width,
              height: panel.frame.height
          )
          panel.setFrame(panelFrame, display: true)
      }

      func show() { panel?.orderFront(nil) }
      func hide() { panel?.orderOut(nil) }
  }

  // MARK: - SubtitleView

  private struct SubtitleView: View {
      @ObservedObject var appState: AppState

      var body: some View {
          ScrollViewReader { proxy in
              ScrollView(.vertical, showsIndicators: false) {
                  Text(appState.livePartialText.isEmpty ? " " : appState.livePartialText)
                      .font(.system(size: 16, weight: .regular, design: .default))
                      .foregroundColor(.white)
                      .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                      .multilineTextAlignment(.leading)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .padding(.horizontal, 12)
                      .padding(.vertical, 8)
                      .id("bottom")
                      // animation modifier instead of withAnimation inside onChange —
                      // avoids stacking animations on rapid partial result updates.
                      .animation(.easeOut(duration: 0.15), value: appState.livePartialText)
              }
              .onChange(of: appState.livePartialText) { _ in
                  proxy.scrollTo("bottom", anchor: .bottom)
              }
          }
          .background(Color.black.opacity(0.55))
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
  }
  ```

- [ ] **Step 13.3: Build**

  ```bash
  cd app && swift build 2>&1 | tail -15
  ```
  Expected: clean build.

- [ ] **Step 13.4: Commit**

  ```bash
  git add app/OpenVerb/UI/SubtitlePanel.swift app/OpenVerb/Settings/AppSettings.swift
  git commit -m "add SubtitlePanel for live partial transcription display"
  ```

---

### Task 14: Wire SubtitlePanel into RecordingWindow

**Files:**
- Modify: `app/OpenVerb/UI/RecordingWindow.swift`

- [ ] **Step 14.1: Add SubtitlePanel property to RecordingWindow**

  In `RecordingWindow.swift`, add:
  ```swift
  private let subtitlePanel = SubtitlePanel()
  ```

  In the initializer, after `self.init(...)` completes (or in `windowDidLoad` / setup method), call:
  ```swift
  subtitlePanel.setup(anchorWindow: self, appState: appState, settings: settings)
  ```

- [ ] **Step 14.2: Show/hide SubtitlePanel with the recording window**

  In RecordingWindow's `show()` method (or wherever the panel is ordered front), add:
  ```swift
  if settings.showSubtitlePanel {
      subtitlePanel.show()
  }
  ```
  In `hide()`:
  ```swift
  subtitlePanel.hide()
  ```

- [ ] **Step 14.3: Build + test**

  ```bash
  cd app && swift build 2>&1 | tail -10
  cd app && swift test 2>&1 | tail -15
  ```

- [ ] **Step 14.4: Commit**

  ```bash
  git add app/OpenVerb/UI/RecordingWindow.swift
  git commit -m "wire SubtitlePanel into RecordingWindow"
  ```

---

### Task 15: Diagnose live subtitle path (Phase 9)

The user reports live subtitle never worked. This task instruments the path from engine → partial_result → livePartialText.

**Files:**
- Modify: `app/OpenVerb/Engine/EngineClient.swift` (add instrumentation)
- Modify: `app/OpenVerb/App/OpenVerbApp.swift` (add instrumentation)
- Modify: `app/OpenVerb/State/AppState.swift` (add instrumentation)

- [ ] **Step 15.1: Verify EngineClient.onPartialResult fires during a session**

  In EngineClient, search for where `onPartialResult` is called. Add a logger.debug line immediately before the closure call:
  ```swift
  // In EngineClient.receiveMessage or wherever partial_result is handled:
  logger.debug("⚡ onPartialResult firing: \(text)")
  self.onPartialResult?(text, chunkId, isFinal)
  ```

- [ ] **Step 15.2: Locate existing onPartialResult wiring**

  Before adding new wiring, check if it already exists:
  ```bash
  grep -n "onPartialResult" app/OpenVerb/App/OpenVerbApp.swift
  grep -n "livePartialText" app/OpenVerb/App/OpenVerbApp.swift app/OpenVerb/State/AppState.swift
  ```

  If `onPartialResult` is already assigned in AppDelegate but `livePartialText` never updates during a real recording, the issue is on the engine side (engine not sending `partial_result` messages). If `onPartialResult` is NOT assigned anywhere, wire it:
  ```swift
  engineManager.engineClient.onPartialResult = { [weak self] text, _, _ in
      guard let self else { return }
      logger.debug("⚡ onPartialResult → livePartialText: \(text)")
      Task { @MainActor in self.appState.livePartialText = text }
  }
  ```
  This must be set in `applicationDidFinishLaunching` BEFORE any session starts.

- [ ] **Step 15.3: Verify AppState.livePartialText is @Published and SubtitleView observes it**

  In `AppState.swift`, confirm:
  ```swift
  @Published var livePartialText: String = ""
  ```

  In `SubtitleView`, confirm it uses `@ObservedObject var appState: AppState` and references `appState.livePartialText`.

- [ ] **Step 15.4: Write integration test for partial result flow**

  Add to a suitable integration test file (or `app/OpenVerbTests/PartialAccumulationTests.swift`):
  ```swift
  func testLivePartialTextUpdatesFromPartialResult() async {
      // Verify that when onPartialResult fires, livePartialText is updated on @MainActor.
      let appState = await MainActor.run { AppState() }
      let client = EngineClient()
      // Wire manually
      await MainActor.run {
          client.onPartialResult = { text, _, _ in
              Task { @MainActor in appState.livePartialText = text }
          }
      }
      // Simulate a partial result
      await MainActor.run {
          client.onPartialResult?("hello world", 1, false)
      }
      // Allow main actor to process
      try? await Task.sleep(for: .milliseconds(50))
      let text = await MainActor.run { appState.livePartialText }
      XCTAssertEqual(text, "hello world",
                     "livePartialText must update synchronously from onPartialResult")
  }
  ```

- [ ] **Step 15.5: Run test + diagnose**

  ```bash
  cd app && swift test --filter PartialAccumulationTests/testLivePartialTextUpdatesFromPartialResult 2>&1 | tail -15
  ```
  If this test passes, the issue is in the engine not sending partial results — check the engine side. If it fails, the wiring in AppDelegate is broken — fix the closure assignment.

- [ ] **Step 15.6: Fix identified root cause**

  Based on the instrumentation output, fix the specific wiring issue. Common causes:
  1. `onPartialResult` closure never assigned in AppDelegate
  2. Closure assigned but captured `self` strongly (causing it to be nil'd)
  3. Assignment happens after session start (closure not in place when partials fire)
  4. `AppState.livePartialText` update happens off `@MainActor` (use `DispatchQueue.main.async`)

- [ ] **Step 15.7: Commit**

  ```bash
  git add -p  # stage only the relevant changes
  git commit -m "fix live subtitle path wiring (phase 9)"
  ```

---

## Human Verification

- [ ] **HUMAN: Add new Swift files to Xcode target**

  For every new Swift file added in this plan that Xcode doesn't auto-discover, open the project in Xcode and use **File → Add Files to OpenVerb**. Files that need adding:
  - `app/OpenVerb/Input/AudioRingBuffer.swift`
  - `app/OpenVerb/Pipeline/AudioPipeline.swift` (also the new `Pipeline/` directory)
  - `app/OpenVerb/UI/SubtitlePanel.swift`

  Confirm each file's target membership checkbox is set to the "OpenVerb" app target (not just tests).

  Then run `ov` — expect **BUILD SUCCEEDED**.

- [ ] **HUMAN: Phase 1 smoke test — first recording latency**

  Launch the app fresh. Immediately press ⌥Space and speak a 5-second sentence. Stop. Verify the transcript contains the beginning of the utterance (not just the last 2 seconds). Check logs: `engine.ensure_loaded()` log should appear before `ipc: listening on`.

- [ ] **HUMAN: Back-to-back recording test**

  Perform 5 consecutive recordings without pausing. All 5 must produce non-empty transcripts. This proves symptom #2 (every-second-fails) is resolved.

- [ ] **HUMAN: SubtitlePanel visual check**

  Start a recording, speak for 3+ seconds. Verify the SubtitlePanel appears below the recording HUD and accumulates text as you speak.

- [ ] **HUMAN: Verify AudioRingBuffer.Metrics.overflowCount == 0 in logs**

  After recordings of <5 min, search the app logs for `AudioRingBuffer: overflow`. Under normal usage (recordings under 5 min) this log must not appear.

- [ ] **HUMAN: Update bugs.md**

  Verify no open bugs remain unaddressed. If any "Bug N:" comment was removed from code without a regression test, reopen that bug in `bugs.md` with a note explaining the new mechanism that covers it.
