import XCTest
import AppKit
@testable import OpenVerb

// ---------------------------------------------------------------------------
// BugsMDTDDTests — TDD tests proving bugs from bugs.md.
//
// Each test describes CORRECT expected behaviour and FAILS because the bug
// exists.  After fixes, all tests here should PASS.
//
// Already-fixed bugs (no failing test possible):
//   Bug 1  — CGEvent tap: passRetained → fixed to passUnretained
//   Bug 4  — recordingWindow.show() before audio start → fixed order
//   Bug 6  — unload_model + inference race → fixed with engine_mutex_
//   Bug 11 — truncateToUTF8Bytes over-stripping → fixed with sequence-length
//
// Untestable without full runtime (model, hardware, IPC):
//   Bug 2  — EngineClient disconnect() fd race (needs real socket)
//   Bug 7  — server.cpp raw `this` in GCD (needs server lifecycle)
//   Bug 8  — session inference_thread_ gap (needs model + full session)
//   Bug 9  — shared RecvBuffer (design concern, not a code error)
//   Bug 12 — StatusBarItem no animation (UI, needs real NSStatusBar)
//   Bug 13 — shutdown() blocks MainActor (mitigated by Task.detached)
//
// Partially testable (API incomplete per Bug 4):
//   Bug 4  — ContextBuilder incomplete (PasteboardReadable, pasteboard param,
//            truncateToUTF8Bytes) — referenced by ContextBuilderTests.swift
// ---------------------------------------------------------------------------

final class BugsMDTDDTests: XCTestCase {

    // =======================================================================
    // Bug 1 — WaveformViewModel.reset() is async when it should be sync.
    //
    // The reset() method wraps amplitudes.removeAll() in DispatchQueue.main.async
    // even though the method is @MainActor. This causes a race condition where
    // stale amplitude bars may briefly appear in the new session.
    //
    // EXPECTED: reset() should clear amplitudes synchronously.
    // ACTUAL: reset() defers clearing to next run loop turn.
    // =======================================================================

    @MainActor
    func testBug1_resetShouldClearAmplitudesSynchronously() {
        let vm = WaveformViewModel()
        let sineData = Self.makeSine(frequency: 1000, amplitude: 0.8)
        vm.updateFromChunk(sineData)
        vm.updateFromChunk(sineData)

        let preResetSum = vm.bins.reduce(0, +)
        vm.reset()

        XCTAssertGreaterThan(preResetSum, 0.001,
                             "Pre-reset: bins must be non-zero after feeding non-silent PCM")
        XCTAssertEqual(vm.bins.reduce(0, +), 0, accuracy: 0.001,
                       "reset() should clear bins synchronously, but bug causes async delay")
    }

    private static func makeSine(frequency: Float, amplitude: Float) -> Data {
        let sampleRate: Float = 16_000
        let sampleCount = Constants.CHUNK_BYTES / MemoryLayout<Int16>.size
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let value = amplitude * sin(2 * .pi * frequency * Float(i) / sampleRate)
            samples[i] = Int16(value * Float(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // =======================================================================
    // Bug 3 — Auto-clear timer can fire during PREPARING, silently killing
    // the session.
    //
    // If Task.sleep completes just before user triggers a new session, the
    // continuation runs after transition(to: .preparing) but the cancellation
    // check is missing, causing an invalid transition from .preparing to .idle.
    //
    // EXPECTED: Timer continuation should check Task.isCancelled before
    //           calling transition.
    // ACTUAL: Timer fires and calls transition from .preparing → .idle.
    // =======================================================================

    @MainActor
    func testBug3_autoClearTimerShouldRespectCancellation() async {
        let appState = AppState()
        appState.errorClearDelay = .milliseconds(50)

        await appState.transition(to: .error("test"))
        XCTAssertEqual(appState.state, .error("test"))

        await appState.transition(to: .preparing)
        XCTAssertEqual(appState.state, .preparing)

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appState.state, .preparing,
                       "Auto-clear timer should have been cancelled by transition to PREPARING")
    }

    // =======================================================================
    // Bug 7 — AppState.preparingSubtitle has public setter, breaking encapsulation.
    //
    // Currently @Published var preparingSubtitle allows direct mutation.
    // Should be @Published private(set) var. This test tries to set the property
    // directly - if private(set), compilation fails.
    //
    // EXPECTED: preparingSubtitle should be @Published private(set).
    // ACTUAL: preparingSubtitle has public setter allowing external mutation.
    // =======================================================================

    func testBug7_preparingSubtitleShouldBeReadOnly() {
        // Check source code for private(set) rather than attempting mutation
        // (which would cause a compile error once the bug is fixed).
        let path = "OpenVerb/State/AppState.swift"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Try absolute path fallback.
            let abs = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/app/OpenVerb/State/AppState.swift"
            guard let c = try? String(contentsOfFile: abs, encoding: .utf8) else {
                XCTFail("Cannot read AppState.swift"); return
            }
            XCTAssertTrue(c.contains("private(set) var preparingSubtitle"),
                          "preparingSubtitle should be private(set) to prevent external mutation")
            return
        }
        XCTAssertTrue(content.contains("private(set) var preparingSubtitle"),
                      "preparingSubtitle should be private(set) to prevent external mutation")
    }
}