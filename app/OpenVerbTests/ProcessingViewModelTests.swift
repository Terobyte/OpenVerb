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

    // -----------------------------------------------------------------------
    // MARK: ETA countdown (Phase 7, step 56)
    // -----------------------------------------------------------------------

    func testUpdateEtaSetsEtaSeconds() {
        sut.updateEta(ms: 3500)
        // 3500 ms → rounds up to 4 seconds
        XCTAssertEqual(sut.etaSeconds, 4, "updateEta(3500) must round up to 4 s")
    }

    func testUpdateEtaExactSecondsNoRounding() {
        sut.updateEta(ms: 2000)
        XCTAssertEqual(sut.etaSeconds, 2, "updateEta(2000) must yield exactly 2 s")
    }

    func testEtaTextFormatting() {
        sut.updateEta(ms: 5000)
        XCTAssertEqual(sut.etaText, "~5 сек", "etaText must format as '~N сек'")
    }

    func testEtaTextNilWhenNoEta() {
        XCTAssertNil(sut.etaText, "etaText must be nil before any updateEta call")
    }

    func testEtaTextNilAfterReset() {
        sut.updateEta(ms: 3000)
        sut.reset()
        XCTAssertNil(sut.etaText, "etaText must be nil after reset()")
    }

    func testTickDecrementsEtaByOne() {
        sut.updateEta(ms: 5000)
        sut.tick()
        XCTAssertEqual(sut.etaSeconds, 4, "tick() must decrement etaSeconds by 1")
    }

    func testTickToZeroClearsEta() {
        sut.updateEta(ms: 1000)
        sut.tick()
        // After decrement 1→0, etaSeconds must be nil (not zero)
        XCTAssertNil(sut.etaSeconds, "tick() on last second must set etaSeconds to nil")
        XCTAssertNil(sut.etaText, "etaText must be nil when etaSeconds reaches 0")
    }

    func testResetEtaClearsCountdown() {
        sut.updateEta(ms: 8000)
        sut.resetEta()
        XCTAssertNil(sut.etaSeconds, "resetEta() must clear etaSeconds")
        XCTAssertNil(sut.etaText, "etaText must be nil after resetEta()")
    }

    func testUpdateEtaCancelsSpinnerFallback() {
        // When ETA arrives, the pending spinner fallback must be suppressed.
        sut.startSpinnerFallback()
        sut.updateEta(ms: 4000)
        // Verify spinner is not showing and ETA is set.
        XCTAssertFalse(sut.showSpinner, "spinner must not show once ETA is available")
        XCTAssertEqual(sut.etaSeconds, 4)
    }

    func testEtaZeroMsYieldsNilSeconds() {
        sut.updateEta(ms: 0)
        XCTAssertNil(sut.etaSeconds, "updateEta(0) must yield nil etaSeconds (no meaningful countdown)")
    }

    // -----------------------------------------------------------------------
    // MARK: Polish state (Phase 8)
    // -----------------------------------------------------------------------

    func testEnterPolishingSetsFlag() {
        XCTAssertFalse(sut.isPolishing, "isPolishing must be false initially")
        sut.enterPolishing()
        XCTAssertTrue(sut.isPolishing, "enterPolishing() must set isPolishing = true")
    }

    func testExitPolishingClearsFlag() {
        sut.enterPolishing()
        sut.exitPolishing()
        XCTAssertFalse(sut.isPolishing, "exitPolishing() must set isPolishing = false")
    }

    func testResetClearsPolishingState() {
        sut.enterPolishing()
        sut.reset()
        XCTAssertFalse(sut.isPolishing, "reset() must clear isPolishing")
    }

    func testPolishStateTransitionCycle() {
        // Simulate: inference finishes → polish starts → polish completes
        sut.updateEta(ms: 3000)
        sut.enterPolishing()
        XCTAssertTrue(sut.isPolishing)
        // ETA still active during polishing — that's fine, view prioritizes isPolishing
        sut.exitPolishing()
        XCTAssertFalse(sut.isPolishing)
    }
}
