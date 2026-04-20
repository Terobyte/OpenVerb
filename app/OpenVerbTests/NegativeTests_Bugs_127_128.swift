import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 127, 128
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_127_128: XCTestCase {

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
    // Bug 127 — Pre-buffer audio silently lost on audioEngine.start() failure
    //
    // AudioSession.start() sets _isCapturing = true BEFORE calling
    // audioEngine.start().  The tap is already installed and can fire during
    // the engine's synchronous AU activation, filling preBuffer with real audio.
    // If audioEngine.start() then throws, the catch block calls
    // inputNode.removeTap() and resets _isCapturing = false — but does NOT
    // preserve, log, or notify about the chunks that accumulated in preBuffer
    // during that window.  On the first successful retry, the pre-buffer is
    // empty; the audio captured before the failure is silently dropped with no
    // indication to the caller.
    //
    // EXPECTED: the catch block on audioEngine.start() failure must either
    //   (a) save preBuffer content so a retry can use it, OR
    //   (b) log or post a notification recording that audio was lost.
    //   The current pattern — clearing preBuffer at line 120 and then silently
    //   resetting state in the catch block — satisfies neither requirement.
    // ACTUAL:   the catch block only removes the tap and resets _isCapturing;
    //           any audio that arrived during engine activation is dropped
    //           without any record.
    // =======================================================================

    func testBug127_PreBufferPreservedOrLoggedOnEngineStartFailure() {
        guard let src = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Bug 127 CONFIRMED: Cannot read AudioSession.swift. Fix: in the audioEngine.start() catch block, either save preBuffer content for retry or log/post a notification about the dropped audio.")
            return
        }

        // Locate the catch block that handles audioEngine.start() failure.
        // The structure is:
        //   do {
        //       try audioEngine.start()
        //   } catch {
        //       inputNode.removeTap(onBus: 0)
        //       lock.lock()
        //       _isCapturing = false
        //       lock.unlock()
        //       throw error
        //   }
        guard let doTryRange = src.range(of: "try audioEngine.start()") else {
            XCTFail("Bug 127 CONFIRMED: `try audioEngine.start()` not found in AudioSession.swift — file structure changed, review manually.")
            return
        }

        // Extract the catch block: search forward from the try for "} catch {"
        // and capture the next ~300 chars as the catch body.
        let afterTry = String(src[doTryRange.upperBound...])
        guard let catchRange = afterTry.range(of: "} catch {") else {
            XCTFail("Bug 127 CONFIRMED: no catch block found after `try audioEngine.start()` in AudioSession.swift.")
            return
        }

        let afterCatch = String(afterTry[catchRange.upperBound...])
        let catchBodyEnd = afterCatch.index(
            afterCatch.startIndex,
            offsetBy: 300,
            limitedBy: afterCatch.endIndex
        ) ?? afterCatch.endIndex
        let catchBody = String(afterCatch[afterCatch.startIndex ..< catchBodyEnd])

        // Option (a): the catch block saves / preserves preBuffer for the caller.
        // A fix would snapshot it before clearing, e.g.:
        //   let savedBuffer = preBuffer  -- and store it somewhere durable
        //   preBuffer = savedBuffer  -- or not clear it at all
        // We look for any reference to preBuffer in the catch body that is NOT
        // just removeAll() (which is the buggy discard).
        let catchPreservesBuffer: Bool = {
            // Presence of `preBuffer` in the catch body where it is being
            // assigned to something (not just cleared).
            let lines = catchBody.components(separatedBy: "\n")
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                // e.g. "let saved = preBuffer" or "preBuffer = preBuffer" (no-op preserve)
                // or simply not calling removeAll on preBuffer in the catch
                if t.contains("preBuffer") && !t.contains("removeAll()") {
                    return true
                }
            }
            return false
        }()

        // Option (b): the catch block logs the loss.  A fix would include a
        // logger call that mentions the dropped audio, e.g.:
        //   logger.warning("preBuffer audio dropped due to engine start failure")
        // We require a logger call inside the catch body that references
        // preBuffer, buffer, drop, or lost audio.
        let catchLogsLoss: Bool = {
            let lower = catchBody.lowercased()
            let hasLoggerCall = lower.contains("logger.") || lower.contains("os_log")
            let mentionsLoss = lower.contains("prebuffer") ||
                               lower.contains("dropped") ||
                               lower.contains("lost") ||
                               lower.contains("audio")
            return hasLoggerCall && mentionsLoss
        }()

        // Option (c): the catch block posts a notification so the caller can act.
        let catchPostsNotification = catchBody.contains("NotificationCenter") ||
                                     catchBody.contains("post(name:")

        XCTAssertTrue(
            catchPreservesBuffer || catchLogsLoss || catchPostsNotification,
            "Bug 127 CONFIRMED: AudioSession.start() catch block silently discards audio " +
            "that accumulated in preBuffer during audioEngine.start() failure. " +
            "_isCapturing is set true BEFORE audioEngine.start() so the tap can fire and fill " +
            "preBuffer; if start() throws, that audio is lost with no log or notification. " +
            "Fix: in the catch block, either (a) preserve preBuffer so a retry can use it, " +
            "(b) log a warning that audio was dropped, or " +
            "(c) post a notification so callers are aware of the loss."
        )
    }

    // =======================================================================
    // Bug 128 — Stale waveform callbacks delivered after stop() — waveform
    //           animates briefly after recording ends
    //
    // processTapBuffer() checks `guard _isCapturing` on the audio thread before
    // building chunksToDisplay, then dispatches each chunk to the main queue via
    // DispatchQueue.main.async { waveformCallback(chunk) }.
    // Because DispatchQueue.main.async blocks cannot be cancelled, any blocks
    // that were enqueued before stop() was processed on the main queue will still
    // fire after stop() completes — waveformCallback is called with stale audio
    // data from the ended session, causing the waveform view to animate for one
    // extra buffer after the recording stops.
    //
    // EXPECTED: a guard inside the DispatchQueue.main.async block checks session
    //   state BEFORE calling waveformCallback, so that blocks enqueued just before
    //   stop() silently no-op instead of firing the callback.  The guard must
    //   test a flag such as `_isCapturing`, `isCapturing`, or a dedicated
    //   `isActive`/`isRunning` property.
    // ACTUAL:   the async block calls waveformCallback(chunk) unconditionally;
    //           there is no state check inside the dispatched closure.
    // =======================================================================

    func testBug128_WaveformCallbackGuardedInsideMainAsyncBlock() {
        guard let src = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Bug 128 CONFIRMED: Cannot read AudioSession.swift. Fix: add a guard that checks _isCapturing (or equivalent) inside the DispatchQueue.main.async block that calls waveformCallback.")
            return
        }

        // Locate the DispatchQueue.main.async block that fires waveformCallback.
        // The current (buggy) pattern is:
        //
        //   for chunk in chunksToDisplay {
        //       DispatchQueue.main.async {
        //           waveformCallback(chunk)
        //       }
        //   }
        //
        // The fix must place a state guard INSIDE the async closure so that
        // stale blocks no-op after stop() runs.  We look for a guard or `if`
        // check on a capturing/running/active flag inside the async block.
        guard let asyncRange = src.range(of: "DispatchQueue.main.async") else {
            XCTFail("Bug 128 CONFIRMED: DispatchQueue.main.async not found near waveformCallback in AudioSession.swift — file structure changed, review manually.")
            return
        }

        // Extract a window starting from the async dispatch up to ~200 chars
        // to cover the closure body.
        let afterAsync = String(src[asyncRange.lowerBound...])
        let windowEnd = afterAsync.index(
            afterAsync.startIndex,
            offsetBy: 200,
            limitedBy: afterAsync.endIndex
        ) ?? afterAsync.endIndex
        let asyncWindow = String(afterAsync[afterAsync.startIndex ..< windowEnd])

        // The closure body must contain a guard or if-check on a state flag
        // BEFORE calling waveformCallback.  Acceptable patterns:
        //   guard self._isCapturing else { return }
        //   guard self?.isCapturing == true else { return }
        //   if !self.isCapturing { return }
        //   guard self.isActive else { return }
        //   guard self.isRunning else { return }
        //   guard let self, self._isCapturing else { return }
        let hasGuardOnCapturing: Bool = {
            let lower = asyncWindow.lowercased()
            // Must contain some form of state check (guard or if) AND a
            // reference to a capturing/active/running flag.
            let hasGuard = lower.contains("guard") || lower.contains("if !")
            let checksCaptureFlag = lower.contains("iscapturing") ||
                                    lower.contains("isactive") ||
                                    lower.contains("isrunning") ||
                                    lower.contains("_iscapturing")
            return hasGuard && checksCaptureFlag
        }()

        XCTAssertTrue(
            hasGuardOnCapturing,
            "Bug 128 CONFIRMED: the DispatchQueue.main.async block in AudioSession.processTapBuffer " +
            "calls waveformCallback(chunk) without checking session state first. " +
            "When stop() is called, already-queued async blocks cannot be cancelled — they still " +
            "execute and fire waveformCallback with stale audio data, making the waveform animate " +
            "briefly after the recording session ends. " +
            "Fix: add `guard self._isCapturing else { return }` (or equivalent) as the first " +
            "statement inside the DispatchQueue.main.async closure, so stale queued blocks " +
            "silently no-op after stop() has cleared the capturing flag."
        )
    }
}
