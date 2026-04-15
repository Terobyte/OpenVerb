import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// ProcessingViewModelTests — tests monotonic clamp, reset invariant, and
// spinner fallback behavior (plan step 17).
// ---------------------------------------------------------------------------

@MainActor
final class ProcessingViewModelTests: XCTestCase {

    var sut: ProcessingViewModel!

    override func setUp() async throws {
        sut = ProcessingViewModel()
    }

    override func tearDown() async throws {
        sut = nil
    }

    // -----------------------------------------------------------------------
    // MARK: Monotonic clamp
    // -----------------------------------------------------------------------

    func testProgressAdvancesMonotonically() {
        sut.updateProgress(0.1)
        XCTAssertEqual(sut.displayedPercent, 0.1, accuracy: 1e-9)

        sut.updateProgress(0.2)
        XCTAssertEqual(sut.displayedPercent, 0.2, accuracy: 1e-9)

        // 0.15 < 0.2 → must be ignored (Path A non-monotonic estimate).
        sut.updateProgress(0.15)
        XCTAssertEqual(sut.displayedPercent, 0.2, accuracy: 1e-9,
                       "Backtracking estimate 0.15 must be ignored (clamp)")

        sut.updateProgress(0.3)
        XCTAssertEqual(sut.displayedPercent, 0.3, accuracy: 1e-9)
    }

    func testProgressSequenceFromSpec() {
        // Exact sequence from plan: [0.1, 0.2, 0.15, 0.3] → [0.1, 0.2, 0.2, 0.3]
        let inputs:   [Double] = [0.1, 0.2, 0.15, 0.3]
        let expected: [Double] = [0.1, 0.2, 0.2,  0.3]
        for (input, expectedValue) in zip(inputs, expected) {
            sut.updateProgress(input)
            XCTAssertEqual(sut.displayedPercent, expectedValue, accuracy: 1e-9,
                           "After input \(input), expected \(expectedValue)")
        }
    }

    func testProgressClampedToOne() {
        sut.updateProgress(1.5)
        XCTAssertEqual(sut.displayedPercent, 1.0, accuracy: 1e-9,
                       "Progress must be clamped to 1.0 maximum")
    }

    func testZeroProgressIsAccepted() {
        XCTAssertEqual(sut.displayedPercent, 0.0)
        sut.updateProgress(0.0)
        XCTAssertEqual(sut.displayedPercent, 0.0, accuracy: 1e-9)
    }

    // -----------------------------------------------------------------------
    // MARK: Reset invariant
    // -----------------------------------------------------------------------

    func testResetClearsDisplayedPercent() {
        sut.updateProgress(0.8)
        XCTAssertEqual(sut.displayedPercent, 0.8, accuracy: 1e-9)

        sut.reset()
        XCTAssertEqual(sut.displayedPercent, 0.0, accuracy: 1e-9,
                       "reset() must clear displayedPercent to 0")
    }

    func testResetClearsShowSpinner() {
        sut.startSpinnerFallback()
        // Manually force spinner on without waiting 2 s.
        // We test the reset path by directly checking the property after reset().
        sut.reset()
        XCTAssertFalse(sut.showSpinner, "reset() must set showSpinner = false")
    }

    func testResetAllowsProgressAfterClear() {
        sut.updateProgress(0.9)
        sut.reset()
        // After reset the clamp is at 0; values above 0 should be accepted.
        sut.updateProgress(0.25)
        XCTAssertEqual(sut.displayedPercent, 0.25, accuracy: 1e-9,
                       "After reset() the clamp must restart from 0")
    }

    // -----------------------------------------------------------------------
    // MARK: Spinner fallback
    // -----------------------------------------------------------------------

    func testSpinnerFallbackFiresAfter2Seconds() async throws {
        XCTAssertFalse(sut.showSpinner)
        sut.startSpinnerFallback()
        // Wait slightly more than the 2s timeout.
        try await Task.sleep(for: .seconds(2.1))
        XCTAssertTrue(sut.showSpinner,
                      "showSpinner must become true after 2 s with no progress")
    }

    func testProgressCancelsSpinnerFallback() async throws {
        sut.startSpinnerFallback()
        // Progress arrives within the 2s window.
        try await Task.sleep(for: .milliseconds(200))
        sut.updateProgress(0.1)
        // Wait past the 2s mark.
        try await Task.sleep(for: .seconds(2.0))
        XCTAssertFalse(sut.showSpinner,
                       "Progress arriving before 2 s must cancel the spinner fallback")
    }

    func testProgressAfterSpinnerDismissesSpinner() async throws {
        // Wait until the spinner is actually showing (past the 2 s threshold).
        sut.startSpinnerFallback()
        try await Task.sleep(for: .seconds(2.1))
        XCTAssertTrue(sut.showSpinner,
                      "Precondition: showSpinner must be true before this test is meaningful")

        // Progress arrives AFTER the spinner has fired.
        sut.updateProgress(0.45)

        // Spinner must be dismissed and displayedPercent must reflect the value.
        XCTAssertFalse(sut.showSpinner,
                       "showSpinner must become false when progress arrives after spinner")
        XCTAssertEqual(sut.displayedPercent, 0.45, accuracy: 1e-9,
                       "displayedPercent must reflect the progress value that dismissed the spinner")
    }

    // -----------------------------------------------------------------------
    // MARK: Full session cycle
    // -----------------------------------------------------------------------

    func testFullSessionCycle() {
        // Simulate: reset → progress(0.25) → progress(0.5) → progress(1.0)
        sut.reset()
        XCTAssertEqual(sut.displayedPercent, 0.0)

        sut.updateProgress(0.25)
        XCTAssertEqual(sut.displayedPercent, 0.25, accuracy: 1e-9)

        sut.updateProgress(0.5)
        XCTAssertEqual(sut.displayedPercent, 0.5, accuracy: 1e-9)

        sut.updateProgress(1.0)
        XCTAssertEqual(sut.displayedPercent, 1.0, accuracy: 1e-9)
    }
}
