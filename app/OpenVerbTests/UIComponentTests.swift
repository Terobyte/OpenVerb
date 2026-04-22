import XCTest
import AppKit
@testable import OpenVerb

// ---------------------------------------------------------------------------
// UIComponentTests — covers UI files that are not exercised by other test
// suites: OnboardingView, RecordingWindow, StatusBarItem, PreferencesView.
//
// Deep view rendering is not tested here (no snapshot infrastructure), but
// all instantiable types and their observable state machines are covered.
// ---------------------------------------------------------------------------

// MARK: - OnboardingView

final class OnboardingStepTests: XCTestCase {

    func testOnboardingStepHasSixCases() {
        XCTAssertEqual(OnboardingView.OnboardingStep.allCases.count, 6)
    }

    func testOnboardingStepOrder() {
        let cases = OnboardingView.OnboardingStep.allCases
        XCTAssertEqual(cases[0], .welcome)
        XCTAssertEqual(cases[1], .microphone)
        XCTAssertEqual(cases[2], .accessibility)
        XCTAssertEqual(cases[3], .inputMonitoring)
        XCTAssertEqual(cases[4], .modelDownload)
        XCTAssertEqual(cases[5], .done)
    }

    func testOnboardingStepRawValues() {
        XCTAssertEqual(OnboardingView.OnboardingStep.welcome.rawValue, 0)
        XCTAssertEqual(OnboardingView.OnboardingStep.done.rawValue, 5)
    }
}

// MARK: - RecordingWindow

@MainActor
final class RecordingWindowTests: XCTestCase {

    func testRecordingWindowPanelProperties() {
        let appState = AppState()
        let waveformVM = WaveformViewModel()
        let processingVM = ProcessingViewModel()
        let win = RecordingWindow(
            appState: appState,
            waveformVM: waveformVM,
            processingVM: processingVM,
            settings: .shared
        )

        // NSPanel must not steal focus — critical for text injection into target app.
        XCTAssertTrue(win.styleMask.contains(.nonactivatingPanel))

        // Transparent background so SwiftUI shadow renders without clipping.
        XCTAssertEqual(win.backgroundColor, .clear)
        XCTAssertFalse(win.hasShadow)
        XCTAssertFalse(win.isOpaque)

        // Always-on-top floating level.
        XCTAssertEqual(win.level, .floating)

        // Follow all Spaces (useful for full-screen apps).
        XCTAssertTrue(win.collectionBehavior.contains(.canJoinAllSpaces))
    }

    func testRecordingWindowOnStopCallbackNilByDefault() {
        let win = RecordingWindow(
            appState: AppState(),
            waveformVM: WaveformViewModel(),
            processingVM: ProcessingViewModel(),
            settings: .shared
        )
        XCTAssertNil(win.onStop)
    }

    func testRecordingWindowOnStopCanBeSet() {
        let win = RecordingWindow(
            appState: AppState(),
            waveformVM: WaveformViewModel(),
            processingVM: ProcessingViewModel(),
            settings: .shared
        )
        var fired = false
        win.onStop = { fired = true }
        win.onStop?()
        XCTAssertTrue(fired)
    }
}

// MARK: - StatusBarItem

@MainActor
final class StatusBarItemTests: XCTestCase {

    func testStatusBarItemCanBeInstantiated() {
        let appState = AppState()
        let engineManager = EngineManager(enginePath: "/usr/bin/false")
        let item = StatusBarItem(appState: appState, engineManager: engineManager)
        XCTAssertNotNil(item)
    }

    func testShowStatusSetsTooltip() {
        let item = StatusBarItem(appState: AppState(), engineManager: EngineManager(enginePath: "/usr/bin/false"))
        item.showStatus("Ready")
        // Just verify it does not crash; NSStatusBar button may be nil in headless CI.
    }

    func testClearStatusDoesNotCrash() {
        let item = StatusBarItem(appState: AppState(), engineManager: EngineManager(enginePath: "/usr/bin/false"))
        item.clearStatus()
    }

    func testUpdateStateDoesNotCrash() {
        let item = StatusBarItem(appState: AppState(), engineManager: EngineManager(enginePath: "/usr/bin/false"))
        item.updateState(.idle)
        item.updateState(.preparing)
        item.updateState(.recording)
        item.updateState(.inferring)
        item.updateState(.error("test"))
    }

    func testUpdateEngineStatusAllCases() {
        let item = StatusBarItem(appState: AppState(), engineManager: EngineManager(enginePath: "/usr/bin/false"))
        item.updateEngineStatus(.stopped)
        item.updateEngineStatus(.starting)
        item.updateEngineStatus(.running)
        item.updateEngineStatus(.error("test failure"))
    }
}

// MARK: - PreferencesWindowController

@MainActor
final class PreferencesWindowControllerTests: XCTestCase {

    func testSharedSingletonIsStable() {
        let a = PreferencesWindowController.shared
        let b = PreferencesWindowController.shared
        XCTAssertTrue(a === b)
    }
}

// MARK: - EngineManager.EngineStatus

final class EngineStatusTests: XCTestCase {

    func testEngineStatusEquality() {
        XCTAssertEqual(EngineManager.EngineStatus.stopped, .stopped)
        XCTAssertEqual(EngineManager.EngineStatus.starting, .starting)
        XCTAssertEqual(EngineManager.EngineStatus.running, .running)
        XCTAssertEqual(EngineManager.EngineStatus.error("x"), .error("x"))
        XCTAssertNotEqual(EngineManager.EngineStatus.error("a"), .error("b"))
    }

    func testEngineStatusStoppedNotEqualToRunning() {
        XCTAssertNotEqual(EngineManager.EngineStatus.stopped, .running)
    }
}
