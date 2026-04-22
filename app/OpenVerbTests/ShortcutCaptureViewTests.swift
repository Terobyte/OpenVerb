import XCTest
import AppKit
@testable import OpenVerb

final class ShortcutCaptureViewTests: XCTestCase {

    // MARK: NSView contract

    func testAcceptsFirstResponder() {
        let view = ShortcutCaptureView()
        XCTAssertTrue(view.acceptsFirstResponder)
    }

    // MARK: recording state

    func testStopRecordingIfActiveWhenNotRecordingIsNoOp() {
        let view = ShortcutCaptureView()
        // isRecording starts false — stopRecordingIfActive must not crash
        view.stopRecordingIfActive()
    }

    func testStopRecordingIfActiveIsIdempotent() {
        let view = ShortcutCaptureView()
        view.stopRecordingIfActive()
        view.stopRecordingIfActive()
    }

    // MARK: onCapture callback

    func testOnCaptureIsNilByDefault() {
        let view = ShortcutCaptureView()
        XCTAssertNil(view.onCapture)
    }

    func testOnCaptureCanBeAssigned() {
        let view = ShortcutCaptureView()
        var capturedCode: UInt16?
        view.onCapture = { code, _ in capturedCode = code }
        view.onCapture?(0x31, .maskAlternate)
        XCTAssertEqual(capturedCode, 0x31)
    }

    // MARK: view geometry

    func testViewCanBeInstantiatedWithFrame() {
        let view = ShortcutCaptureView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        XCTAssertEqual(view.frame.width, 200)
        XCTAssertEqual(view.frame.height, 28)
    }
}
