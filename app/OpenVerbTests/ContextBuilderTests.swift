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

    func testClipboardOmittedWhenNil() async {
        let pb = MockPasteboard()
        pb.content = nil
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        XCTAssertNil(ctx["clipboard_style"], "nil clipboard must omit the clipboard_style key entirely")
    }

    func testClipboardOmittedWhenEmpty() async {
        let pb = MockPasteboard()
        pb.content = ""
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        XCTAssertNil(ctx["clipboard_style"], "Empty clipboard must omit the clipboard_style key entirely")
    }

    func testClipboardKeyIsNeverEmittedWithRawText() async {
        let pb = MockPasteboard()
        pb.content = "sensitive clipboard text"
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        // Production code writes "clipboard_style" (a descriptor), never raw text.
        // Verify the descriptor does NOT contain the raw clipboard content.
        let descriptor = ctx["clipboard_style"] ?? ""
        XCTAssertFalse(descriptor.contains("sensitive clipboard text"),
                       "clipboard_style must never contain raw clipboard text")
    }

    func testClipboardStyleEmittedWhenClipboardPresent() async {
        let pb = MockPasteboard()
        pb.content = "Hello"
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        XCTAssertNotNil(ctx["clipboard_style"],
                        "clipboard_style must be emitted when clipboard is present and non-empty")
    }

    func testClipboardStyleOmittedWhenEmpty() async {
        let pb = MockPasteboard()
        pb.content = ""
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        XCTAssertNil(ctx["clipboard_style"],
                     "clipboard_style must be omitted when clipboard is empty")
    }

    func testClipboardStyleOmittedWhenToggleOff() async {
        let pb = MockPasteboard()
        pb.content = "some text"
        let ctx = await ContextBuilder.build(
            targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes"),
            pasteboard: pb,
            includeClipboard: false
        )
        XCTAssertNil(ctx["clipboard_style"],
                     "clipboard_style must be omitted when includeClipboard is false")
    }

    func testClipboardStyleDescriptorForShortText() async {
        let shortText = "Hello, World!"
        let pb = MockPasteboard()
        pb.content = shortText
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        guard let descriptor = ctx["clipboard_style"] else {
            XCTFail("clipboard_style must be present for non-empty clipboard")
            return
        }
        XCTAssertTrue(descriptor.contains("len:\(shortText.utf8.count)"),
                      "Descriptor must contain correct byte length")
        XCTAssertTrue(descriptor.contains("coding:false"),
                      "Short text without code fence must have coding:false")
    }

    func testClipboardStyleDescriptorForLongText() async {
        let longText = String(repeating: "a", count: 15_360)
        let pb = MockPasteboard()
        pb.content = longText
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        guard let descriptor = ctx["clipboard_style"] else {
            XCTFail("clipboard_style must be present for non-empty clipboard")
            return
        }
        XCTAssertTrue(descriptor.contains("len:10240"),
                      "Descriptor byte length must reflect truncation to 10240")
    }

    func testClipboardStyleDetectsCodeFence() async {
        let codeText = "```\nprint(\"hello\")\n```"
        let pb = MockPasteboard()
        pb.content = codeText
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        guard let descriptor = ctx["clipboard_style"] else {
            XCTFail("clipboard_style must be present for non-empty clipboard")
            return
        }
        XCTAssertTrue(descriptor.contains("coding:true"),
                      "Text with code fences must set coding:true")
    }

    func testClipboardStyleDetectsMarkdown() async {
        let markdownText = "# Title\n\n- item 1\n- item 2\n**bold**"
        let pb = MockPasteboard()
        pb.content = markdownText
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        guard let descriptor = ctx["clipboard_style"] else {
            XCTFail("clipboard_style must be present for non-empty clipboard")
            return
        }
        XCTAssertTrue(descriptor.contains("markdown:true"),
                      "Markdown-like text must set markdown:true")
    }

    func testClipboardStyleDetectsURL() async {
        let urlText = "Check out https://example.com for more"
        let pb = MockPasteboard()
        pb.content = urlText
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        guard let descriptor = ctx["clipboard_style"] else {
            XCTFail("clipboard_style must be present for non-empty clipboard")
            return
        }
        XCTAssertTrue(descriptor.contains("url:true"),
                      "Text containing a URL must set url:true")
    }

    func testClipboardStyleDescriptorContainsNoRawText() async {
        let secret = "SUPER_SECRET_CLIPBOARD_CONTENT_12345"
        let pb = MockPasteboard()
        pb.content = secret
        let ctx = await ContextBuilder.build(targetApp: nil, pasteboard: pb)
        let descriptor = ctx["clipboard_style"] ?? ""
        XCTAssertFalse(descriptor.contains(secret),
                       "Descriptor must never contain raw clipboard text")
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
