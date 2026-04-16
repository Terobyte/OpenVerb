import XCTest
@testable import OpenVerb

final class MockAccessibilityReader: AccessibilityReadable {
    var windowTitle: String?
    var selectedText: String?

    func readWindowTitle(for app: NSRunningApplication) -> String? { windowTitle }
    func readSelectedText(for app: NSRunningApplication) -> String? { selectedText }
}

final class AccessibilityReaderTests: XCTestCase {

    func testWindowTitleReturnsValue() {
        let mock = MockAccessibilityReader()
        mock.windowTitle = "Inbox — Mail"
        XCTAssertEqual(mock.readWindowTitle(for: NSRunningApplication.current), "Inbox — Mail")
    }

    func testSelectedTextReturnsValue() {
        let mock = MockAccessibilityReader()
        mock.selectedText = "Hello world"
        XCTAssertEqual(mock.readSelectedText(for: NSRunningApplication.current), "Hello world")
    }

    func testNilWhenNoAccessibility() {
        let mock = MockAccessibilityReader()
        mock.windowTitle = nil
        mock.selectedText = nil
        XCTAssertNil(mock.readWindowTitle(for: NSRunningApplication.current))
        XCTAssertNil(mock.readSelectedText(for: NSRunningApplication.current))
    }

    func testSelectedTextReturnedRawWithoutTruncation() {
        let mock = MockAccessibilityReader()
        mock.selectedText = String(repeating: "a", count: 15_000)
        XCTAssertEqual(mock.readSelectedText(for: NSRunningApplication.current)?.count, 15_000)
    }
}
