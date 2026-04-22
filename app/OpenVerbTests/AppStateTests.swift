import XCTest
import AppKit
@testable import OpenVerb

// ---------------------------------------------------------------------------
// AppStateTests — validates the AppState state machine transitions and
// side effects described in the MVP3 plan step 3.
// ---------------------------------------------------------------------------

/// Lightweight mock for NSRunningApplication injection.
/// NSRunningApplication is a concrete class and cannot be subclassed, so we
/// use a custom wrapper that carries the values we care about.
final class MockApp {
    let bundleIdentifier: String?
    let localizedName: String?
    init(bundleIdentifier: String? = "com.example.TestApp",
         localizedName: String? = "TestApp") {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }
}

@MainActor
final class AppStateTests: XCTestCase {

    var sut: AppState!
    // Sentinel NSRunningApplication substituted by the mock provider.
    var mockTarget: NSRunningApplication?

    override func setUp() async throws {
        sut = AppState()
        // Wire a mock frontmost-app provider so tests don't depend on the
        // real NSWorkspace.
        mockTarget = NSRunningApplication.current
        sut.frontmostApplicationProvider = { [weak self] in self?.mockTarget }
        // Suppress assertionFailure so invalid-transition tests don't crash.
        sut.invalidTransitionAction = { _ in }
    }

    override func tearDown() async throws {
        sut = nil
        mockTarget = nil
    }

    // -----------------------------------------------------------------------
    // MARK: Valid transitions — happy path
    // -----------------------------------------------------------------------

    func testIdleToPreparingSetsTargetApp() {
        XCTAssertEqual(sut.state, .idle)
        sut.transition(to: .preparing)
        XCTAssertEqual(sut.state, .preparing)
        // targetApp must be captured from the mock provider on IDLE→PREPARING.
        XCTAssertEqual(sut.targetApp, mockTarget)
    }

    func testPreparingToRecordingClearsPreparingSubtitle() {
        // Drive through abort+restart to set subtitle synchronously (no async timer needed).
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        sut.transition(to: .preparing)  // sets "Reconnecting..."
        sut.transition(to: .recording)
        XCTAssertEqual(sut.state, .recording)
        XCTAssertNil(sut.preparingSubtitle, "preparingSubtitle must be cleared on PREPARING→RECORDING")
    }

    func testPreparingToIdleClearsTargetApp() {
        sut.transition(to: .preparing)
        XCTAssertNotNil(sut.targetApp)
        sut.transition(to: .idle)
        XCTAssertEqual(sut.state, .idle)
        XCTAssertNil(sut.targetApp, "targetApp must be cleared when transitioning back to IDLE")
    }

