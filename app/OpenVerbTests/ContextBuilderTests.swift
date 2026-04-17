import XCTest
import AppKit
@testable import OpenVerb

// ---------------------------------------------------------------------------
// ContextBuilderTests — validates context assembly (plan step 12).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Mock conformances for protocol-based dependency injection.
// ---------------------------------------------------------------------------

final class MockAppIdentifiable: AppIdentifiable {
    var bundleIdentifier: String?
    var localizedName: String?

    init(bundleIdentifier: String? = nil, localizedName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }
}

final class MockPasteboard: PasteboardReadable {
    var content: String?
    func string(forType: NSPasteboard.PasteboardType) -> String? { content }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

final class ContextBuilderTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: "app" field assembly
    // -----------------------------------------------------------------------

    func testAppFieldUsesBundleIdentifier() async {
        let app = MockAppIdentifiable(bundleIdentifier: "com.apple.Terminal",
                                      localizedName: "Terminal")
        let ctx = await ContextBuilder.build(targetApp: app, pasteboard: MockPasteboard())
        XCTAssertEqual(ctx["app"], "com.apple.Terminal")
    }

    func testAppFieldFallsBackToLocalizedName() async {
        let app = MockAppIdentifiable(bundleIdentifier: nil, localizedName: "MyApp")
        let ctx = await ContextBuilder.build(targetApp: app, pasteboard: MockPasteboard())
        XCTAssertEqual(ctx["app"], "MyApp")
    }

    func testAppFieldIsUnknownWhenBothNil() async {
        let app = MockAppIdentifiable(bundleIdentifier: nil, localizedName: nil)
        let ctx = await ContextBuilder.build(targetApp: app, pasteboard: MockPasteboard())
        XCTAssertEqual(ctx["app"], "unknown")
    }

