import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// RecordingHUDBugsTests — one test per open HUD bug.
// Pattern mirrors OpenBugsNegativeTests.swift: assert CORRECT behaviour and
// fail while the bug exists. GREEN = bug fixed.
// ---------------------------------------------------------------------------

final class RecordingHUDBugsTests: XCTestCase {

    private func readSource(_ relativePath: String) -> String? {
        let direct = URL(fileURLWithPath: relativePath)
        return try? String(contentsOf: direct, encoding: .utf8)
    }

    // =======================================================================
    // Bug A — elapsed-seconds timer stuck at 00:00.
    //
    // Root cause: Timer.publish(...) is re-created inside body on every eval,
    // so SwiftUI replaces the subscription faster than 1 s can elapse.
    //
    // EXPECTED: the publisher is hoisted to @State so its identity is stable.
    // ACTUAL:   Timer.publish is used inline inside .onReceive in body.
    // =======================================================================

    func testBugA_ElapsedSecondsTimerPublisherIsHoistedToState() {
        guard let src = readSource("OpenVerb/UI/RecordingWindow.swift") else {
            XCTFail("Cannot read RecordingWindow.swift"); return
        }
        // The stable fix pattern is a @State-owned publisher named `ticker`
        // (or similar). Assert the file declares one.
        let hasStatePublisher = src.contains("@State private var ticker") ||
                                src.contains("@State private let ticker") ||
                                src.contains("@State private var elapsedTicker") ||
                                src.contains("@State private let elapsedTicker")
        XCTAssertTrue(hasStatePublisher,
            "Bug A: Timer.publish must be hoisted to a @State property so " +
            "SwiftUI does not re-subscribe on every body eval.")

        // Negative assertion: the inline usage pattern must not remain.
        XCTAssertFalse(
            src.contains(".onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect())"),
            "Bug A: inline Timer.publish(...).autoconnect() inside .onReceive keeps " +
            "re-subscribing and never fires.")
    }

    // =======================================================================
    // Bug B — waveform bars appear static.
    //
    // Root cause: outer .animation(.easeInOut(duration: 0.2), value: …)
    // wraps WaveformView and overrides its inner 0.05 s linear animation.
    //
    // EXPECTED: the outer easeInOut 0.2s animations are removed or scoped to
    //           a container that does NOT include WaveformView.
    // ACTUAL:   two such modifiers sit on the root ZStack.
    // =======================================================================

    func testBugB_OuterAnimationDoesNotEngulfWaveform() {
        guard let src = readSource("OpenVerb/UI/RecordingWindow.swift") else {
            XCTFail("Cannot read RecordingWindow.swift"); return
        }
        // The pre-fix version has these two lines together at the bottom of
        // body; the fix either removes them or moves them onto a narrower
        // container. Assert the offending pair no longer sits on the root.
        let pattern =
            ".animation(.easeInOut(duration: 0.2), value: showRecording)\n" +
            "        .animation(.easeInOut(duration: 0.2), value: showInferring)"
        XCTAssertFalse(src.contains(pattern),
            "Bug B: outer .animation(.easeInOut(0.2)) on the root ZStack " +
            "overrides WaveformView's 0.05 s linear and freezes the bars.")
    }

    // =======================================================================
    // Bug C — live partial transcript never shown.
    //
    // Root cause: AppSettings.showLiveTranscript defaults to false; the UI
    // gate never fires even though partial_result messages arrive and
    // appState.livePartialText accumulates correctly.
    //
    // EXPECTED: default is true so fresh installs see the live text.
    // ACTUAL:   default is false.
    // =======================================================================

    func testBugC_ShowLiveTranscriptDefaultsToTrue() {
        guard let src = readSource("OpenVerb/Settings/AppSettings.swift") else {
            XCTFail("Cannot read AppSettings.swift"); return
        }
        XCTAssertTrue(
            src.contains("var showLiveTranscript: Bool = true"),
            "Bug C: showLiveTranscript default must be true so live partial " +
            "text is visible out-of-the-box.")
        XCTAssertFalse(
            src.contains("var showLiveTranscript: Bool = false"),
            "Bug C: the old default literal is still in the file.")
    }
}
