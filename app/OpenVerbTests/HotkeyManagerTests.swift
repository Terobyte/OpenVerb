import XCTest
@testable import OpenVerb

// HotkeyManager is @MainActor — all test methods must run on MainActor.
@MainActor
final class HotkeyManagerTests: XCTestCase {

    // MARK: instantiation

    func testCanBeInstantiated() {
        let manager = HotkeyManager()
        XCTAssertNotNil(manager)
    }

    // MARK: configure() before register() is a no-op for the event tap

    func testConfigureBeforeRegisterDoesNotInstallTap() {
        let manager = HotkeyManager()
        // configure() only calls register() if eventTap != nil.
        // Since register() hasn't been called, eventTap is nil —
        // configure() must not crash and must accept arbitrary values.
        manager.configure(keyCode: 0x32, modifiers: .maskAlternate)
        // No assertion needed beyond "did not crash"
    }

    func testMultipleConfigureCallsAreStable() {
        let manager = HotkeyManager()
        manager.configure(keyCode: 0x31, modifiers: .maskAlternate)
        manager.configure(keyCode: 0x31, modifiers: .maskControl)
        manager.configure(keyCode: 0x32, modifiers: [.maskAlternate, .maskShift])
    }

    // MARK: unregister() when nothing is registered

    func testUnregisterWithoutRegisterIsSafe() {
        let manager = HotkeyManager()
        manager.unregister()
    }

    func testUnregisterIsIdempotent() {
        let manager = HotkeyManager()
        manager.unregister()
        manager.unregister()
    }

    // MARK: Escape monitor registration

    func testRegisterEscapeMonitorsTwiceIsIdempotent() {
        let manager = HotkeyManager()
        manager.registerEscapeMonitors()
        manager.registerEscapeMonitors()  // second call is guarded by nil check
        manager.removeEscapeMonitors()
    }

    func testRemoveEscapeMonitorsWithoutRegisterIsSafe() {
        let manager = HotkeyManager()
        manager.removeEscapeMonitors()
    }

    // MARK: callback wiring

    func testCallbacksAreNilByDefault() {
        let manager = HotkeyManager()
        XCTAssertNil(manager.onToggleRecording)
        XCTAssertNil(manager.onCancelRecording)
        XCTAssertNil(manager.onAbortAndRestart)
    }

    func testCallbacksCanBeSet() {
        let manager = HotkeyManager()
        var fired = false
        manager.onToggleRecording = { fired = true }
        manager.onToggleRecording?()
        XCTAssertTrue(fired)
    }
}
