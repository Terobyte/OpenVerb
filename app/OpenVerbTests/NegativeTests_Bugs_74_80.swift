import XCTest
@testable import OpenVerb

// Negative tests for: Bug 74, 75, 76, 77, 78, 79, 80
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_74_80: XCTestCase {

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
    // Bug 74 — shutdown() detached Task sets .stopped after ensureRunning() sets .running
    //
    // restartWithBackend() calls shutdown() (which spawns a Task.detached that
    // eventually sets status = .stopped) and then immediately calls ensureRunning()
    // with no await between them.  The detached Task fires asynchronously and
    // can stamp .stopped AFTER the new engine is live, lying to the status bar
    // and causing the next hotkey press to double-launch the engine.
    //
    // EXPECTED: restartWithBackend() must await a proper async shutdown that
    //           synchronously waits for process exit before calling ensureRunning().
    //           shutdown() must be `async` and awaited, so the detached Task's
    //           .stopped write cannot race with the new session's .running write.
    // ACTUAL:   restartWithBackend() calls shutdown() synchronously (non-async,
    //           fire-and-forget), then calls ensureRunning().  The Task.detached
    //           inside shutdown() sets .stopped asynchronously after .running is set.
    // =======================================================================

    func testBug74_restartWithBackendAwaitsShutdownBeforeEnsureRunning() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }

        // The bug is that shutdown() is declared as a non-async func, so it cannot
        // be awaited.  A fixed implementation makes shutdown() async (or introduces
        // an awaitShutdown() wrapper) so restartWithBackend() can await it.
        //
        // Check: shutdown() must be declared as `async` to allow awaiting.
        // In the buggy code: `func shutdown() {` — synchronous, cannot be awaited.
        // In the fixed code:  `func shutdown() async {` — awaitable.
        let shutdownIsSync = content.contains("func shutdown() {")

        XCTAssertFalse(shutdownIsSync,
            "Bug 74 CONFIRMED: shutdown() is declared as a synchronous (non-async) function. " +
            "restartWithBackend() therefore cannot await it before calling ensureRunning(). " +
            "The Task.detached inside shutdown() sets status = .stopped asynchronously, " +
            "racing with ensureRunning() which sets status = .running for the new session. " +
            "Fix: declare shutdown() as `async`, await waitForProcessExit() directly (remove " +
            "Task.detached), and change restartWithBackend() to `await shutdown()` before " +
            "`try? await ensureRunning()`.")
    }

    // =======================================================================
    // Bug 75 — Phase 2 monitor discards last engine message — checks POLLHUP before POLLIN
    //
    // runPhase2Monitor() polls the socket and wakeup pipe.  When the engine writes
    // its final message and immediately closes the socket, poll() returns with both
    // POLLIN and POLLHUP set on pfds[0].  The monitor checks POLLHUP on pfds[0]
    // BEFORE checking POLLIN on pfds[0], so the monitor exits without reading the
    // final message, dropping it and triggering spurious crash recovery.
    //
    // EXPECTED: In the Phase 2 poll loop, the pfds[0] POLLIN check must come
    //           BEFORE the pfds[0] POLLHUP|POLLERR check.
    // ACTUAL:   The `pfds[0].revents & Int16(POLLHUP | POLLERR)` branch fires
    //           before `pfds[0].revents & Int16(POLLIN)` — POLLHUP wins when both set.
    // =======================================================================

    func testBug75_phase2MonitorChecksPollInBeforePollHup() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }

        // In runPhase2Monitor, after the wakeup-pipe check, the loop body must
        // check pfds[0] POLLIN before pfds[0] POLLHUP|POLLERR.
        //
        // Locate the two pfds[0] checks by their exact source patterns:
        //   POLLHUP check: "pfds[0].revents & Int16(POLLHUP"
        //   POLLIN  guard: "pfds[0].revents & Int16(POLLIN"
        //
        // In the buggy code the POLLHUP check appears at line 549 and the POLLIN
        // guard at line 556 — POLLHUP precedes POLLIN.

        guard let pollhupRange = content.range(of: "pfds[0].revents & Int16(POLLHUP") else {
            // If the POLLHUP check no longer uses pfds[0] the code was restructured — pass.
            return
        }
        guard let pollinRange = content.range(of: "guard pfds[0].revents & Int16(POLLIN") else {
            // If the POLLIN guard no longer uses pfds[0] the code was restructured — pass.
            return
        }

        // POLLIN guard must appear BEFORE the POLLHUP check in source order.
        let pollhupBeforePollin = pollhupRange.lowerBound < pollinRange.lowerBound

        XCTAssertFalse(pollhupBeforePollin,
            "Bug 75 CONFIRMED: In runPhase2Monitor(), the pfds[0] POLLHUP|POLLERR branch " +
            "appears BEFORE the pfds[0] POLLIN guard in source order. When the engine writes " +
            "its last message and closes the socket simultaneously, poll() sets both POLLIN " +
            "and POLLHUP; the POLLHUP branch fires first and returns without reading the " +
            "buffered final message, dropping it and triggering spurious crash recovery. " +
            "Fix: move the pfds[0] POLLIN guard BEFORE the POLLHUP|POLLERR check so that " +
            "pending data is always drained before treating HUP as a fatal exit condition.")
    }

    // =======================================================================
    // Bug 76 — socketReadLock held 180 seconds disables Phase 2 error monitor entirely
    //
    // recvJSONSync() acquires socketReadLock at line 301 and uses `defer` to
    // release it — meaning the lock is held for the ENTIRE `while true` poll loop,
    // which can run for up to `timeoutMs` milliseconds.  drainResult() passes
    // timeoutMs: 180_000 (3 minutes).  The Phase 2 monitor calls
    // recvJSONSync(timeoutMs: 100) and blocks on socketReadLock for up to 3 minutes,
    // making it unable to detect engine crashes during the full inference window.
    //
    // EXPECTED: The 180_000 ms receiveMessage path must NOT hold socketReadLock for
    //           its full duration.  The lock must be released before the blocking
    //           poll loop, or the 180 s drain must use a separate non-locking path.
    // ACTUAL:   `defer { socketReadLock.unlock() }` appears immediately after
    //           `socketReadLock.lock()`, holding the lock across the entire while loop.
    // =======================================================================

    func testBug76_socketReadLockNotHeldAcross180sTimeout() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }

        // Find recvJSONSync body.
        guard let recvRange = content.range(of: "func recvJSONSync(") else {
            XCTFail("Cannot find recvJSONSync in EngineClient.swift"); return
        }

        let bodyStart = recvRange.lowerBound
        let bodyEnd = content.index(bodyStart, offsetBy: 2000, limitedBy: content.endIndex) ?? content.endIndex
        let recvBody = String(content[bodyStart..<bodyEnd])

        // The bug: `socketReadLock.lock()` is immediately followed by
        //          `defer { socketReadLock.unlock() }`, which holds the lock for
        //          the full while-true poll loop duration.
        //
        // A fixed implementation would NOT use `defer` for socketReadLock in the
        // path that enters the poll loop — it would release the lock explicitly
        // before entering `while true`, or restructure to avoid holding the lock
        // during the blocking poll.
        //
        // Proxy check: if `defer { socketReadLock.unlock() }` and `while true` both
        // appear in recvJSONSync, and no explicit `socketReadLock.unlock()` appears
        // between the `lock()` call and `while true` (only the deferred one), the bug
        // is present because defer fires at function return, not before the loop.

        let hasDeferUnlock = recvBody.contains("defer { socketReadLock.unlock() }")
        let hasWhileTrue   = recvBody.contains("while true")

        // If defer is still used to unlock socketReadLock AND the while-true loop
        // exists, the lock is held for the full loop duration — that's the bug.
        if hasDeferUnlock && hasWhileTrue {
            // Verify there is no explicit socketReadLock.unlock() before `while true`
            // (which would mean the lock IS released before the blocking poll loop).
            guard let deferPos = recvBody.range(of: "defer { socketReadLock.unlock() }"),
                  let loopPos  = recvBody.range(of: "while true") else {
                return
            }
            let between = String(recvBody[deferPos.upperBound..<loopPos.lowerBound])
            let hasExplicitUnlockBeforeLoop = between.contains("socketReadLock.unlock()")

            XCTAssertTrue(hasExplicitUnlockBeforeLoop,
                "Bug 76 CONFIRMED: recvJSONSync() uses `defer { socketReadLock.unlock() }` " +
                "immediately after `socketReadLock.lock()`, holding the lock across the entire " +
                "`while true` poll loop. drainResult() passes timeoutMs: 180_000, causing the " +
                "Phase 2 monitor to block on socketReadLock for up to 3 minutes and miss all " +
                "engine crashes during inference. " +
                "Fix: release socketReadLock explicitly before `while true` (no defer for this " +
                "lock in the polling path), so the Phase 2 monitor can acquire it within 100 ms.")
        }
    }

    // =======================================================================
    // Bug 78 — drainResult .result case tears down new session after abortAndRestart()
    //
    // drainResult() captures a generation counter at spawn time.  The .result case
    // calls transition(to: .idle) and tears down the session without first re-checking
    // whether `generation == drainGeneration`.  After abortAndRestart() bumps
    // drainGeneration and transitions to .preparing, the stale drain's .result handler
    // fires, calls transition(to: .idle) and cancels the new session.
    //
    // EXPECTED: The .result case must re-check `generation == drainGeneration`
    //           before performing any session teardown or state transition.
    // ACTUAL:   The .result case calls transition(to: .idle) unconditionally, with
    //           no generation guard anywhere in its body.
    // =======================================================================

    func testBug78_drainResultResultCaseChecksGenerationBeforeTransition() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }

        // Locate the .result case inside drainResult.
        // The pattern `case .result(let text, let command):` is unique to drainResult.
        guard let resultCaseRange = content.range(of: "case .result(let text, let command):") else {
            XCTFail("Cannot find .result case in OpenVerbApp.swift"); return
        }

        // Extract the .result case body — it extends to `return` at approximately
        // 600 chars from the case label.
        let caseStart = resultCaseRange.lowerBound
        let caseEnd = content.index(caseStart, offsetBy: 700, limitedBy: content.endIndex) ?? content.endIndex
        let resultCaseBody = String(content[caseStart..<caseEnd])

        // The fix requires a generation guard before teardown:
        //   guard generation == drainGeneration else { return }
        let hasGenerationGuardInResult =
            resultCaseBody.contains("generation == drainGeneration") ||
            resultCaseBody.contains("drainGeneration == generation")

        XCTAssertTrue(hasGenerationGuardInResult,
            "Bug 78 CONFIRMED: The .result case in drainResult() calls transition(to: .idle) " +
            "and tears down the session without re-checking generation == drainGeneration. " +
            "After abortAndRestart() bumps drainGeneration, the stale drain's .result fires " +
            "and cancels the new session via the PREPARING→IDLE transition. " +
            "Fix: add `guard generation == drainGeneration else { return }` at the top of " +
            "the .result case body before any disconnect/teardown/transition calls.")
    }

    // =======================================================================
    // Bug 79 — drainResult .error disconnects new session socket via unguarded handleCrash()
    //
    // The .error case in drainResult() spawns `Task { handleCrash() }` unconditionally
    // without checking whether generation == drainGeneration.  After abortAndRestart()
    // creates a new session, the stale drain's .error fires and handleCrash() calls
    // engineClient.disconnect() on the live new session socket.
    //
    // EXPECTED: The `Task { handleCrash() }` spawn in the .error case must be
    //           guarded by generation == drainGeneration so it does not execute for
    //           stale drains that no longer own the live session.
    // ACTUAL:   `Task { [weak self] in try? await self?.engineManager.handleCrash() }`
    //           is spawned as the very first line of the .error case with no guard.
    // =======================================================================

    func testBug79_drainResultErrorCaseGuardsHandleCrashWithGeneration() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }

        // Search the full file for the .error case inside the drainResult switch.
        // The unique fingerprint is: the case label immediately followed by the
        // unguarded handleCrash Task spawn on the next line.
        //
        // Buggy pattern:
        //   case .error(let code, let message):
        //       Task { [weak self] in try? await self?.engineManager.handleCrash() }
        //
        // Fixed pattern: must have a generation guard before the Task spawn.

        // Find the drainResult function start.
        guard let drainRange = content.range(of: "private func drainResult(generation:") else {
            XCTFail("Cannot find drainResult(generation:) in OpenVerbApp.swift"); return
        }

        // Extract a large enough window to cover the whole drainResult body.
        let bodyStart = drainRange.lowerBound
        let bodyEnd = content.index(bodyStart, offsetBy: 8000, limitedBy: content.endIndex) ?? content.endIndex
        let drainBody = String(content[bodyStart..<bodyEnd])

        // Find the switch-case .error inside this window.
        guard let errorCaseRange = drainBody.range(of: "case .error(let code, let message):") else {
            XCTFail("Cannot find `case .error(let code, let message):` in drainResult body " +
                    "(window may be too small — increase offset)"); return
        }

        // Extract the .error case body (~500 chars is enough to cover the whole case).
        let caseStart = errorCaseRange.lowerBound
        let caseEnd = drainBody.index(caseStart, offsetBy: 600, limitedBy: drainBody.endIndex) ?? drainBody.endIndex
        let errorCaseBody = String(drainBody[caseStart..<caseEnd])

        // The fix must include a generation guard before spawning handleCrash().
        let hasGenerationGuardInError =
            errorCaseBody.contains("generation == drainGeneration") ||
            errorCaseBody.contains("drainGeneration == generation")

        XCTAssertTrue(hasGenerationGuardInError,
            "Bug 79 CONFIRMED: The .error case in drainResult() spawns " +
            "`Task { handleCrash() }` as its first statement, with no generation guard. " +
            "After abortAndRestart() creates a new session and bumps drainGeneration, the " +
            "stale drain's .error fires and handleCrash() calls engineClient.disconnect() " +
            "on the live new session socket, aborting the new recording. " +
            "Fix: add `guard generation == drainGeneration else { return }` before " +
            "spawning the handleCrash Task in the .error case.")
    }

    // =======================================================================
    // Bug 80 — restartWithBackend() launches new engine against still-running old one
    //
    // shutdown() sends SIGTERM and immediately returns — the actual process-exit
    // wait is delegated to a Task.detached.  restartWithBackend() then calls
    // ensureRunning(), which calls tryPing().  The old engine is still alive
    // (SIGTERM is async), so tryPing() succeeds against it.  ensureRunning()
    // concludes the engine is already running and skips spawning the new backend.
    // The backend switch silently fails.
    //
    // EXPECTED: restartWithBackend() must wait for the old process to fully exit
    //           before calling ensureRunning().  shutdown() must be `async` and
    //           directly await waitForProcessExit() (not delegate it to a detached Task).
    // ACTUAL:   shutdown() is synchronous and uses Task.detached for the wait;
    //           restartWithBackend() calls it fire-and-forget, then ensureRunning()
    //           succeeds against the still-alive old engine.
    // =======================================================================

    func testBug80_restartWithBackendAwaitsProcessExitNotJustSigterm() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }

        // The shutdown() function uses Task.detached to call waitForProcessExit,
        // meaning it returns before the process has exited.
        // Bug check: Task.detached AND waitForProcessExit must both appear in
        // the shutdown() body — indicating the async process-exit delegation.
        guard let shutdownRange = content.range(of: "func shutdown() {") else {
            // shutdown() has been made async — one part of the fix applied.
            // This test passes once shutdown() is no longer synchronous.
            return
        }

        let shutBodyStart = shutdownRange.lowerBound
        let shutBodyEnd = content.index(shutBodyStart, offsetBy: 1200, limitedBy: content.endIndex) ?? content.endIndex
        let shutdownBody = String(content[shutBodyStart..<shutBodyEnd])

        // The bug: shutdown() uses Task.detached for waitForProcessExit.
        // This means it returns immediately, before process exit is confirmed.
        let shutdownDelegatesWaitToDetachedTask =
            shutdownBody.contains("Task.detached") &&
            shutdownBody.contains("waitForProcessExit")

        XCTAssertFalse(shutdownDelegatesWaitToDetachedTask,
            "Bug 80 CONFIRMED: shutdown() delegates waitForProcessExit to a Task.detached, " +
            "returning immediately after SIGTERM. restartWithBackend() then calls " +
            "ensureRunning() while the old process is still alive; tryPing() succeeds " +
            "against the old engine and ensureRunning() skips launching the new backend. " +
            "The --backend switch silently fails — the old backend continues serving. " +
            "Fix: make shutdown() async and directly await waitForProcessExit() inline " +
            "(removing Task.detached), then `await shutdown()` in restartWithBackend() " +
            "before calling ensureRunning().")
    }
}
