import XCTest
import AppKit
@testable import OpenVerb

// Negative test for: Bug 139
// Test FAILS while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bug_139: XCTestCase {

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
    // Bug 139 — autoClearTimer cancellation is timing-sensitive — intermittent
    //           test flakiness under load
    //
    // BugsMDTDDTests.testBug3_autoClearTimerShouldRespectCancellation sets
    // errorClearDelay to 50 ms, then sleeps 100 ms waiting for the race.
    // Under scheduler load the 50 ms Task.sleep can fire BEFORE cancel() is
    // processed, causing transition(to: .preparing) to see .idle instead of
    // .preparing — an intermittent false-negative.
    //
    // The root cause is that the test uses a 50 ms delay that is not
    // sufficiently larger than the system sleep granularity, and there is no
    // documented minimum safe ratio between errorClearDelay and the sleep used
    // in the test that waits for cancellation to take effect.
    //
    // A robust fix requires one of:
    //   (a) The test sets errorClearDelay to a value large enough that
    //       cancellation reliably wins before the timer fires (e.g. >= 1 s),
    //       and the verification sleep stays much shorter (e.g. 100 ms).
    //   (b) AppState exposes the autoClearTimer handle as internal/testable so
    //       the test can await the task's cancellation directly instead of
    //       relying on a fixed sleep.
    //
    // EXPECTED: Either —
    //   (a) testBug3 uses errorClearDelay >= .milliseconds(500) (at least 5x
    //       the verification sleep of 100 ms), so there is a sufficient margin
    //       for cancel() to take effect before the timer fires; OR
    //   (b) AppState exposes `internal var autoClearTimer` so tests can
    //       directly await task completion instead of using a blind sleep.
    // ACTUAL:
    //   errorClearDelay = .milliseconds(50) and the verification sleep is
    //   100 ms — only a 2x margin, which is not reliable under scheduler load.
    //   autoClearTimer is private, so direct await-based verification is not
    //   possible.
    // =======================================================================

    func testBug139_AutoClearTimerDelayOrExposureIsSufficientForRobustTests() {
        guard let testSrc = readSource("OpenVerbTests/BugsMDTDDTests.swift") else {
            XCTFail(
                "Bug 139 CONFIRMED: Cannot read BugsMDTDDTests.swift. " +
                "Fix: set errorClearDelay to >= .milliseconds(500) in testBug3 so cancel() " +
                "reliably wins over the timer before the 100 ms verification sleep elapses."
            )
            return
        }

        guard let appSrc = readSource("OpenVerb/State/AppState.swift") else {
            XCTFail(
                "Bug 139 CONFIRMED: Cannot read AppState.swift. " +
                "Fix: expose `internal var autoClearTimer` so tests can await the task " +
                "directly, OR document a safe errorClearDelay minimum in AppState."
            )
            return
        }

        // --- Option (a): test uses a delay large enough to be reliable ----------
        //
        // The test body for testBug3 sets errorClearDelay.  We extract the
        // relevant test method and check whether the millisecond value used is
        // >= 500 (a 5x margin over the 100 ms verification sleep).
        //
        // Locate the testBug3 method body.
        let testMethodMarker = "func testBug3_autoClearTimerShouldRespectCancellation"
        let hasLargeSafeDelay: Bool = {
            guard let markerRange = testSrc.range(of: testMethodMarker) else { return false }
            // Extract up to 400 chars of the method body.
            let bodyStart = markerRange.upperBound
            let bodyEnd = testSrc.index(bodyStart,
                                        offsetBy: 400,
                                        limitedBy: testSrc.endIndex) ?? testSrc.endIndex
            let body = String(testSrc[bodyStart..<bodyEnd])

            // Look for errorClearDelay = .milliseconds(<N>) and parse N.
            // A safe delay is N >= 500.
            guard let assignRange = body.range(of: "errorClearDelay = .milliseconds(") else {
                // Might use .seconds() — that is always safe.
                return body.contains("errorClearDelay = .seconds(")
            }
            let afterParen = String(body[assignRange.upperBound...])
            let digits = afterParen.prefix(while: { $0.isNumber })
            guard let ms = Int(digits) else { return false }
            return ms >= 500
        }()

        // --- Option (b): autoClearTimer is at least internal (not private) ------
        //
        // If the property is `internal var autoClearTimer` or
        // `var autoClearTimer` (no access modifier = internal), tests can
        // `await task.value` to observe cancellation deterministically.
        let timerIsInternal: Bool = {
            // Must NOT be `private var autoClearTimer` or
            // `private(set) var autoClearTimer`.
            // Must be a plain `var autoClearTimer` (internal access).
            let isPrivate = appSrc.contains("private var autoClearTimer") ||
                            appSrc.contains("private(set) var autoClearTimer")
            let exists    = appSrc.contains("var autoClearTimer")
            return exists && !isPrivate
        }()

        XCTAssertTrue(
            hasLargeSafeDelay || timerIsInternal,
            "Bug 139 CONFIRMED: autoClearTimer cancellation race makes tests flaky under load. " +
            "testBug3_autoClearTimerShouldRespectCancellation sets errorClearDelay = .milliseconds(50) " +
            "and relies on a 100 ms blind sleep to verify cancellation — only a 2x margin, " +
            "which is insufficient under scheduler load. " +
            "The timer fires BEFORE cancel() takes effect, causing the test to see .idle " +
            "instead of .preparing, producing an intermittent false-negative. " +
            "Fix option (a): change errorClearDelay to >= .milliseconds(500) in testBug3 " +
            "(5x margin over the 100 ms verification sleep). " +
            "Fix option (b): change `private var autoClearTimer` to `var autoClearTimer` " +
            "(internal) so tests can await the task directly instead of using a blind sleep."
        )
    }
}
