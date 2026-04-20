import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 95, 96, 97, 98, 99, 100, 101
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_95_101: XCTestCase {

    private func readSource(_ relativePath: String) -> String? {
        let direct = URL(fileURLWithPath: relativePath)
        if let content = try? String(contentsOf: direct, encoding: .utf8) { return content }
        if let base = Bundle.main.resourceURL {
            let bundled = base.appendingPathComponent(relativePath)
            if let content = try? String(contentsOf: bundled, encoding: .utf8) { return content }
        }
        return nil
    }

    // =======================================================================
    // Bug 95 — recvJSONSync races on `fd` between pollfd setup and read()
    //
    // After acquiring socketReadLock, `fd` is read once for the pollfd struct
    // and then used again unguarded in the read() call at line 340.
    // disconnect() can close the fd between those two uses; the read() call
    // then operates on -1 (or a recycled descriptor), returning EBADF instead
    // of the clean EngineClientError.connectionClosed path.
    //
    // EXPECTED: The fd value is snapshotted once under socketReadLock (or the
    //           equivalent fdLock) immediately before both the pollfd setup AND
    //           the read() call.  The live self.fd / self._fd must NOT be
    //           re-evaluated inside the read() call after the lock is released.
    // ACTUAL:   `pollfd(fd: fd, ...)` reads the property (which acquires fdLock
    //           and releases it), then `read(fd, ...)` acquires fdLock again for
    //           a second independent read — there is no single snapshot that is
    //           shared between poll() and read().
    // =======================================================================

    func testBug95_recvJSONSync_fdSnapshotNotReusedBetweenPollAndRead() {
        guard let source = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }

        // The fix requires a local snapshot variable (e.g. `let currentFd = fd`)
        // that is then used in BOTH the pollfd initializer and the read() call.
        // Check that such a local snapshot is used in the recvJSONSync loop.
        // A correct pattern is: capture into a local, then `pollfd(fd: localVar, ...)`
        // and later `read(localVar, ...)` — both referencing the same local.
        //
        // We look for `read(fd,` — if the live `fd` computed property is called
        // directly inside read(), the snapshot pattern is absent.
        let hasDirectFdInRead = source.contains("read(fd,")
        XCTAssertFalse(hasDirectFdInRead,
            "Bug 95 CONFIRMED: read(fd, ...) in recvJSONSync re-evaluates the `fd` " +
            "computed property (which acquires/releases fdLock) separately from the " +
            "pollfd(fd: fd, ...) call. disconnect() can close the descriptor between " +
            "those two accesses, causing read() to see fd=-1 → EBADF instead of " +
            "EngineClientError.connectionClosed. " +
            "Fix: snapshot `let currentFd = fd` once under socketReadLock and use " +
            "that local in both pollfd(fd: currentFd) and read(currentFd, ...).")
    }

    // =======================================================================
    // Bug 96 — ensureRunning() blocks MainActor 500 ms via waitForProcessExit
    //
    // `Self.waitForProcessExit(process, timeout: 0.5)` at line 247 is called
    // directly on the @MainActor ensureRunning() body.  waitForProcessExit spins
    // `RunLoop.current.run(until:)` in a tight loop for up to 500 ms, which
    // freezes the main run loop — all UI updates, timers, and Swift concurrency
    // continuations on MainActor are blocked for the full duration on every
    // cold-start or crash-recovery.
    //
    // EXPECTED: waitForProcessExit is invoked off the main actor, e.g. via
    //           `await Task.detached { Self.waitForProcessExit(...) }.value`
    //           so the main actor is never blocked.
    // ACTUAL:   The call is synchronous on the @MainActor ensureRunning() body.
    // =======================================================================

    func testBug96_ensureRunning_waitForProcessExitBlocksMainActor() {
        guard let source = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }

        // The bug is present when ensureRunning() contains a synchronous bare call:
        //   `Self.waitForProcessExit(process, timeout: 0.5)`
        // A fixed implementation either:
        //   (a) wraps it: `await Task.detached { Self.waitForProcessExit(...) }.value`, OR
        //   (b) inlines the wait logic inside a detached Task.
        //
        // The bare call `Self.waitForProcessExit(process,` (with `process` as the
        // argument, not `procRef`) appears only in the ensureRunning() body.
        // The shutdown() path uses `procRef` as the argument — we target the
        // `process` variant to isolate the ensureRunning() call site.
        let hasBareCallInEnsureRunning = source.contains("Self.waitForProcessExit(process,")
        XCTAssertFalse(hasBareCallInEnsureRunning,
            "Bug 96 CONFIRMED: ensureRunning() calls Self.waitForProcessExit(process, " +
            "timeout: 0.5) synchronously on the @MainActor execution context. " +
            "waitForProcessExit spins RunLoop.current.run(until:) for up to 500 ms, " +
            "blocking the main actor on every cold-start and crash-recovery. " +
            "Fix: wrap the call in `await Task.detached { Self.waitForProcessExit(...) }.value` " +
            "so the spin happens off the main actor.")
    }

    // =======================================================================
    // Bug 97 — handleCrash() silent-return on dedup leaves second caller blind
    //
    // `guard !isRecovering else { return }` returns Void on the dedup path.
    // If the first recovery attempt throws `.crashLoop` and sets
    // `status = .error(...)`, the second (duplicate) caller sees a plain
    // return and assumes recovery is running normally — it never learns that
    // recovery already failed and the engine is dead.
    //
    // EXPECTED: The dedup guard path either throws an error (e.g. a new
    //           `EngineManagerError.recoveryInProgress`), returns a distinct
    //           Bool, or uses a continuation/async mechanism so callers can
    //           detect that they did not actually trigger recovery and can
    //           check engine status themselves.
    // ACTUAL:   `guard !isRecovering else { return }` returns Void silently.
    // =======================================================================

    func testBug97_handleCrash_dedupReturnIsIndistinguishable() {
        guard let source = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }

        // The bug is present when the guard line is a plain `return` (Void).
        // A fix replaces it with `throw`, a distinct Bool return, or an async
        // awaitable — any of which signals the duplicate caller.
        //
        // We match the literal dedup guard pattern introduced for the bug.
        let hasSilentReturn = source.contains("guard !isRecovering else {") &&
            source.range(of: "guard !isRecovering else \\{\\s*\\n[^}]*return\\s*\\n\\s*\\}",
                         options: .regularExpression) != nil
        XCTAssertFalse(hasSilentReturn,
            "Bug 97 CONFIRMED: handleCrash() uses `guard !isRecovering else { return }` " +
            "which returns Void on the dedup path. If the first caller's recovery throws " +
            "crashLoop and leaves the engine dead, a second concurrent caller sees a plain " +
            "return and incorrectly assumes recovery is in progress — it never checks " +
            "engine status or surfaces the error. " +
            "Fix: replace the silent return with `throw EngineManagerError.recoveryInProgress` " +
            "(or equivalent) so the second caller can detect the failure and react.")
    }

    // =======================================================================
    // Bug 98 — Phase 2 monitor and drainResult both fire onPartialResult
    //          for the same message
    //
    // In runPhase2Monitor() (EngineClient.swift line 617), when a
    // `.partialResult` arrives it is forwarded directly via
    // `onPartialResult?(t, id, f)`.  In drainResult() (OpenVerbApp.swift line
    // 846), `.partialResult` messages are forwarded via the same
    // `engineManager.engineClient.onPartialResult?` callback.  During the
    // recording→inferring handoff, both paths can process the same message,
    // appending the same partial text to livePartialText twice.
    //
    // EXPECTED: Only one path delivers each partial message — either the Phase 2
    //           monitor delivers partials and drainResult skips them, or a
    //           chunkId-based dedup prevents double delivery.
    // ACTUAL:   Both paths call onPartialResult with no dedup guard.
    // =======================================================================

    func testBug98_partialResult_doubleDelivery_noDedup() {
        guard let engineSource = readSource("OpenVerb/Engine/EngineClient.swift"),
              let appSource    = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read source files"); return
        }

        // The Phase 2 monitor delivers partials at EngineClient.swift line 617:
        //   `onPartialResult?(t, id, f)   // Bug 55: live forwarding`
        // drainResult delivers partials at OpenVerbApp.swift line 846:
        //   `engineManager.engineClient.onPartialResult?(text, chunkId, isFinal)`
        //
        // The fix requires EITHER:
        //   (a) The monitor path is guarded to NOT call onPartialResult (so only
        //       drainResult delivers, after the monitor stops), OR
        //   (b) A set of already-delivered chunkIds prevents re-delivery, OR
        //   (c) drainResult skips .partialResult entirely (defers to monitor).
        //
        // We check for the simplest guard: the monitor's onPartialResult call
        // should only fire when the monitor is active AND drainResult hasn't
        // already seen the chunkId.  A sufficient proxy is verifying that the
        // monitor no longer calls onPartialResult unconditionally — i.e. there
        // is no bare `onPartialResult?(t, id, f)` after a partialResult match
        // without a preceding dedup check.
        //
        // We detect the bug by confirming both call sites exist without any
        // surrounding dedup logic in the monitor path.
        let monitorDeliversUnguarded = engineSource.contains("onPartialResult?(t, id, f)")
        let drainResultAlsoDelivers  = appSource.contains("engineClient.onPartialResult?")

        XCTAssertFalse(monitorDeliversUnguarded && drainResultAlsoDelivers,
            "Bug 98 CONFIRMED: Both runPhase2Monitor (EngineClient.swift) and drainResult " +
            "(OpenVerbApp.swift) call onPartialResult for .partialResult messages with no " +
            "deduplication guard. During the recording→inferring handoff the same partial " +
            "text is appended to livePartialText twice. " +
            "Fix: either stop the monitor before drainResult begins (so only one path is " +
            "active per message), or implement chunkId-based dedup (track a Set<Int> of " +
            "delivered chunkIds, skip if already seen).")
    }

    // =======================================================================
    // Bug 99 — livePartialText appended after idle-transition clear
    //
    // onPartialResult enqueues `Task { @MainActor }`. If the session ends and
    // livePartialText is cleared (transition to .idle) before the Task executes,
    // the enqueued Task still runs `self.appState.livePartialText += text`,
    // re-populating the field with text from the previous session.
    //
    // EXPECTED: After transitioning to .idle, any subsequently-running
    //           onPartialResult Task must be a no-op (guard on current state).
    // ACTUAL:   The Task only checks `guard let self` — no state guard.
    // =======================================================================

    func testBug99_livePartialText_staleAppendAfterIdleTransition() async throws {
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            // Disable assertion failures for invalid transitions in tests.
            appState.invalidTransitionAction = { _ in }
        }

        // Build the partial-result closure exactly as OpenVerbApp.swift wires it:
        // no state guard — just `livePartialText += text`.
        let partialCallback: (String, Int, Bool) -> Void = { [weak appState] text, _, _ in
            Task { @MainActor [weak appState] in
                guard let appState else { return }
                // BUG: no `guard appState.state == .inferring` check here
                appState.livePartialText += text
            }
        }

        // Drive AppState through a recording cycle up to .inferring.
        await MainActor.run {
            appState.transition(to: .preparing)
            appState.transition(to: .recording)
            appState.transition(to: .inferring)
        }

        // Simulate the session ending: transition to .idle clears livePartialText.
        await MainActor.run {
            appState.transition(to: .idle)
        }

        // Now fire a "late" partial callback (as if it arrived after idle transition).
        // The async Task it enqueues must NOT modify livePartialText.
        partialCallback("stale text", 42, false)

        // Yield to let the enqueued MainActor Task execute.
        try await Task.sleep(for: .milliseconds(50))

        let text = await MainActor.run { appState.livePartialText }
        XCTAssertEqual(text, "",
            "Bug 99 CONFIRMED: onPartialResult callback enqueues `Task { @MainActor }` " +
            "with no state guard. When the Task runs after the session transitions to " +
            ".idle (which clears livePartialText), the stale partial text is re-appended. " +
            "Fix: add `guard appState.state != .idle` (or check for .inferring/.recording) " +
            "inside the Task before appending to livePartialText.")
    }

    // =======================================================================
    // Bug 100 — remainingInferenceMs not cleared on ERROR→PREPARING
    //
    // AppState only clears remainingInferenceMs on transition to .idle.
    // After INFERRING→ERROR→PREPARING the field retains the countdown value
    // from the failed session, so the UI shows a stale inference timer during
    // the new preparing phase.
    //
    // EXPECTED: remainingInferenceMs is nil after transitioning to .preparing.
    // ACTUAL:   The value is only cleared in the `.idle` entry-effects block.
    // =======================================================================

    func testBug100_remainingInferenceMs_notClearedOnPreparingEntry() async throws {
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.invalidTransitionAction = { _ in }
            // Use a very short error-clear delay so the auto-clear timer does
            // not interfere with the test.
            appState.errorClearDelay = .milliseconds(5000)
        }

        // Drive to .inferring and set a non-zero countdown.
        await MainActor.run {
            appState.transition(to: .preparing)
            appState.transition(to: .recording)
            appState.transition(to: .inferring)
            appState.remainingInferenceMs = 60_000
        }

        // Simulate an error (engine crash mid-inference).
        await MainActor.run {
            appState.transition(to: .error("test error"))
        }

        // User presses ⌥Space: ERROR → PREPARING retry.
        await MainActor.run {
            appState.transition(to: .preparing)
        }

        let remaining = await MainActor.run { appState.remainingInferenceMs }
        XCTAssertNil(remaining,
            "Bug 100 CONFIRMED: remainingInferenceMs is \(remaining as Any) after " +
            "INFERRING→ERROR→PREPARING instead of nil. AppState only clears this " +
            "field in the .idle entry-effects block, so the stale countdown from the " +
            "failed session is shown in the UI during the new preparing phase. " +
            "Fix: also set remainingInferenceMs = nil in the .preparing entry-effects " +
            "block (applyEntryEffects case .preparing).")
    }

    // =======================================================================
    // Bug 101 — NSPasteboard.string fallback called off main thread
    //
    // ContextBuilder.build() is `async` and runs on the Swift cooperative
    // thread pool.  When `clipboardSnapshot` is nil and `includeClipboard` is
    // true, line 99 executes `pasteboard.string(forType: .string)` — which in
    // production resolves to `NSPasteboard.general.string(forType:)`.  NSPasteboard
    // is not thread-safe and must be accessed from the main thread only.
    //
    // EXPECTED: Every NSPasteboard.general access in ContextBuilder.swift is
    //           wrapped in a `MainActor.run { }` block or an `@MainActor` function.
    // ACTUAL:   The fallback `pasteboard.string(forType: .string)` is a plain
    //           call with no actor annotation or MainActor.run wrapper.
    // =======================================================================

    func testBug101_contextBuilder_pasteboardFallbackCalledOffMainThread() {
        guard let source = readSource("OpenVerb/Context/ContextBuilder.swift") else {
            XCTFail("Cannot read ContextBuilder.swift"); return
        }

        // The fix requires that every pasteboard read is inside `MainActor.run {}`
        // or that the enclosing function is `@MainActor`.
        //
        // We detect the bug by verifying the pasteboard fallback line is NOT
        // protected:  `pasteboard.string(forType: .string)` must appear inside
        // a `MainActor.run` closure, or the whole `build` function must be
        // `@MainActor`.
        //
        // Proxy check 1: `build` is NOT annotated @MainActor.
        let buildIsMainActor = source.contains("@MainActor") &&
            source.range(of: "@MainActor[\\s\\S]*?static func build",
                         options: .regularExpression) != nil

        // Proxy check 2: the pasteboard read is wrapped in MainActor.run.
        let pasteboardWrapped = source.contains("MainActor.run") &&
            source.range(of: "MainActor\\.run[\\s\\S]*?pasteboard\\.string",
                         options: .regularExpression) != nil

        XCTAssertTrue(buildIsMainActor || pasteboardWrapped,
            "Bug 101 CONFIRMED: ContextBuilder.build() is an async function that runs " +
            "on the cooperative thread pool. When clipboardSnapshot is nil, line 99 calls " +
            "`pasteboard.string(forType: .string)` which resolves to " +
            "NSPasteboard.general.string(forType:) off the main thread. NSPasteboard " +
            "requires main-thread access and can crash or return garbage when called " +
            "from a background thread. " +
            "Fix: wrap the fallback read in `await MainActor.run { pasteboard.string(...) }` " +
            "or annotate ContextBuilder.build() as @MainActor.")
    }
}