    func testAppFieldIsUnknownWhenTargetAppIsNil() async {
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: MockPasteboard())
        XCTAssertEqual(ctx["app"], "unknown")
    }

    func testAppFieldIgnoresEmptyBundleIdentifier() async {
        let app = MockAppIdentifiable(bundleIdentifier: "", localizedName: "Fallback")
        let ctx = await ContextBuilder.build(targetApp: app, pasteboard: MockPasteboard())
        XCTAssertEqual(ctx["app"], "Fallback",
                       "Empty bundleIdentifier must fall through to localizedName")
    }

    // -----------------------------------------------------------------------
    // MARK: "clipboard" field
    // -----------------------------------------------------------------------

    func testClipboardIncludedWhenPresent() async {
        let pb = MockPasteboard()
        pb.content = "Hello, World!"
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        XCTAssertEqual(ctx["clipboard"], "Hello, World!")
    }

    func testClipboardOmittedWhenNil() async {
        let pb = MockPasteboard()
        pb.content = nil
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        XCTAssertNil(ctx["clipboard"], "nil clipboard must omit the key entirely")
    }

    func testClipboardOmittedWhenEmpty() async {
        let pb = MockPasteboard()
        pb.content = ""
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        XCTAssertNil(ctx["clipboard"], "Empty clipboard must omit the key entirely")
    }

    func testClipboardTruncatedTo10240Bytes() async {
        // 15 KB of ASCII (each char = 1 byte) → must be truncated to 10 240 bytes.
        let big = String(repeating: "a", count: 15_360)
        let pb = MockPasteboard()
        pb.content = big
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        let result = ctx["clipboard"] ?? ""
        XCTAssertLessThanOrEqual(result.utf8.count, 10_240,
                                 "Clipboard must not exceed 10 240 UTF-8 bytes")
        XCTAssertEqual(result.utf8.count, 10_240,
                       "ASCII clipboard must be truncated to exactly 10 240 bytes")
    }

    func testClipboardTruncationPreservesCharacterBoundary() async {
        // 4-byte emoji: if the limit falls in the middle of an emoji, the
        // result must not contain partial codepoints.
        let emoji = String(repeating: "😀", count: 3000)  // 3000 × 4 = 12 000 bytes
        let pb = MockPasteboard()
        pb.content = emoji
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        let result = ctx["clipboard"] ?? ""
        XCTAssertLessThanOrEqual(result.utf8.count, 10_240)
        // Result must be valid UTF-8 (no partial multi-byte sequences).
        XCTAssertNotNil(result.data(using: .utf8))
        // Every character must be a complete emoji.
        XCTAssertTrue(result.unicodeScalars.allSatisfy { $0.value == 0x1F600 })
    }

    // -----------------------------------------------------------------------
    // MARK: "language" field
    // -----------------------------------------------------------------------

    func testLanguageFieldDefaultsToCurrentLocale() async {
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: MockPasteboard())
        let lang = ctx["language"]
        XCTAssertNotNil(lang, "language key must always be present")
        let expected = Locale.current.language.languageCode?.identifier ?? "en"
        XCTAssertEqual(lang, expected, "language should default to current locale")
    }

    func testLanguageOverrideUsedWhenProvided() async {
        let ctx = await ContextBuilder.build(
            targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes"),
            languageOverride: "ru"
        )
        XCTAssertEqual(ctx["language"], "ru")
    }

    // -----------------------------------------------------------------------
    // MARK: clipboard toggle
    // -----------------------------------------------------------------------

    func testClipboardOmittedWhenToggleOff() async {
        let pb = MockPasteboard()
        pb.content = "some clipboard text"
        let ctx = await ContextBuilder.build(
            targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes"),
            pasteboard: pb,
            includeClipboard: false
        )
        XCTAssertNil(ctx["clipboard"])
    }

    // -----------------------------------------------------------------------
    // MARK: Accessibility — window + selected text
    // -----------------------------------------------------------------------

    func testWindowTitlePopulatedFromAccessibility() async {
        let mock = MockAccessibilityReader()
        mock.windowTitle = "Inbox — Mail"
        let mockApp = NSRunningApplication.current
        let ctx = await ContextBuilder.build(
            targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.mail", localizedName: "Mail"),
            accessibilityApp: mockApp,
            pasteboard: MockPasteboard(),
            accessibilityReader: mock
        )
        XCTAssertEqual(ctx["window"], "Inbox — Mail")
    }

    func testSelectionPopulatedFromAccessibility() async {
        let mock = MockAccessibilityReader()
        mock.selectedText = "selected words"
        let mockApp = NSRunningApplication.current
        let ctx = await ContextBuilder.build(
            targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes"),
            accessibilityApp: mockApp,
            pasteboard: MockPasteboard(),
            accessibilityReader: mock
        )
        XCTAssertEqual(ctx["selected"], "selected words")
    }

    func testSelectionTruncatedTo10KB() async {
        let mock = MockAccessibilityReader()
        // Pure ASCII (1 byte/char) so utf8.count == character count — equality is exact.
        mock.selectedText = String(repeating: "x", count: 15_000)
        let mockApp = NSRunningApplication.current
        let ctx = await ContextBuilder.build(
            targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes"),
            accessibilityApp: mockApp,
            pasteboard: MockPasteboard(),
            accessibilityReader: mock
        )
        XCTAssertEqual(ctx["selected"]?.utf8.count, 10_240)
    }

    func testWindowEmptyWhenAccessibilityDenied() async {
        let mock = MockAccessibilityReader()
        mock.windowTitle = nil
        mock.selectedText = nil
        let mockApp = NSRunningApplication.current
        let ctx = await ContextBuilder.build(
            targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.Terminal", localizedName: "Terminal"),
            accessibilityApp: mockApp,
            pasteboard: MockPasteboard(),
            accessibilityReader: mock
        )
        XCTAssertEqual(ctx["window"], "")
        XCTAssertNil(ctx["selected"])
    }

    // -----------------------------------------------------------------------
    // MARK: truncateToUTF8Bytes helper
    // -----------------------------------------------------------------------

    func testTruncateHelperNoOpForShortString() {
        let s = "hello"
        XCTAssertEqual(ContextBuilder.truncateToUTF8Bytes(s, limit: 100), s)
    }

    func testTruncateHelperExactLimit() {
        let s = String(repeating: "x", count: 10)
        XCTAssertEqual(ContextBuilder.truncateToUTF8Bytes(s, limit: 10), s)
    }

    func testTruncateHelperCutsASCII() {
        let s = String(repeating: "A", count: 20)
        let result = ContextBuilder.truncateToUTF8Bytes(s, limit: 10)
        XCTAssertEqual(result.utf8.count, 10)
        XCTAssertEqual(result, String(repeating: "A", count: 10))
    }

    func testTruncateHelperDoesNotSplitMultibyteCharacter() {
        // "é" = 2 bytes in UTF-8. With limit=3 we can fit 1 full "é" (2 bytes)
        // but NOT 1.5 "é", so the result should be 1 "é" = 2 bytes.
        let s = "éé"   // 4 bytes total
        let result = ContextBuilder.truncateToUTF8Bytes(s, limit: 3)
        XCTAssertLessThanOrEqual(result.utf8.count, 3)
        XCTAssertEqual(result, "é")   // 2 bytes, not 3 (which would be partial)
    }
}