    func testRecordingToInferring() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        XCTAssertEqual(sut.state, .inferring)
    }

    func testInferringToIdleClearsTargetApp() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        sut.transition(to: .idle)
        XCTAssertEqual(sut.state, .idle)
        XCTAssertNil(sut.targetApp)
    }

    // -----------------------------------------------------------------------
    // MARK: remainingInferenceMs — Phase 7, step 51
    // -----------------------------------------------------------------------

    func testRemainingInferenceMsIsNilInitially() {
        XCTAssertNil(sut.remainingInferenceMs,
                     "remainingInferenceMs must be nil before any session")
    }

    // Note: remainingInferenceMs is private(set) — cannot be set externally.
    // The test below verifies the initial state and that clearing on .idle
    // works (the property starts nil and transitions to .idle keep it nil).
    func testRemainingInferenceMsIsNilOnInferringEntry() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        // remainingInferenceMs is private(set); we can only read it.
        // It starts nil and is only set by the production engine client.
        XCTAssertNil(sut.remainingInferenceMs,
                     "remainingInferenceMs must be nil on initial INFERRING entry (no engine data yet)")
    }

    func testRemainingInferenceMsClearedOnIdleTransition() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        // remainingInferenceMs is private(set) so we verify the idle-transition
        // clears it from its natural nil state (already nil → stays nil).
        sut.transition(to: .idle)
        XCTAssertNil(sut.remainingInferenceMs,
                     "remainingInferenceMs must be nil after transitioning to .idle")
    }

    func testRecordingToIdleCancelClearsTargetApp() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .idle)
        XCTAssertEqual(sut.state, .idle)
        XCTAssertNil(sut.targetApp)
    }

    // -----------------------------------------------------------------------
    // MARK: INFERRING→PREPARING (abort+restart) preserves targetApp
    // -----------------------------------------------------------------------

    func testAbortAndRestartPreservesTargetApp() {
        var providerCallCount = 0
        sut.frontmostApplicationProvider = { [weak self] in
            providerCallCount += 1
            return self?.mockTarget
        }

        sut.transition(to: .preparing)
        XCTAssertEqual(providerCallCount, 1,
                       "Provider must be called exactly once for IDLE→PREPARING")
        let captured = sut.targetApp
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        sut.transition(to: .preparing)  // abort+restart
        XCTAssertEqual(sut.state, .preparing)
        XCTAssertEqual(providerCallCount, 1,
                       "Provider must NOT be called again on INFERRING→PREPARING — targetApp is preserved, not re-captured")
        XCTAssertTrue(sut.targetApp === captured,
                       "INFERRING→PREPARING must preserve targetApp — same object identity")
    }

    // -----------------------------------------------------------------------
    // MARK: Invalid transitions — must not change state
    // -----------------------------------------------------------------------

    func testIdleToRecordingIsInvalid() {
        let before = sut.state
        var invalidTransitionFired = false
        var receivedMessage: String?
        sut.invalidTransitionAction = { msg in
            invalidTransitionFired = true
            receivedMessage = msg
        }
        sut.transition(to: .recording)  // invalid
        XCTAssertTrue(invalidTransitionFired,
                      "invalidTransitionAction must fire on invalid IDLE→RECORDING")
        XCTAssertNotNil(receivedMessage,
                        "Invalid transition message must be provided")
        XCTAssertEqual(sut.state, before,
                       "Invalid IDLE→RECORDING must not change state")
    }

    func testIdleToInferringIsInvalid() {
        var invalidTransitionFired = false
        sut.invalidTransitionAction = { _ in
            invalidTransitionFired = true
        }
        sut.transition(to: .inferring)  // invalid
        XCTAssertTrue(invalidTransitionFired,
                      "invalidTransitionAction must fire on invalid IDLE→INFERRING")
        XCTAssertEqual(sut.state, .idle)
    }

    // -----------------------------------------------------------------------
    // MARK: preparingSubtitle lifecycle
    // -----------------------------------------------------------------------

    func testPreparingSubtitleSetAndCleared() {
        sut.transition(to: .preparing)
        XCTAssertNil(sut.preparingSubtitle)  // timer hasn't fired yet

        // Drive through abort+restart to populate subtitle synchronously.
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        sut.transition(to: .preparing)  // sets "Reconnecting..."
        XCTAssertEqual(sut.preparingSubtitle, "Reconnecting...")

        sut.transition(to: .recording)
        XCTAssertNil(sut.preparingSubtitle, "Must be nil after PREPARING→RECORDING")
    }

    func testPreparingSubtitleClearedOnCancelToIdle() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        sut.transition(to: .preparing)  // sets "Reconnecting..."
        sut.transition(to: .idle)
        XCTAssertNil(sut.preparingSubtitle)
    }

    // -----------------------------------------------------------------------
    // MARK: Error state
    // -----------------------------------------------------------------------

    func testAnyToErrorTransition() {
        // From idle
        sut.transition(to: .error("mic unavailable"))
        XCTAssertEqual(sut.state, .error("mic unavailable"))

        // From preparing
        sut = AppState()
        sut.invalidTransitionAction = { _ in }
        sut.frontmostApplicationProvider = { [weak self] in self?.mockTarget }
        sut.transition(to: .preparing)
        sut.transition(to: .error("connection failed"))
        XCTAssertEqual(sut.state, .error("connection failed"),
                       "PREPARING→ERROR must be valid")

        // From recording
        sut = AppState()
        sut.invalidTransitionAction = { _ in }
        sut.frontmostApplicationProvider = { [weak self] in self?.mockTarget }
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .error("mic dropped"))
        XCTAssertEqual(sut.state, .error("mic dropped"),
                       "RECORDING→ERROR must be valid")

        // From inferring
        sut = AppState()
        sut.invalidTransitionAction = { _ in }
        sut.frontmostApplicationProvider = { [weak self] in self?.mockTarget }
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        sut.transition(to: .error("engine crash"))
        XCTAssertEqual(sut.state, .error("engine crash"),
                       "INFERRING→ERROR must be valid")
    }

    func testErrorToErrorIsIgnored() {
        sut.transition(to: .error("first"))
        XCTAssertEqual(sut.state, .error("first"))

        // Second error while already in error — must be silently ignored.
        sut.transition(to: .error("second"))
        XCTAssertEqual(sut.state, .error("first"),
                       "ERROR→ERROR must be ignored; first error message must be preserved")
    }

    // -----------------------------------------------------------------------
    // MARK: ERROR→PREPARING — ⌥Space during error auto-clear window
    // -----------------------------------------------------------------------

    func testErrorToPreparingClearsErrorAndKeepsTargetApp() async throws {
        // Use a short delay so we can verify the timer is cancelled quickly.
        sut.errorClearDelay = .milliseconds(80)

        // Reach a state where targetApp was captured.
        sut.transition(to: .preparing)
        let captured = sut.targetApp
        sut.transition(to: .recording)
        sut.transition(to: .error("engine crash"))

        // ⌥Space during error window → ERROR→PREPARING immediately.
        sut.transition(to: .preparing)
        XCTAssertEqual(sut.state, .preparing)
        // targetApp kept from before the error.
        XCTAssertEqual(sut.targetApp, captured)

        // Verify the auto-clear timer was cancelled: waiting past the delay
        // must NOT transition to .idle — we should remain in .preparing.
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(sut.state, .preparing,
                       "ERROR→PREPARING must cancel the auto-clear timer; state must remain .preparing after delay")
    }

    func testErrorToPreparingWithNilTargetAppRecaptures() {
        // Error from idle — no targetApp was ever set.
        sut.transition(to: .error("engine crash"))
        sut.transition(to: .preparing)
        XCTAssertEqual(sut.state, .preparing)
        // Should re-capture from frontmostApplicationProvider since it was nil.
        XCTAssertEqual(sut.targetApp, mockTarget)
    }

    // -----------------------------------------------------------------------
    // MARK: preparingSubtitle cleared on ERROR entry and on ERROR→PREPARING retry
    // -----------------------------------------------------------------------

    /// Regression: PREPARING → (500 ms) → subtitle shown → PREPARING→ERROR →
    ///   ERROR→PREPARING must NOT show stale "Preparing..." immediately.
    func testPreparingSubtitleClearedOnEnteringError() async throws {
        sut.preparingSubtitleDelay = .milliseconds(50)
        sut.transition(to: .preparing)

        // Let the subtitle timer fire so preparingSubtitle = "Preparing..."
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sut.preparingSubtitle, "Preparing...",
                       "Precondition: subtitle must be shown after delay")

        // Simulate connection failure: PREPARING → ERROR
        sut.transition(to: .error("connection failed"))

        // Entering ERROR must clear the stale subtitle immediately.
        XCTAssertNil(sut.preparingSubtitle,
                     "preparingSubtitle must be nil after PREPARING→ERROR — stale subtitle must not persist")
    }

    /// Regression: start, cancel after 100 ms, start again — the second PREPARING
    ///   window must not show "Preparing..." until its own 500 ms have elapsed.
    func testCancelAndRestartDoesNotShowSubtitlePrematurely() async throws {
        sut.preparingSubtitleDelay = .milliseconds(200)
        sut.errorClearDelay = .milliseconds(50)

        // Session 1: PREPARING → ERROR (subtitle never shown — error before delay)
        sut.transition(to: .preparing)
        sut.transition(to: .error("connection failed"))
        XCTAssertNil(sut.preparingSubtitle,
                     "No subtitle should show when error arrives before delay")

        // Session 2: ERROR → PREPARING (⌥Space retry)
        sut.transition(to: .preparing)
        // Immediately after the transition, subtitle must still be nil.
        XCTAssertNil(sut.preparingSubtitle,
                     "ERROR→PREPARING must not show subtitle immediately — 500 ms window required")
    }

    /// Full sequence: shown subtitle is cleared on PREPARING→ERROR then on
    ///   ERROR→PREPARING the timer restarts and shows subtitle only after delay.
    func testSubtitleTimerRestartsAfterErrorRecovery() async throws {
        sut.preparingSubtitleDelay = .milliseconds(60)
        sut.errorClearDelay = .milliseconds(200)

        // Session 1 — let subtitle appear, then fail.
        sut.transition(to: .preparing)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sut.preparingSubtitle, "Preparing...")

        sut.transition(to: .error("boom"))
        XCTAssertNil(sut.preparingSubtitle, "Must clear on PREPARING→ERROR")

        // Session 2 — ⌥Space retry, subtitle should reappear after 60 ms.
        sut.transition(to: .preparing)
        XCTAssertNil(sut.preparingSubtitle, "Must be nil immediately after ERROR→PREPARING")

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(sut.preparingSubtitle, "Preparing...",
                       "Subtitle must reappear after preparingSubtitleDelay in the new session")
    }

    // -----------------------------------------------------------------------
    // MARK: 5-second auto-clear timer
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // MARK: livePartialText and polishedText (Phase 8)
    // -----------------------------------------------------------------------

    func testLivePartialTextIsEmptyInitially() {
        XCTAssertEqual(sut.livePartialText, "",
                       "livePartialText must be empty string initially")
    }

    func testLivePartialTextClearedOnIdleTransition() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.livePartialText = "hello world"
        sut.transition(to: .inferring)
        sut.transition(to: .idle)
        XCTAssertEqual(sut.livePartialText, "",
                       "livePartialText must be cleared on transition to .idle")
    }

    func testLivePartialTextClearedOnPreparingAbortRestart() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.livePartialText = "partial text"
        sut.transition(to: .inferring)
        sut.transition(to: .preparing)  // abort+restart
        XCTAssertEqual(sut.livePartialText, "",
                       "livePartialText must be cleared on INFERRING→PREPARING (abort+restart)")
    }

    func testPolishedTextNilInitially() {
        XCTAssertNil(sut.polishedText,
                     "polishedText must be nil initially")
    }

    // Note: polishedText is private(set) — cannot be set externally.
    // Tests verify that transitions leave the property nil (it starts nil and
    // is only set by the production engine result delivery path).
    func testPolishedTextClearedOnIdleTransition() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        // polishedText is private(set); the production path sets it.
        // We verify it's nil before any engine data and after idle.
        sut.transition(to: .idle)
        XCTAssertNil(sut.polishedText,
                     "polishedText must be nil on transition to .idle")
    }

    func testPolishedTextClearedOnPreparingAbortRestart() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        // polishedText is private(set); verify it is nil on INFERRING→PREPARING.
        sut.transition(to: .preparing)
        XCTAssertNil(sut.polishedText,
                     "polishedText must be nil on INFERRING→PREPARING abort restart")
    }

    // -----------------------------------------------------------------------
    // MARK: 5-second auto-clear timer
    // -----------------------------------------------------------------------

    func testErrorAutoClearTimerTransitionsToIdle() async throws {
        // Inject a 80 ms delay so this test does not need a real 5-second wait.
        sut.errorClearDelay = .milliseconds(80)

        sut.transition(to: .error("test error"))
        XCTAssertEqual(sut.state, .error("test error"))

        // Confirm state is still .error before the timer fires.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(sut.state, .error("test error"),
                       "State must remain .error before the delay elapses")

        // Wait past the injected delay for the auto-clear task to fire.
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(sut.state, .idle,
                       "State must auto-clear to .idle after errorClearDelay elapses")
        XCTAssertNil(sut.targetApp)
    }

    // -----------------------------------------------------------------------
    // MARK: Bug 175 — abort+restart integration
    //
    // Exercises the complete INFERRING → PREPARING → RECORDING restart cycle
    // end-to-end, across multiple iterations, verifying that targetApp, live
    // text, and polished text invariants hold across arbitrarily many cycles.
    // -----------------------------------------------------------------------

    func testBug175_fullAbortRestartCycleReturnsToIdle() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.transition(to: .inferring)
        sut.transition(to: .idle)
        XCTAssertEqual(sut.state, .idle)
        XCTAssertNil(sut.targetApp,
            "Full abort+restart cycle must leave targetApp nil on .idle")
    }

    func testBug175_threeConsecutiveAbortRestartsPreserveTargetApp() {
        var providerCalls = 0
        sut.frontmostApplicationProvider = { [weak self] in
            providerCalls += 1
            return self?.mockTarget
        }
        sut.transition(to: .preparing)
        let captured = sut.targetApp
        for _ in 0..<3 {
            sut.transition(to: .recording)
            sut.transition(to: .inferring)
            sut.transition(to: .preparing)  // abort+restart
        }
        XCTAssertEqual(providerCalls, 1,
            "3 abort+restart cycles must not re-capture targetApp — it is preserved")
        XCTAssertTrue(sut.targetApp === captured,
            "targetApp identity must survive 3 consecutive abort+restart cycles")
    }

    func testBug175_abortRestartClearsInFlightLiveAndPolishedText() {
        sut.transition(to: .preparing)
        sut.transition(to: .recording)
        sut.livePartialText = "hello partial"
        sut.transition(to: .inferring)
        sut.transition(to: .preparing)  // abort+restart
        XCTAssertEqual(sut.livePartialText, "",
            "livePartialText must be cleared on abort+restart (Bug 136 fix)")
        XCTAssertNil(sut.polishedText,
            "polishedText must be nil on abort+restart (Bug 166 fix)")
    }

    func testBug175_errorToPreparingIsAbortRestartPath() {
        // .error → .preparing is also an abort+restart entry point.
        sut.errorClearDelay = .milliseconds(100)
        sut.transition(to: .preparing)
        let captured = sut.targetApp
        sut.transition(to: .recording)
        sut.livePartialText = "text before error"
        sut.transition(to: .error("engine died"))
        sut.transition(to: .preparing)  // ⌥Space retry
        XCTAssertEqual(sut.state, .preparing)
        XCTAssertTrue(sut.targetApp === captured,
            ".error → .preparing must preserve the prior targetApp")
        XCTAssertEqual(sut.livePartialText, "",
            ".error → .preparing must clear livePartialText")
    }
}
