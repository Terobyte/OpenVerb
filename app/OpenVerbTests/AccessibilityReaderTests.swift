import XCTest
@testable import OpenVerb

final class MockAccessibilityReader: AccessibilityReadable {
    var windowTitle: String?
    var selectedText: String?
    var cursorSurroundingText: (before: String, after: String) = ("", "")

    func readWindowTitle(for app: NSRunningApplication) -> String? { windowTitle }
    func readSelectedText(for app: NSRunningApplication) -> String? { selectedText }
    func readCursorSurroundingText(for app: NSRunningApplication) -> (before: String, after: String) { cursorSurroundingText }
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

    // Bug 133 fix: exercise the real AccessibilityReader implementation so
    // regressions in the production code are not invisible to the test suite.
    func testRealAccessibilityReaderInstantiatesWithoutCrash() {
        let reader = AccessibilityReader()
        // Calling the real implementation against the current process.
        // Accessibility permission is typically not granted in test context,
        // so we expect nil or empty string — the key invariant is that the
        // real class exists and its methods are callable without crashing.
        let title = reader.readWindowTitle(for: NSRunningApplication.current)
        // nil is valid (no accessibility permission); just verify no crash.
        _ = title
    }
}
