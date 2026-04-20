import XCTest
@testable import OpenVerb

// Negative tests for: Bug 135, 136
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_135_136: XCTestCase {

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
    // Bug 135 — testQueueStatusDoesNotFirePartialCallback is a tautology
    //
    // PartialAccumulationTests.swift (lines 135–151):
    //   The test decodes a queue_status JSON message, then checks:
    //     if case .partialResult(...) = msg { ... fire callback ... }
    //   A queue_status message can NEVER match the .partialResult case, so the
    //   callback never fires regardless of any real behaviour. XCTAssertFalse(fired)
    //   always passes even if the drain loop were broken to fire the callback
    //   unconditionally — the test proves nothing.
    //
    // EXPECTED: the pattern match uses the CORRECT case for the message that was
    //   actually decoded — `.queueStatus` (or equivalent) — so the `if case` branch
    //   is at least reachable and the test is not trivially vacuous.
    // ACTUAL:   `if case .partialResult` is used to match a .queueStatus message,
    //           which can never match, making the test a structural no-op.
    // =======================================================================

    func testBug135_QueueStatusTestUsesCorrectPatternMatch() {
        guard let src = readSource("OpenVerbTests/PartialAccumulationTests.swift") else {
            XCTFail("Bug 135 CONFIRMED: Cannot read PartialAccumulationTests.swift. Fix: change `if case .partialResult` to `if case .queueStatus` in testQueueStatusDoesNotFirePartialCallback.")
            return
        }

        // Isolate the testQueueStatusDoesNotFirePartialCallback function body.
        guard let funcRange = src.range(of: "func testQueueStatusDoesNotFirePartialCallback()") else {
            XCTFail("Bug 135 CONFIRMED: testQueueStatusDoesNotFirePartialCallback() not found in PartialAccumulationTests.swift — file structure changed.")
            return
        }

        // Extract a window of ~700 chars covering the entire short function body.
        let windowEnd = src.index(funcRange.lowerBound,
                                  offsetBy: 700,
                                  limitedBy: src.endIndex) ?? src.endIndex
        let window = String(src[funcRange.lowerBound..<windowEnd])

        // The tautology: the test sends a queue_status message but matches
        // against .partialResult — a case that can never match for that message.
        let usesTautologicalPattern = window.contains("if case .partialResult") &&
                                      window.contains("queue_status")

        XCTAssertFalse(
            usesTautologicalPattern,
            "Bug 135 CONFIRMED: testQueueStatusDoesNotFirePartialCallback() in PartialAccumulationTests.swift " +
            "decodes a `queue_status` JSON message but then uses `if case .partialResult = msg` — a pattern " +
            "that can never match a .queueStatus value. The callback is never invoked, so XCTAssertFalse(fired) " +
            "is trivially true and proves nothing about the drain loop's actual behaviour. " +
            "Fix: change the `if case` pattern to `.queueStatus` (or the actual associated-value form) so the " +
            "guard branch is at least reachable and the test has a real false-positive risk."
        )
    }

    // =======================================================================
    // Bug 136 — livePartialText not cleared on .error transition
    //
    // AppState.applyEntryEffects (AppState.swift, lines 280–305):
    //   The .error case clears preparingSubtitle and starts the autoClearTimer,
    //   but never resets livePartialText. If a recording session produced partial
    //   transcript text before the error, that text remains in livePartialText
    //   and is visible to the UI for up to 5 seconds — the entire duration of the
    //   error state — appearing alongside the error message.
    //
    // EXPECTED: livePartialText is explicitly cleared (set to "" or .removeAll())
    //   inside the .error case of applyEntryEffects, just as it is in the .idle case.
    // ACTUAL:   the .error case never touches livePartialText, leaving stale
    //           partial transcript visible during the error window.
    // =======================================================================

    func testBug136_LivePartialTextClearedOnErrorTransition() {
        guard let src = readSource("OpenVerb/State/AppState.swift") else {
            XCTFail("Bug 136 CONFIRMED: Cannot read AppState.swift. Fix: add `livePartialText = \"\"` inside the .error case of applyEntryEffects.")
            return
        }

        // Isolate the applyEntryEffects function body, then find its outer `case .error:`
        // (distinct from the inner `case .error:` inside the nested `switch previous`
        // within the `.preparing` branch).  The outer `.error` case immediately precedes
        // the final `case .inferring:` in the switch-on-next block.
        guard let entryFuncRange = src.range(of: "func applyEntryEffects(from previous: State, to next: State)") else {
            XCTFail("Bug 136 CONFIRMED: applyEntryEffects not found in AppState.swift — file structure changed, review manually.")
            return
        }

        // Work only within the applyEntryEffects body (from function start to end of file).
        let entryFuncBody = String(src[entryFuncRange.lowerBound...])

        // The switch has TWO `case .inferring:` occurrences: one in the inner
        // `switch previous` block and one as the final outer case.  We need the LAST
        // occurrence, which is the outer one that terminates the `case .error:` block.
        guard let lastInferringRange = entryFuncBody.range(of: "case .inferring:", options: .backwards) else {
            XCTFail("Bug 136 CONFIRMED: `case .inferring:` not found after applyEntryEffects — file structure changed.")
            return
        }

        // The outer `.error` case body is the text between the last `case .error:` before
        // the final `case .inferring:` and that `case .inferring:` label itself.
        let beforeLastInferring = String(entryFuncBody[entryFuncBody.startIndex..<lastInferringRange.lowerBound])
        guard let lastErrorRange = beforeLastInferring.range(of: "case .error:", options: .backwards) else {
            XCTFail("Bug 136 CONFIRMED: cannot locate outer `case .error:` inside applyEntryEffects — file structure changed.")
            return
        }

        let errorBody = String(beforeLastInferring[lastErrorRange.lowerBound...])

        // The fix requires livePartialText to be reset inside the .error case.
        let clearsLivePartial = errorBody.contains("livePartialText = \"\"") ||
                                errorBody.contains("livePartialText.removeAll()")

        XCTAssertTrue(
            clearsLivePartial,
            "Bug 136 CONFIRMED: AppState.applyEntryEffects .error case does not clear livePartialText. " +
            "Stale partial transcript from a recording session remains visible to the UI for up to 5 seconds " +
            "while the error message is displayed. " +
            "Fix: add `livePartialText = \"\"` inside the .error case of applyEntryEffects, " +
            "matching the reset already present in the .idle case."
        )
    }
}
