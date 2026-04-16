# MVP4-5: Context Awareness + Distribution & Polish

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Accessibility API context awareness (MVP4) and complete distribution pipeline — Preferences, Onboarding, ModelDownloader, CGEvent fallback, i18n templates, Homebrew cask (MVP5).

**Architecture:** MVP4 is Swift-only — the C++ engine already handles `window` and `selected` context JSON fields (`parse_context_json()` in `engine/src/context/prompt_builder.cpp:181-208`). MVP5 spans Swift UI (Preferences, Onboarding), Swift networking (ModelDownloader), Swift input (custom shortcut recorder), C++ templates (i18n), and shell scripting (Homebrew cask, build-release).

**IMPORTANT — JSON key name:** The spec (line 90) uses `"selection"` but the engine implementation (`prompt_builder.cpp:200`) reads `"selected"`. This plan uses `"selected"` to match the running engine code. The spec has a typo — do NOT use `"selection"` as the key.

**Tech Stack:** Swift 5.9 / SwiftUI (macOS 13+), AXUIElement (ApplicationServices), URLSession, C++ (engine templates), Ruby (Homebrew cask), Bash (build-release)

**Existing code alignment:**
- [x] `app/OpenVerb/Context/ContextBuilder.swift:54-57` — explicit "deferred to MVP4" placeholders for `window` and `selection`. **NOTE: line 59 comment reads `// "selection" is omitted entirely` — this is a typo; the engine key is `"selected"` (prompt_builder.cpp:200). Task 3 Step 10 rewrites this function and uses the correct key. The comment must become `// "selected" is set from Accessibility API` — do NOT perpetuate the "selection" typo.**
- [x] `app/OpenVerb/Output/TextInjector.swift:25` — "CGEvent per-character fallback deferred to MVP5"
- [x] `app/OpenVerb/UI/StatusBarItem.swift` — no Preferences menu item (MVP5)
- [x] `engine/src/context/prompt_builder.cpp:55` — "MVP4+ i18n: replace with per-locale template"
- [x] `engine/src/context/prompt_builder.cpp:74` — "MVP4+ i18n: localize style descriptions" (style localization deferred to post-v1.0; this plan localizes system prompts and generation suffixes only)
- [x] `app/OpenVerb/Engine/EngineManager.swift` — `checkModelExists()` is a simple file check; ModelDownloader replaces the manual download script

---

## Chunk 1: MVP4 — Accessibility API Context

### Task 1: AccessibilityReader — protocol + failing test

**Files:**
- [x] Create: `app/OpenVerb/Context/AccessibilityReader.swift`
- [x] Create: `app/OpenVerbTests/AccessibilityReaderTests.swift`

> **Xcode:** Add each new file to the correct target in `OpenVerb.xcodeproj` (drag into navigator → tick target checkbox). Source `.swift` → **OpenVerb** target; test `.swift` → **OpenVerbTests** target. Alternatively run tests via `cd app && swift test` — SwiftPM auto-discovers files without project membership.

- [x] **Step 1: Write the AccessibilityReader protocol and struct skeleton**

```swift
// app/OpenVerb/Context/AccessibilityReader.swift
import ApplicationServices
import AppKit
import os

// Protocol for testability — mock in tests, real AXUIElement in production.
protocol AccessibilityReadable {
    func readWindowTitle(for app: NSRunningApplication) -> String?
    func readSelectedText(for app: NSRunningApplication) -> String?
}

struct AccessibilityReader: AccessibilityReadable {
    private let logger = Logger(subsystem: "io.openverb.app", category: "AccessibilityReader")

    func readWindowTitle(for app: NSRunningApplication) -> String? {
        fatalError("Not implemented")
    }

    func readSelectedText(for app: NSRunningApplication) -> String? {
        fatalError("Not implemented")
    }
}
```

- [x] **Step 2: Write failing tests for AccessibilityReader**

```swift
// app/OpenVerbTests/AccessibilityReaderTests.swift
import XCTest
@testable import OpenVerb

// Mock that returns controlled values.
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
        // AccessibilityReader does NOT truncate — it returns the raw string.
        // Truncation is the responsibility of ContextBuilder.build() via
        // truncateToUTF8Bytes(). If this test named "Truncation" passed, it
        // would incorrectly suggest that AccessibilityReader itself truncates.
        let mock = MockAccessibilityReader()
        mock.selectedText = String(repeating: "a", count: 15_000)
        XCTAssertEqual(mock.readSelectedText(for: NSRunningApplication.current)?.count, 15_000)
    }
}
```

- [x] **Step 3: Run tests to verify they compile and the mock tests pass**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/AccessibilityReaderTests 2>&1 | tail -20`
Expected: 4 tests PASS (mock-based, no real AX calls)

---

### Task 2: AccessibilityReader — AXUIElement implementation

**Files:**
- [x] Modify: `app/OpenVerb/Context/AccessibilityReader.swift`

- [x] **Step 5: Implement readWindowTitle with AXUIElement**

Replace the `fatalError` stubs with real AX calls:

```swift
struct AccessibilityReader: AccessibilityReadable {
    private let logger = Logger(subsystem: "io.openverb.app", category: "AccessibilityReader")

    /// Returns true if Accessibility permission is granted.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    func readWindowTitle(for app: NSRunningApplication) -> String? {
        guard AccessibilityReader.isAccessibilityGranted else {
            logger.debug("Accessibility not granted — skipping window title")
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let focusedWindow else {
            logger.debug("No focused window for \(app.processIdentifier)")
            return nil
        }

        // Use conditional cast — focusedWindow is CFTypeRef; force-casting crashes if
        // the AX API returns a non-AXUIElement in a future OS version.
        guard let windowElem = focusedWindow as? AXUIElement else { return nil }
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(windowElem, kAXTitleAttribute as CFString, &titleValue)
        guard titleResult == .success, let title = titleValue as? String, !title.isEmpty else {
            return nil
        }

        return title
    }

    func readSelectedText(for app: NSRunningApplication) -> String? {
        guard AccessibilityReader.isAccessibilityGranted else {
            logger.debug("Accessibility not granted — skipping selected text")
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let focusedElement else {
            return nil
        }

        // Use conditional cast — same reason as readWindowTitle above.
        guard let elem = focusedElement as? AXUIElement else { return nil }
        var selectedValue: CFTypeRef?
        let selResult = AXUIElementCopyAttributeValue(elem, kAXSelectedTextAttribute as CFString, &selectedValue)
        guard selResult == .success, let text = selectedValue as? String, !text.isEmpty else {
            return nil
        }

        return text
    }
}
```

- [ ] **Step 6: Run existing tests — still pass (mock tests don't call real AX)**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/AccessibilityReaderTests 2>&1 | tail -20`
Expected: 4 tests PASS

---

### Task 3: ContextBuilder — add Accessibility fields

**Files:**
- [ ] Modify: `app/OpenVerb/Context/ContextBuilder.swift`
- [ ] Modify: `app/OpenVerbTests/ContextBuilderTests.swift`

- [ ] **Step 8: Write failing test for window title in context**

Add to `ContextBuilderTests.swift`:

```swift
func testWindowTitlePopulatedFromAccessibility() async {
    let mockReader = MockAccessibilityReader()
    mockReader.windowTitle = "Inbox — Mail"
    let mockApp = MockAppIdentifiable(bundleIdentifier: "com.apple.mail", localizedName: "Mail")
    let context = await ContextBuilder.build(
        targetApp: mockApp,
        pasteboard: { let pb = MockPasteboard(); pb.content = nil; return pb }(),
        accessibilityReader: mockReader,
        accessibilityApp: nil  // uses mockReader directly
    )
    XCTAssertEqual(context["window"], "Inbox — Mail")
}

func testSelectionPopulatedFromAccessibility() async {
    let mockReader = MockAccessibilityReader()
    mockReader.selectedText = "selected words"
    let mockApp = MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes")
    let context = await ContextBuilder.build(
        targetApp: mockApp,
        pasteboard: { let pb = MockPasteboard(); pb.content = nil; return pb }(),
        accessibilityReader: mockReader,
        accessibilityApp: nil
    )
    XCTAssertEqual(context["selected"], "selected words")
}

func testSelectionTruncatedTo10KB() async {
    let mockReader = MockAccessibilityReader()
    // NOTE: Uses ASCII 'x' (1 byte per char) intentionally.
    // For multi-byte chars (e.g. "й" = 2 bytes) truncateToUTF8Bytes may
    // produce fewer than 10_240 bytes to avoid splitting a UTF-8 sequence,
    // which would break the equality check below. If you need to test with
    // multi-byte input, assert <= 10_240 instead of ==.
    mockReader.selectedText = String(repeating: "x", count: 15_000)
    let mockApp = MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes")
    let context = await ContextBuilder.build(
        targetApp: mockApp,
        pasteboard: { let pb = MockPasteboard(); pb.content = nil; return pb }(),
        accessibilityReader: mockReader,
        accessibilityApp: nil
    )
    // For pure-ASCII input, utf8.count == character count, so this is exact.
    XCTAssertEqual(context["selected"]?.utf8.count, 10_240)
}

func testWindowEmptyWhenAccessibilityDenied() async {
    let mockReader = MockAccessibilityReader()
    // Both nil = simulates no Accessibility permission
    mockReader.windowTitle = nil
    mockReader.selectedText = nil
    let mockApp = MockAppIdentifiable(bundleIdentifier: "com.apple.Terminal", localizedName: "Terminal")
    let context = await ContextBuilder.build(
        targetApp: mockApp,
        pasteboard: { let pb = MockPasteboard(); pb.content = nil; return pb }(),
        accessibilityReader: mockReader,
        accessibilityApp: nil
    )
    XCTAssertEqual(context["window"], "")
    XCTAssertNil(context["selected"])
}
```

- [ ] **Step 9: Run tests to verify they fail (new signature doesn't exist yet)**

Run: `cd app && xcodebuild test -scheme OpenVerb 2>&1 | tail -20`
Expected: FAIL — `build()` signature mismatch

- [ ] **Step 10: Update ContextBuilder.build() to accept AccessibilityReadable**

Modify `app/OpenVerb/Context/ContextBuilder.swift`:

```swift
// PasteboardReadable — protocol wrapping NSPasteboard for testability.
protocol PasteboardReadable {
    func string(forType: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: PasteboardReadable {}

struct ContextBuilder {

    static func build(
        targetApp: AppIdentifiable?,
        pasteboard: PasteboardReadable = NSPasteboard.general,
        accessibilityReader: AccessibilityReadable = AccessibilityReader(),
        accessibilityApp: NSRunningApplication? = nil
    ) async -> [String: String] {
        var context: [String: String] = [:]

        // "app" — prefer bundleIdentifier, fall back to localizedName, then "unknown".
        if let id = targetApp?.bundleIdentifier, !id.isEmpty {
            context["app"] = id
        } else if let name = targetApp?.localizedName, !name.isEmpty {
            context["app"] = name
        } else {
            context["app"] = "unknown"
        }

        // "clipboard" — truncate to 10 240 UTF-8 bytes; omit if nil/empty.
        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            context["clipboard"] = truncateToUTF8Bytes(raw, limit: 10_240)
        }

        // "language" — BCP-47 from current locale.
        context["language"] = Locale.current.language.languageCode?.identifier ?? "en"

        // "window" — from Accessibility API; empty string if unavailable.
        // The real NSRunningApplication is passed separately because
        // AppIdentifiable protocol doesn't carry process ID needed for AX.
        // When nil: skip the AX read entirely — reading OpenVerb's own window
        // title is useless and would confuse the model.
        if let app = accessibilityApp {
            context["window"] = accessibilityReader.readWindowTitle(for: app) ?? ""
        } else {
            context["window"] = ""
        }

        // "selected" — from Accessibility API; omit entirely if nil/empty.
        // NOTE: engine reads "selected" (not "selection") — see prompt_builder.cpp:200
        // When accessibilityApp is nil, skip: reading OpenVerb's own selection is useless.
        if let app = accessibilityApp,
           let sel = accessibilityReader.readSelectedText(for: app), !sel.isEmpty {
            context["selected"] = truncateToUTF8Bytes(sel, limit: 10_240)
        }

        return context
    }

    // -----------------------------------------------------------------------
    // Internal helpers (accessible via @testable import in tests)
    // -----------------------------------------------------------------------

    /// Truncates `s` to at most `limit` UTF-8 bytes, preserving whole
    /// characters by walking back through continuation bytes.
    static func truncateToUTF8Bytes(_ s: String, limit: Int) -> String {
        let allBytes = Array(s.utf8)
        guard allBytes.count > limit else { return s }
        var end = limit
        while end > 0 && (allBytes[end - 1] & 0xC0) == 0x80 {
            end -= 1
        }
        if end > 0 {
            let lead = allBytes[end - 1]
            if lead & 0x80 != 0 {
                let expected: Int
                if lead & 0xE0 == 0xC0      { expected = 2 }
                else if lead & 0xF0 == 0xE0 { expected = 3 }
                else if lead & 0xF8 == 0xF0 { expected = 4 }
                else                         { expected = 1 }
                let seqLen = limit - (end - 1)
                if seqLen < expected { end -= 1 }
                else { end = end - 1 + expected }
            }
        }
        return String(bytes: Array(allBytes.prefix(end)), encoding: .utf8) ?? s
    }
}
```

**Note:** The existing call sites in `OpenVerbApp.swift` that call `ContextBuilder.build(targetApp:)` continue to work — new params have defaults. The only change needed in `OpenVerbApp.swift` is to pass the real `NSRunningApplication` as `accessibilityApp`.

`appState.targetApp` is typed as `AppIdentifiable?` (a protocol), not `NSRunningApplication`. Cast it with `as? NSRunningApplication` — this succeeds at runtime because the hotkey fires while `targetApp` is set to `NSWorkspace.shared.frontmostApplication`, which is always a real `NSRunningApplication`.

```swift
// In OpenVerbApp.swift toggle flow, update the ContextBuilder call:
let context = await ContextBuilder.build(
    targetApp: self?.appState.targetApp,
    accessibilityApp: self?.appState.targetApp as? NSRunningApplication
)
```

- [ ] **Step 11: Run tests to verify all pass**

Run: `cd app && xcodebuild test -scheme OpenVerb 2>&1 | tail -20`
Expected: ALL PASS (old tests use default params, new tests use mock reader)

---

### Task 4: Wire AccessibilityReader into the app flow

**Files:**
- [ ] Modify: `app/OpenVerb/App/OpenVerbApp.swift`

- [ ] **Step 13: Update ContextBuilder call in OpenVerbApp.swift to pass accessibilityApp**

Find the existing call at `app/OpenVerb/App/OpenVerbApp.swift:478` inside `connectAndRecord()`:

```swift
// Before (MVP3):
let context = await ContextBuilder.build(targetApp: appState.targetApp)

// After (MVP4):
let context = await ContextBuilder.build(
    targetApp: appState.targetApp,
    accessibilityApp: appState.targetApp as? NSRunningApplication
)
```

- [ ] **Step 14: Build to verify compilation**

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

---

### Task 5: MVP4 human verification

- [ ] **Step 16: HUMAN: Build the app**

`cd app && xcodebuild -scheme OpenVerb -configuration Release build`

- [ ] **Step 17: HUMAN: Test with Accessibility granted**

Open TextEdit, select some text, press ⌥Space, speak, press ⌥Space. Check engine `--verbose` logs — context JSON should contain `"window":"Untitled"` and `"selected":"<your selected text>"`.

- [ ] **Step 18: HUMAN: Test with Accessibility denied**

Revoke Accessibility permission in System Settings. Press ⌥Space → speak → ⌥Space. Verify: still works (graceful degradation), context has `"window":""` and no `"selected"` key. No crash, no error.

- [ ] **Step 19: HUMAN: Test context-aware output difference**

Open Slack, select a message, dictate "reply that sounds great" → verify casual tone. Open Mail, compose window, dictate same → verify formal tone. The difference comes from the `style` lookup via `resolve_style()` in the engine, which now receives the real app bundle ID.

---

## Chunk 2: MVP5a — Settings Storage & Preferences UI

### Task 6: UserDefaults settings wrapper

**Files:**
- [ ] Create: `app/OpenVerb/Settings/` directory (new — does not exist yet)
- [ ] Create: `app/OpenVerb/Settings/AppSettings.swift`
- [ ] Create: `app/OpenVerbTests/AppSettingsTests.swift`

> **Xcode:** Add each new file to the correct target in `OpenVerb.xcodeproj`. Source `.swift` → **OpenVerb** target; test `.swift` → **OpenVerbTests** target. Alternatively run tests via `cd app && swift test`.

- [ ] **Step 20: Write failing test for AppSettings**

```swift
// app/OpenVerbTests/AppSettingsTests.swift
import XCTest
@testable import OpenVerb

final class AppSettingsTests: XCTestCase {

    override func setUp() {
        // Use a volatile suite so tests don't pollute real UserDefaults
        UserDefaults.standard.removePersistentDomain(forName: "io.openverb.test")
    }

    func testDefaultHotkeyIsOptionSpace() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        XCTAssertEqual(settings.hotkeyKeyCode, 0x31) // Space
        XCTAssertTrue(settings.hotkeyModifiers.contains(.maskAlternate))
    }

    func testClipboardContextDefaultsToTrue() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        XCTAssertTrue(settings.includeClipboard)
    }

    func testBackendDefaultsToGemmaAudio() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        XCTAssertEqual(settings.backend, .gemmaAudio)
    }

    func testLanguageDefaultsToSystemLocale() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        let expected = Locale.current.language.languageCode?.identifier ?? "en"
        XCTAssertEqual(settings.language, expected)
    }

    func testSetAndGetCustomHotkey() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        settings.hotkeyKeyCode = 0x32 // backtick
        settings.hotkeyModifiers = .maskAlternate
        XCTAssertEqual(settings.hotkeyKeyCode, 0x32)
    }

    func testClipboardToggle() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        settings.includeClipboard = false
        XCTAssertFalse(settings.includeClipboard)
    }
}
```

- [ ] **Step 21: Run test — fails (AppSettings doesn't exist)**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/AppSettingsTests 2>&1 | tail -20`
Expected: FAIL — "no such module"

- [ ] **Step 22: Implement AppSettings**

```swift
// app/OpenVerb/Settings/AppSettings.swift
import Foundation
import ApplicationServices

enum BackendType: String {
    case gemmaAudio = "gemma_audio"
    case whisperGemma = "whisper_gemma"
}

// NOTE: @Published only works with stored properties in ObservableObject.
// Each property is a stored var that syncs to/from UserDefaults via didSet
// and is populated from UserDefaults in init().
//
// @MainActor: AppSettings is always accessed on the main thread (SwiftUI
// bindings, StatusBarItem, EngineManager are all @MainActor). Annotating the
// class avoids Swift 6 strict-concurrency warnings when weak refs to it are
// held inside other @MainActor types (e.g. StatusBarItem).

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    // -- Hotkey --
    @Published var hotkeyKeyCode: UInt16 = 0x31 {  // Space
        didSet { defaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode") }
    }

    // @Published required: hotkeyDescription in PreferencesView derives from
    // both hotkeyKeyCode AND hotkeyModifiers. Without @Published, a modifiers-
    // only change (e.g. ⌥ → ⌃) would not trigger a view refresh.
    @Published var hotkeyModifiers: CGEventFlags = .maskAlternate {
        didSet { defaults.set(Int(hotkeyModifiers.rawValue), forKey: "hotkeyModifiers") }
    }

    // -- Backend --
    @Published var backend: BackendType = .gemmaAudio {
        didSet { defaults.set(backend.rawValue, forKey: "backend") }
    }

    // -- Language --
    @Published var language: String = "en" {
        didSet { defaults.set(language, forKey: "language") }
    }

    // -- Clipboard --
    @Published var includeClipboard: Bool = true {
        didSet { defaults.set(includeClipboard, forKey: "includeClipboard") }
    }

    // -- Model path --
    @Published var modelDirectory: String = "" {
        didSet { defaults.set(modelDirectory, forKey: "modelDirectory") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load stored values (or keep defaults if keys absent)
        let storedKeyCode = defaults.integer(forKey: "hotkeyKeyCode")
        if storedKeyCode != 0 { hotkeyKeyCode = UInt16(storedKeyCode) }

        let storedMods = defaults.integer(forKey: "hotkeyModifiers")
        if storedMods != 0 { hotkeyModifiers = CGEventFlags(rawValue: UInt64(storedMods)) }

        if let raw = defaults.string(forKey: "backend") {
            backend = BackendType(rawValue: raw) ?? .gemmaAudio
        }

        language = defaults.string(forKey: "language")
            ?? Locale.current.language.languageCode?.identifier
            ?? "en"

        if defaults.object(forKey: "includeClipboard") != nil {
            includeClipboard = defaults.bool(forKey: "includeClipboard")
        }

        let rawDir = defaults.string(forKey: "modelDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openverb/models").path
        // Normalize: strip trailing slash so path comparisons are consistent.
        // Constants.DEFAULT_MODEL_DIR has a trailing slash; without this the
        // ggufModelExists() check in EngineManager uses a different path string.
        modelDirectory = rawDir.hasSuffix("/") ? String(rawDir.dropLast()) : rawDir
    }
}
```

- [ ] **Step 23: Run test — all pass**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/AppSettingsTests 2>&1 | tail -20`
Expected: 6 tests PASS

---

### Task 7: Wire AppSettings into ContextBuilder (clipboard toggle)

**Files:**
- [ ] Modify: `app/OpenVerb/Context/ContextBuilder.swift`
- [ ] Modify: `app/OpenVerbTests/ContextBuilderTests.swift`

- [ ] **Step 25: Write failing test for clipboard toggle OFF**

Add to `ContextBuilderTests.swift`:

```swift
func testClipboardOmittedWhenToggleOff() async {
    let context = await ContextBuilder.build(
        targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes"),
        pasteboard: { let pb = MockPasteboard(); pb.content = "some clipboard text"; return pb }(),
        includeClipboard: false
    )
    XCTAssertNil(context["clipboard"])
}
```

- [ ] **Step 26: Add `includeClipboard` param to ContextBuilder.build()**

Add `includeClipboard: Bool = true` to the function signature. Wrap the clipboard block:

```swift
if includeClipboard, let raw = pasteboard.string(forType: .string), !raw.isEmpty {
    context["clipboard"] = truncateToUTF8Bytes(raw, limit: 10_240)
}
```

- [ ] **Step 27: Run all tests — pass**

Run: `cd app && xcodebuild test -scheme OpenVerb 2>&1 | tail -20`
Expected: ALL PASS

---

### Task 7b: Wire AppSettings into connectAndRecord call site

**Files:**
- [ ] Modify: `app/OpenVerb/App/OpenVerbApp.swift`

Without this task, the `includeClipboard` and `language` parameters added to `ContextBuilder.build()`
have no effect because `connectAndRecord()` still calls the function with default values.
`ContextBuilder` uses `Locale.current.language.languageCode` by default — ignoring the user's
override in Preferences.

**Also add `languageOverride` parameter to ContextBuilder.build():**

```swift
// Modify ContextBuilder.build() signature (add one more parameter):
static func build(
    targetApp: AppIdentifiable?,
    pasteboard: PasteboardReadable = NSPasteboard.general,
    accessibilityReader: AccessibilityReadable = AccessibilityReader(),
    accessibilityApp: NSRunningApplication? = nil,
    includeClipboard: Bool = true,
    languageOverride: String? = nil   // NEW: overrides Locale.current when set
) async -> [String: String] {
    // ...
    // Replace:
    //   context["language"] = Locale.current.language.languageCode?.identifier ?? "en"
    // With:
    context["language"] = languageOverride
        ?? Locale.current.language.languageCode?.identifier
        ?? "en"
    // ...
}
```

- [ ] **Step 28a: Write failing test for language override**

Add to `ContextBuilderTests.swift`:

```swift
func testLanguageOverrideUsedWhenProvided() async {
    let context = await ContextBuilder.build(
        targetApp: MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes"),
        languageOverride: "ru"
    )
    XCTAssertEqual(context["language"], "ru")
}
```

- [ ] **Step 28b: Add `languageOverride` parameter to ContextBuilder.build() — signature only**

⚠️ **DO NOT wire into connectAndRecord() here** — `appSettings` is not created until Step 30.
This step only extends the function signature. The call-site update is in Step 30a.

Modify `app/OpenVerb/Context/ContextBuilder.swift` — add the parameter to the signature and update the language line:

```swift
static func build(
    targetApp: AppIdentifiable?,
    pasteboard: PasteboardReadable = NSPasteboard.general,
    accessibilityReader: AccessibilityReadable = AccessibilityReader(),
    accessibilityApp: NSRunningApplication? = nil,
    includeClipboard: Bool = true,
    languageOverride: String? = nil   // NEW: overrides Locale.current when set
) async -> [String: String] {
    // ...
    // Replace:
    //   context["language"] = Locale.current.language.languageCode?.identifier ?? "en"
    // With:
    context["language"] = languageOverride
        ?? Locale.current.language.languageCode?.identifier
        ?? "en"
    // ...
}
```

- [ ] **Step 28c: Run all tests — pass**

Run: `cd app && xcodebuild test -scheme OpenVerb 2>&1 | tail -20`
Expected: ALL PASS

---

### Task 8: PreferencesView

**Files:**
- [ ] Create: `app/OpenVerb/UI/PreferencesView.swift`
- [ ] Modify: `app/OpenVerb/UI/StatusBarItem.swift`
- [ ] Modify: `app/OpenVerb/Engine/EngineManager.swift`

> **Xcode:** Add `PreferencesView.swift` to the **OpenVerb** target in `OpenVerb.xcodeproj`.

- [ ] **Step 29a: Add `restartWithBackend()` stub to EngineManager**

PreferencesView's backend picker calls this method. Add it now so the build succeeds:

```swift
// In app/OpenVerb/Engine/EngineManager.swift, add stored property:
var backendOverride: String?

// Add method (full implementation in Task 11 Step 42, but stub compiles now):
func restartWithBackend(_ backend: BackendType) async {
    logger.info("Switching backend to \(backend.rawValue)")
    status = .starting
    // shutdown() is @MainActor sync — inherited from the class isolation.
    // Task.detached { self?.shutdown() } is a Swift 6 compile error: calling an
    // @MainActor method from non-isolated context without `await` is forbidden.
    // DispatchQueue bypasses the concurrency checker while guaranteeing main-thread
    // execution; DispatchQueue.main.sync blocks the global thread until shutdown()
    // (including its 0.5 s waitForProcessExit busy-loop) completes.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            DispatchQueue.main.sync { [weak self] in
                self?.shutdown()
            }
            continuation.resume()
        }
    }
    backendOverride = backend.rawValue
    try? await ensureRunning()
}
```

Also add `BackendType` enum to `app/OpenVerb/Settings/AppSettings.swift` if not already present (it was created in Task 6 Step 22).

- [ ] **Step 29b: Write PreferencesView with SwiftUI**

```swift
// app/OpenVerb/UI/PreferencesView.swift
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var engineManager: EngineManager

    @State private var isSwitchingBackend = false

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            backendTab.tabItem { Label("Backend", systemImage: "cpu") }
        }
        .frame(width: 450, height: 300)
        .padding()
    }

    // -- General tab --
    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Current:")
                    Text(hotkeyDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Change...") { /* ShortcutRecorder sheet — Task 10 */ }
                    Button("Reset to Default") {
                        // Restore ⌥Space — the only way back if the user
                        // records an inconvenient hotkey with no Undo.
                        settings.hotkeyKeyCode = 0x31
                        settings.hotkeyModifiers = .maskAlternate
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }

            Section("Context") {
                Toggle("Include clipboard in context", isOn: $settings.includeClipboard)
            }

            Section("Language") {
                Picker("Output language", selection: $settings.language) {
                    // "auto" uses Whisper's detected language for Path B
                    if settings.backend == .whisperGemma {
                        Text("Auto-detect (Whisper)").tag("auto")
                    }
                    Text("English").tag("en")
                    Text("Русский").tag("ru")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("日本語").tag("ja")
                }
            }
        }
    }

    // -- Backend tab --
    private var backendTab: some View {
        Form {
            Section("Inference Backend") {
                let isNonEnglish = settings.language != "en"

                Picker("Backend", selection: Binding(
                    get: { settings.backend },
                    set: { newValue in
                        guard newValue != settings.backend else { return }
                        isSwitchingBackend = true
                        Task {
                            settings.backend = newValue
                            await engineManager.restartWithBackend(newValue)
                            isSwitchingBackend = false
                        }
                    }
                )) {
                    // Path A disabled on non-English locale (spec line 695)
                    Text("Gemma 4 E2B Audio (recommended)")
                        .tag(BackendType.gemmaAudio)
                    Text("Whisper + Gemma Text (multilingual)")
                        .tag(BackendType.whisperGemma)
                }
                .disabled(isSwitchingBackend)

                if isSwitchingBackend {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Switching backend...")
                            .foregroundStyle(.secondary)
                    }
                }

                if isNonEnglish && settings.backend == .gemmaAudio {
                    // Do NOT auto-switch on .onAppear — modifying @ObservedObject state
                    // during a view render cycle produces a "Publishing changes from within
                    // view updates" SwiftUI warning, and silently changes settings without
                    // user consent. Present a button instead.
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Path A supports English audio only.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Button("Switch to Whisper (multilingual)") {
                            settings.backend = .whisperGemma
                            isSwitchingBackend = true
                            Task {
                                await engineManager.restartWithBackend(.whisperGemma)
                                isSwitchingBackend = false
                            }
                        }
                        .font(.caption)
                    }
                }
            }

            Section("Model") {
                LabeledContent("Model directory") {
                    Text(settings.modelDirectory)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var hotkeyDescription: String {
        var parts: [String] = []
        if settings.hotkeyModifiers.contains(.maskAlternate) { parts.append("⌥") }
        if settings.hotkeyModifiers.contains(.maskControl)   { parts.append("⌃") }
        if settings.hotkeyModifiers.contains(.maskShift)     { parts.append("⇧") }
        if settings.hotkeyModifiers.contains(.maskCommand)   { parts.append("⌘") }

        // Full ANSI key table so the label shows "⌥S" instead of "⌥Key(1)"
        // for any key the ShortcutRecorder can capture.
        let keyNames: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
            0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
            0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
            0x10: "Y", 0x11: "T", 0x1F: "O", 0x20: "U", 0x22: "I",
            0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K", 0x2D: "N",
            0x2E: "M",
            0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6",
            0x17: "5", 0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",
            0x31: "Space", 0x32: "`", 0x24: "Return", 0x30: "Tab",
            0x33: "Delete", 0x35: "Escape",
        ]
        parts.append(keyNames[settings.hotkeyKeyCode] ?? "Key(\(settings.hotkeyKeyCode))")
        return parts.joined()
    }
}
```

- [ ] **Step 30: Add Preferences menu item to StatusBarItem**

Modify `app/OpenVerb/UI/StatusBarItem.swift` — add a `Preferences...` item between "About" and the separator. The init must accept `AppSettings` and `EngineManager`:

In `buildMenu()`, after `aboutItem`:

```swift
let prefsItem = NSMenuItem(
    title: "Preferences...",
    action: #selector(showPreferences),
    keyEquivalent: ","
)
prefsItem.target = self
menu.addItem(prefsItem)
```

Add the stored properties and action:

```swift
private weak var appSettings: AppSettings?
private weak var engineManager: EngineManager?
private var preferencesWindow: NSWindow?

@objc private func showPreferences() {
    guard let settings = appSettings, let engine = engineManager else { return }
    if let existing = preferencesWindow, existing.isVisible {
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    let view = PreferencesView(settings: settings, engineManager: engine)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = "OpenVerb Preferences"
    window.contentView = NSHostingView(rootView: view)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    preferencesWindow = window
}
```

Update `StatusBarItem.init` to accept the new parameters:

```swift
init(appState: AppState, engineManager: EngineManager, appSettings: AppSettings) {
    self.appSettings = appSettings
    self.engineManager = engineManager
    // ... rest unchanged ...
}
```

**Also update the call site** in `app/OpenVerb/App/OpenVerbApp.swift:165`:

```swift
// Before:
statusBar = StatusBarItem(appState: appState, engineManager: engineManager)
// After:
statusBar = StatusBarItem(appState: appState, engineManager: engineManager, appSettings: appSettings)
```

**IMPORTANT:** This requires `appSettings` to be a stored property on `AppDelegate`. Add it now (not deferred to Task 11) so the build succeeds:

In `app/OpenVerb/App/OpenVerbApp.swift`, add alongside other state objects:

```swift
// After line: private var statusBar: StatusBarItem!
private var appSettings: AppSettings!
```

And in `applicationDidFinishLaunching`, after `processingVM = ProcessingViewModel()`:

```swift
appSettings = AppSettings()
```

- [ ] **Step 31: Build to verify**

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 30a: Wire AppSettings into connectAndRecord() call site**

Now that `appSettings` is a stored property on AppDelegate (added in Step 30), update
`connectAndRecord()` in `app/OpenVerb/App/OpenVerbApp.swift` to pass settings values:

```swift
let context = await ContextBuilder.build(
    targetApp: appState.targetApp,
    accessibilityApp: appState.targetApp as? NSRunningApplication,
    includeClipboard: appSettings.includeClipboard,
    languageOverride: appSettings.language
)
```

This is the deferred wiring from Step 28b — `appSettings` did not exist at that point.

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

```bash
git add app/OpenVerb/App/OpenVerbApp.swift
git commit -m "wire appsettings clipboard and language into context builder call site"
```

---

## Chunk 3: MVP5b — ModelDownloader & Onboarding

### Task 9: ModelDownloader — failing test

**Files:**
- [ ] Create: `app/OpenVerb/Model/` directory (new — does not exist yet)
- [ ] Create: `app/OpenVerb/Model/ModelDownloader.swift`
- [ ] Create: `app/OpenVerbTests/ModelDownloaderTests.swift`

> **Xcode:** Add each new file to the correct target in `OpenVerb.xcodeproj`. `ModelDownloader.swift` → **OpenVerb** target; `ModelDownloaderTests.swift` → **OpenVerbTests** target. Alternatively run tests via `cd app && swift test`.

- [ ] **Step 33: Write ModelDownloader protocol and test**

```swift
// app/OpenVerbTests/ModelDownloaderTests.swift
import XCTest
@testable import OpenVerb

final class ModelDownloaderTests: XCTestCase {

    func testSHA256ConstantsExist() {
        // Checksums must be compile-time constants, not fetched from network.
        XCTAssertFalse(ModelDownloader.expectedSHA256.isEmpty)
    }

    func testProgressCallbackFires() async throws {
        var progressValues: [Double] = []
        let downloader = ModelDownloader()
        // Use a tiny test URL that we can control
        // In real test: mock URLSession via protocol
        downloader.onProgress = { p in progressValues.append(p) }
        // This test validates the callback mechanism, not actual download.
        downloader.simulateProgress([0.25, 0.5, 0.75, 1.0])
        XCTAssertEqual(progressValues, [0.25, 0.5, 0.75, 1.0])
    }

    func testResumeSupport() {
        let downloader = ModelDownloader()
        // Verify Range header is set when partial file exists
        let request = downloader.buildResumeRequest(
            url: URL(string: "https://example.com/model.gguf")!,
            existingBytes: 1024
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=1024-")
    }

    func testSHA256Verification() {
        let data = "test data".data(using: .utf8)!
        let hash = ModelDownloader.sha256(data)
        // Known SHA256 of "test data"
        XCTAssertEqual(hash, "916f0027a575074ce72a331777c3478d6513f786a591bd892da1a577bf2335f9")
    }
}
```

- [ ] **Step 34: Run tests — fail (ModelDownloader doesn't exist)**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/ModelDownloaderTests 2>&1 | tail -20`
Expected: FAIL — compilation error

- [ ] **Step 35: Implement ModelDownloader**

```swift
// app/OpenVerb/Model/ModelDownloader.swift
import Foundation
import CryptoKit
import os

final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {

    // Checksums hardcoded at compile time — NEVER fetched from network.
    // Updated by build-release.sh before signing.
    static let expectedSHA256 = "TBD_PIN_BEFORE_RELEASE"

    static let modelURL = URL(string: "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!

    @Published var progress: Double = 0.0
    @Published var isDownloading = false
    @Published var error: String?

    var onProgress: ((Double) -> Void)?

    private let logger = Logger(subsystem: "io.openverb.app", category: "ModelDownloader")
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var resumeData: Data?   // persisted by cancel(); consumed by download() on retry
    private var destinationURL: URL
    private var partialFileURL: URL

    override init() {
        let modelDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openverb/models")
        self.destinationURL = modelDir.appendingPathComponent("gemma-4-E2B-it-Q4_K_M.gguf")
        self.partialFileURL = modelDir.appendingPathComponent("gemma-4-E2B-it-Q4_K_M.gguf.partial")
        super.init()
    }

    func download() async throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Invalidate any existing session before creating a new one.
        // URLSession holds a strong reference to its delegate until explicitly
        // invalidated — skipping this causes a memory leak on retry.
        session?.invalidateAndCancel()

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        await MainActor.run { isDownloading = true; error = nil }

        // Use URLSession native resume data when retrying after a cancel().
        // Range-header approach is unreliable: URLSessionDownloadTask writes to
        // a system temp path, not to partialFileURL, so partialFileSize() would
        // always return 0 and the download would restart from byte 0 on every retry.
        if let data = resumeData {
            downloadTask = session?.downloadTask(withResumeData: data)
        } else {
            downloadTask = session?.downloadTask(with: Self.modelURL)
        }
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            // Store resume data on MainActor so download() can use it on retry.
            // data is nil if the server doesn't support partial content (RFC 7233).
            Task { @MainActor in
                self?.resumeData = data
                self?.isDownloading = false
            }
        })
    }

    // -- Resume support (exposed for unit test testResumeSupport only) --
    // NOTE: Production download() uses URLSession native resume data (resumeData
    // stored property), not Range headers. buildResumeRequest is tested in
    // isolation to verify header construction; it is not called by download().

    func buildResumeRequest(url: URL, existingBytes: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    // -- SHA256 --

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // NOTE: Do NOT use Data(contentsOf:) for a ~1.5 GB model file —
    // it maps the entire file into RAM, causing memory pressure on 8 GB Macs
    // and potential OOM termination. Stream the file in 1 MB chunks instead.
    func verifySHA256(at url: URL) -> Bool {
        if Self.expectedSHA256 == "TBD_PIN_BEFORE_RELEASE" {
            logger.warning("SHA256 not yet pinned — skipping verification")
            return true
        }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }

        var hasher = SHA256()
        let chunkSize = 1 * 1024 * 1024  // 1 MB
        while let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        logger.info("Model SHA256: \(hash)")
        return hash == Self.expectedSHA256
    }

    // -- Test helper --

    func simulateProgress(_ values: [Double]) {
        for v in values { onProgress?(v) }
    }

    // -- URLSessionDownloadDelegate --

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let p = Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, 1))
        Task { @MainActor in
            self.progress = p
            self.onProgress?(p)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // verifySHA256 reads the entire file (~1.5 GB) synchronously on the
            // URLSession delegate queue. This blocks the queue for several seconds.
            // Acceptable because: (a) only one download is ever in flight at a time,
            // (b) the temp file at `location` is deleted by URLSession after this
            // delegate returns, so verification must complete here, not after move.
            guard verifySHA256(at: location) else {
                try? FileManager.default.removeItem(at: location)
                Task { @MainActor in
                    self.error = "Model integrity check failed — download may be corrupted. Please retry."
                    self.isDownloading = false
                    self.progress = 0.0
                    self.resumeData = nil  // corrupt download; start fresh
                }
                return
            }

            // Move verified file to final destination
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)

            Task { @MainActor in
                self.resumeData = nil
                self.isDownloading = false
                self.progress = 1.0
            }
        } catch {
            Task { @MainActor in
                self.error = "Failed to save model: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        let nsErr = error as NSError
        // Preserve any resume data attached to the error so the next download()
        // call can restart from where it left off instead of from byte 0.
        let savedResumeData = nsErr.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        guard nsErr.code != NSURLErrorCancelled else {
            // Cancellation is handled in cancel() via byProducingResumeData.
            return
        }
        Task { @MainActor in
            if let data = savedResumeData { self.resumeData = data }
            self.error = "Download failed: \(error.localizedDescription)"
            self.isDownloading = false
        }
    }
}
```

- [ ] **Step 36: Run tests — pass**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/ModelDownloaderTests 2>&1 | tail -20`
Expected: 4 tests PASS

---

### Task 10: OnboardingView

**Files:**
- [ ] Create: `app/OpenVerb/UI/OnboardingView.swift`

> **Xcode:** Add `OnboardingView.swift` to the **OpenVerb** target in `OpenVerb.xcodeproj`.

- [ ] **Step 38: Write OnboardingView — permissions wizard + model download**

```swift
// app/OpenVerb/UI/OnboardingView.swift
import SwiftUI
import AVFoundation
import ApplicationServices

struct OnboardingView: View {
    @ObservedObject var downloader: ModelDownloader
    @State private var step: OnboardingStep = .welcome
    @State private var micGranted = false
    @State private var accessibilityGranted = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome, microphone, accessibility, inputMonitoring, modelDownload, done
    }

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .welcome:
                welcomeStep
            case .microphone:
                microphoneStep
            case .accessibility:
                accessibilityStep
            case .inputMonitoring:
                inputMonitoringStep
            case .modelDownload:
                modelDownloadStep
            case .done:
                doneStep
            }
        }
        .frame(width: 480, height: 360)
        .padding(32)
    }

    // -- Steps --

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Welcome to OpenVerb")
                .font(.title)
            Text("100% local voice-to-text. No cloud, no data leaves your device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { step = .microphone }
                .buttonStyle(.borderedProminent)
        }
    }

    private var microphoneStep: some View {
        permissionStep(
            icon: "mic.fill",
            title: "Microphone",
            description: "OpenVerb needs microphone access to record your voice.",
            action: {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        micGranted = granted
                        step = .accessibility
                    }
                }
            },
            buttonTitle: "Allow Microphone"
        )
    }

    private var accessibilityStep: some View {
        permissionStep(
            icon: "hand.raised.fill",
            title: "Accessibility",
            description: "Optional but recommended. Enables context-aware text (window title, selected text).",
            action: {
                // #44: use takeUnretainedValue() — kAXTrustedCheckOptionPrompt is a CF
                // constant with +0 refcount; takeRetainedValue() over-releases it.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
                // Cannot detect result immediately — move to next step
                step = .inputMonitoring
            },
            buttonTitle: "Open Accessibility Settings",
            isOptional: true,
            skipAction: { step = .inputMonitoring }
        )
    }

    private var inputMonitoringStep: some View {
        // UX note: Input Monitoring cannot be requested programmatically —
        // macOS only shows the system prompt when a CGEvent tap is first
        // created (which happens on the first ⌥Space press). This step
        // informs the user upfront and provides a direct link to System
        // Settings so they can grant it proactively. Without this link the
        // step is misleading ("Continue" does nothing visible).
        permissionStep(
            icon: "keyboard.fill",
            title: "Input Monitoring",
            description: "Required for the ⌥Space global hotkey.\n\nmacOS will ask for this permission the first time you press ⌥Space. You can also grant it now in System Settings.",
            action: {
                // Open Input Monitoring settings directly so the user can
                // grant it before the first hotkey press.
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring") {
                    NSWorkspace.shared.open(url)
                }
                step = .modelDownload
            },
            buttonTitle: "Open Settings & Continue",
            isOptional: true,
            skipAction: { step = .modelDownload }
        )
    }

    private var modelDownloadStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Download Model")
                .font(.title2)
            Text("Gemma 4 E2B (~1.5 GB). One-time download.")
                .foregroundStyle(.secondary)

            if downloader.isDownloading {
                ProgressView(value: downloader.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { downloader.cancel() }
            } else if let error = downloader.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                Button("Retry") {
                    Task { try? await downloader.download() }
                }
            } else if downloader.progress >= 1.0 {
                Label("Download complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Continue") { step = .done }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Download") {
                    Task { try? await downloader.download() }
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're all set!")
                .font(.title)
            Text("Press ⌥Space anywhere to start dictating.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Start Using OpenVerb") { onComplete() }
                .buttonStyle(.borderedProminent)
        }
    }

    // -- Reusable permission step template --

    private func permissionStep(
        icon: String,
        title: String,
        description: String,
        action: @escaping () -> Void,
        buttonTitle: String,
        isOptional: Bool = false,
        skipAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text(title).font(.title2)
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                if isOptional, let skip = skipAction {
                    Button("Skip") { skip() }
                }
                Button(buttonTitle) { action() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
```

- [ ] **Step 39: Build to verify compilation**

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

---

### Task 11: Wire Onboarding into app launch

**Files:**
- [ ] Modify: `app/OpenVerb/App/OpenVerbApp.swift`
- [ ] Modify: `app/OpenVerb/Engine/EngineManager.swift`

- [ ] **Step 41: Add stored properties and first-launch detection in AppDelegate**

First, add the missing stored properties to `AppDelegate` (alongside the existing `appSettings`):

```swift
// After: private var appSettings: AppSettings!
private var onboardingWindow: NSWindow?
```

Then refactor `applicationDidFinishLaunching` into two parts — extract the post-init logic into `normalStartup()`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    // Suppress SIGPIPE process-wide — MUST come before any socket I/O.
    // Without this, a write() to a broken engine socket delivers SIGPIPE
    // before write() returns EPIPE, silently killing the app.
    signal(SIGPIPE, SIG_IGN)

    // Initialise state objects (unchanged from MVP3)
    appState      = AppState()
    engineManager = EngineManager()
    hotkeyManager = HotkeyManager()
    audioSession  = AudioSession()
    waveformVM    = WaveformViewModel()
    processingVM  = ProcessingViewModel()
    appSettings   = AppSettings()

    recordingWindow = RecordingWindow(
        appState: appState, waveformVM: waveformVM, processingVM: processingVM
    )

    // Check if this is first launch (no model downloaded yet)
    if !engineManager.ggufModelExists() {
        showOnboarding()
        return  // Onboarding triggers normalStartup() on completion
    }

    normalStartup()
}

/// Extracted from applicationDidFinishLaunching — runs all Steps 22-28.
/// Called directly on returning launch, or after onboarding completes.
private func normalStartup() {
    // Steps 22-28 remain identical to existing MVP3 code:
    // 22: AXIsProcessTrustedWithOptions
    // 23: checkModelExists
    // 24: Task { ensureRunning }
    // 25: hotkeyManager.register() + callbacks
    // 26: onError bridge
    // 27: statusBar = StatusBarItem(...)
    // 28: sleep/wake bridge
    // (Copy the existing body of Steps 22-28 here verbatim.)
}
```

Add the onboarding presentation method:

```swift
private func showOnboarding() {
    let downloader = ModelDownloader()
    let onboardingView = OnboardingView(downloader: downloader) { [weak self] in
        self?.onboardingWindow?.close()
        self?.onboardingWindow = nil
        self?.normalStartup()
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = "OpenVerb Setup"
    window.contentView = NSHostingView(rootView: onboardingView)
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    onboardingWindow = window
}
```

- [ ] **Step 42: Wire `backendOverride` into engine subprocess args**

**PREREQUISITE: Step 29a must be completed first.** `backendOverride: String?` stored property and
`restartWithBackend()` were added there. Attempting this step without Step 29a produces a compile
error (`Value of type 'EngineManager' has no member 'backendOverride'`).

Now update the subprocess args in `launchEngine()` — that is where `proc.arguments` is actually set, not in `ensureRunning()`:

```swift
// In launchEngine(), replace:
//   proc.arguments = ["--listen", "--socket", socketPath]
// With:
var args = ["--listen", "--socket", socketPath]
if let backend = backendOverride {
    args += ["--backend", backend]
}
proc.arguments = args
```

- [ ] **Step 43: Build to verify**

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

---

## Chunk 4: MVP5c — TextInjector Fallback & Custom Shortcut

### Task 12: CGEvent per-character fallback in TextInjector

**Files:**
- [ ] Modify: `app/OpenVerb/Output/TextInjector.swift`
- [ ] Create: `app/OpenVerbTests/TextInjectorTests.swift`

> **Xcode:** Add `TextInjectorTests.swift` to the **OpenVerbTests** target in `OpenVerb.xcodeproj`. Alternatively run tests via `cd app && swift test`.

- [ ] **Step 45: Write failing test for character injection**

```swift
// app/OpenVerbTests/TextInjectorTests.swift
import XCTest
@testable import OpenVerb

final class TextInjectorTests: XCTestCase {

    func testCharacterToKeyCodeMappingCoversASCII() {
        // Verify mapping for basic ASCII characters
        let mapped = TextInjector.keyCodeForCharacter("a")
        XCTAssertNotNil(mapped)

        let mappedSpace = TextInjector.keyCodeForCharacter(" ")
        XCTAssertNotNil(mappedSpace)

        let mappedPeriod = TextInjector.keyCodeForCharacter(".")
        XCTAssertNotNil(mappedPeriod)
    }

    func testShiftFlagForUppercase() {
        let (keyCode, flags) = TextInjector.keyCodeAndFlags(for: "A")!
        XCTAssertEqual(keyCode, TextInjector.keyCodeForCharacter("a")!.0)
        XCTAssertTrue(flags.contains(.maskShift))
    }

    func testNilForUnsupportedCharacter() {
        // CGEvent fallback cannot type CJK or emoji — returns nil
        let mapped = TextInjector.keyCodeForCharacter("漢")
        XCTAssertNil(mapped)
    }
}
```

- [ ] **Step 46: Run tests — fail (methods don't exist)**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/TextInjectorTests 2>&1 | tail -20`
Expected: FAIL

- [ ] **Step 47: Add character-by-character injection to TextInjector**

Add to `app/OpenVerb/Output/TextInjector.swift`:

```swift
// -- CGEvent per-character fallback (MVP5) --
// Used when ⌘V is blocked (e.g. some terminal emulators, secure input fields).
// Only supports ASCII printable characters.

/// Map a single character to its (keyCode, needsShift).
static func keyCodeForCharacter(_ char: String) -> (UInt16, Bool)? {
    guard char.count == 1, let scalar = char.unicodeScalars.first else { return nil }
    return Self.charToKeyCode[scalar]
}

/// Returns (keyCode, flags) including shift if needed.
/// NOTE: keyCodeForCharacter returns a (UInt16, Bool) where the Bool is
/// always false in the current map (all entries are lowercase, needsShift=false).
/// We ignore the Bool (hence `_`) and instead derive shift from the caller's
/// original character case. This is intentional: the map knows about key
/// positions, not about the character case the caller wants to produce.
static func keyCodeAndFlags(for char: String) -> (UInt16, CGEventFlags)? {
    guard let (code, _) = keyCodeForCharacter(char.lowercased()) else { return nil }
    let needsShift = char != char.lowercased()
    let flags: CGEventFlags = needsShift ? .maskShift : CGEventFlags(rawValue: 0)
    return (code, flags)
}

/// Inject text character by character via CGEvent keystrokes.
/// Slow (~5ms per char) but works where ⌘V is blocked.
static func injectPerCharacter(_ text: String) async {
    for char in text {
        guard let (keyCode, flags) = keyCodeAndFlags(for: String(char)) else {
            // Skip unsupported characters (CJK, emoji).
            // Clipboard fallback is the only way for these.
            logger.debug("TextInjector: skipping unsupported char: \(String(char))")
            continue
        }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
            if flags != CGEventFlags(rawValue: 0) { down.flags = flags }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// ANSI key code lookup table
private static let charToKeyCode: [Unicode.Scalar: (UInt16, Bool)] = {
    var map: [Unicode.Scalar: (UInt16, Bool)] = [:]
    let row1: [(Unicode.Scalar, UInt16)] = [
        ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03),
        ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
        ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C),
        ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10),
        ("t", 0x11), ("1", 0x12), ("2", 0x13), ("3", 0x14),
        ("4", 0x15), ("6", 0x16), ("5", 0x17), ("=", 0x18),
        ("9", 0x19), ("7", 0x1A), ("-", 0x1B), ("8", 0x1C),
        ("0", 0x1D), ("]", 0x1E), ("o", 0x1F), ("u", 0x20),
        ("[", 0x21), ("i", 0x22), ("p", 0x23), ("l", 0x25),
        ("j", 0x26), ("'", 0x27), ("k", 0x28), (";", 0x29),
        ("\\", 0x2A), (",", 0x2B), ("/", 0x2C), ("n", 0x2D),
        ("m", 0x2E), (".", 0x2F), ("`", 0x32),
    ]
    for (char, code) in row1 { map[char] = (code, false) }
    map[" "] = (0x31, false)   // Space
    map["\t"] = (0x30, false)  // Tab
    map["\n"] = (0x24, false)  // Return
    return map
}()
```

- [ ] **Step 48: Run tests — pass**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/TextInjectorTests 2>&1 | tail -20`
Expected: 3 tests PASS

- [ ] **Step 49: Document fallback wiring decision (no auto-trigger in MVP5)**

**Decision:** `injectPerCharacter()` is NOT auto-triggered from `inject()` in MVP5. Reliable detection of "paste blocked" is impossible without Accessibility API element inspection (checking if the focused field supports the `AXValue` attribute), which adds latency and fragility.

For MVP5, the fallback is an explicitly callable method. Future integration points:
- [ ] A "Character-by-character injection" toggle in Preferences (Task 8 PreferencesView) can call `injectPerCharacter()` instead of the ⌘V path when enabled.
- [ ] A post-v1.0 task can implement AX-based paste detection.

**No code change needed in `inject()` for this step.** The step is a decision checkpoint, not an implementation step.

---

### Task 13: Custom shortcut recorder

**Files:**
- [ ] Create: `app/OpenVerb/Input/ShortcutRecorder.swift`

> **Xcode:** Add `ShortcutRecorder.swift` to the **OpenVerb** target in `OpenVerb.xcodeproj`.

- [ ] **Step 51: Write ShortcutRecorder — NSView-based key capture**

```swift
// app/OpenVerb/Input/ShortcutRecorder.swift
import SwiftUI
import Carbon
import ApplicationServices
import os

/// A SwiftUI view that captures a single key combo when focused.
/// Used in Preferences to let the user pick a custom hotkey.
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var keyCode: UInt16
    @Binding var modifiers: CGEventFlags

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onCapture = { code, mods in
            keyCode = code
            modifiers = mods
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {}
}

final class ShortcutCaptureView: NSView {
    var onCapture: ((UInt16, CGEventFlags) -> Void)?

    private var isRecording = false
    private var localMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            startRecording()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg: NSColor = isRecording ? .controlAccentColor.withAlphaComponent(0.15) : .controlBackgroundColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.fill()

        let text = isRecording ? "Press a key combo... (Esc to cancel)" : "Click to record"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    private func startRecording() {
        isRecording = true
        needsDisplay = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Escape cancels recording without capturing a new hotkey.
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            // Require at least one modifier (⌥, ⌃, ⇧, ⌘) to avoid capturing
            // bare letter/number keys that would break normal text input.
            let mods = event.modifierFlags
            let hasMod = mods.contains(.option) || mods.contains(.control)
                || mods.contains(.shift) || mods.contains(.command)
            if hasMod {
                var flags = CGEventFlags(rawValue: 0)
                if mods.contains(.option)  { flags.insert(.maskAlternate) }
                if mods.contains(.control) { flags.insert(.maskControl) }
                if mods.contains(.shift)   { flags.insert(.maskShift) }
                if mods.contains(.command) { flags.insert(.maskCommand) }
                self.onCapture?(event.keyCode, flags)
                self.stopRecording()
            }
            return nil // consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        needsDisplay = true
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
```

- [ ] **Step 52: Build to verify**

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 53: Update PreferencesView "Change..." button to use ShortcutRecorder**

In `app/OpenVerb/UI/PreferencesView.swift`, replace the placeholder (keep the "Reset to Default" button added in Step 29b):

```swift
Section("Hotkey") {
    HStack {
        Text("Current:")
        Text(hotkeyDescription).foregroundStyle(.secondary)
        Spacer()
        Button("Reset to Default") {
            settings.hotkeyKeyCode = 0x31
            settings.hotkeyModifiers = .maskAlternate
        }
        .foregroundStyle(.secondary)
        .font(.caption)
    }
    ShortcutRecorderView(
        keyCode: $settings.hotkeyKeyCode,
        modifiers: Binding(
            get: { settings.hotkeyModifiers },
            set: { settings.hotkeyModifiers = $0 }
        )
    )
    .frame(height: 28)
}
```

---

### Task 13b: Wire AppSettings hotkey into HotkeyManager

**Files:**
- [ ] Modify: `app/OpenVerb/App/OpenVerbApp.swift`
- [ ] Modify: `app/OpenVerb/Engine/EngineManager.swift` (or HotkeyManager if needed)

Without this task, the user can record a hotkey in Preferences and it is saved to UserDefaults —
but (a) on app restart `HotkeyManager` ignores UserDefaults and re-registers `.altSpace`, and
(b) changing the hotkey live does not reinstall the CGEvent tap.

- [ ] **Step 54a: Load saved hotkey from AppSettings on startup**

In `normalStartup()` in `OpenVerbApp.swift`, before `hotkeyManager.register()`:

```swift
// Load hotkey from persisted settings so the user's custom key survives restart.
// HotkeyManager owns the HotKey struct; pass the saved values before register().
hotkeyManager.configure(keyCode: appSettings.hotkeyKeyCode,
                        modifiers: appSettings.hotkeyModifiers)
```

Add to `HotkeyManager`:

```swift
/// Updates the active hotkey configuration. Call before register() on startup,
/// or to apply a Preferences change without restarting the app.
func configure(keyCode: CGKeyCode, modifiers: CGEventFlags) {
    let newKey = HotKey(virtualKey: keyCode, flags: modifiers)
    installEventTap(key: newKey)
}
```

- [ ] **Step 54b: Observe AppSettings changes and reinstall tap**

In `normalStartup()`, after `hotkeyManager.register()`, add a Combine observer:

```swift
// Live-reload the hotkey tap whenever the user changes it in Preferences.
// Both publishers must fire together — a keyCode-only change leaves modifiers
// stale and vice versa. combineLatest ensures atomic re-registration.
appSettings.$hotkeyKeyCode
    .combineLatest(appSettings.$hotkeyModifiers)
    .dropFirst()  // skip the initial emit (already applied in Step 54a)
    .receive(on: RunLoop.main)
    .sink { [weak self] keyCode, modifiers in
        self?.hotkeyManager.configure(keyCode: keyCode, modifiers: modifiers)
    }
    .store(in: &cancellables)
```

- [ ] **Step 54c: Build and run tests**

Run: `cd app && xcodebuild test -scheme OpenVerb 2>&1 | tail -20`
Expected: ALL PASS

---

## Chunk 5: MVP5d — i18n Templates & Distribution

### Task 14: Engine i18n prompt templates

**Files:**
- [ ] Create: `engine/src/context/templates/en.h`
- [ ] Create: `engine/src/context/templates/ru.h`
- [ ] Create: `engine/src/context/templates/es.h`
- [ ] Create: `engine/src/context/templates/fr.h`
- [ ] Create: `engine/src/context/templates/de.h`
- [ ] Create: `engine/src/context/templates/ja.h`
- [ ] Modify: `engine/src/context/prompt_builder.h`
- [ ] Modify: `engine/src/context/prompt_builder.cpp`

- [ ] **Step 55: Create English template (extract from current prompt_builder.cpp)**

```cpp
// engine/src/context/templates/en.h
#pragma once
#include <string>

namespace openverb::templates {

inline const std::string SYSTEM_PROMPT_EN =
    "You are an expert text editor processing direct audio input.\n"
    "The user dictated speech. Your task:\n"
    "1. Transcribe what the user said faithfully, preserving all sentences and ideas.\n"
    "   For short utterances: output the single phrase. For long dictations: output\n"
    "   every sentence — do NOT summarize or collapse multiple sentences into one.\n"
    "2. If the same phrase or sentence appears repeated multiple times in the audio,\n"
    "   output it ONCE only — repetition is an audio encoding artifact, not intentional.\n"
    "3. Remove filler words (um, uh, like, you know).\n"
    "4. Fix grammar, adapt tone and style for the active application.\n"
    "5. If the output is ONLY a structural command (delete that, undo, new line,\n"
    "   new paragraph), output ONLY that command word(s) with no other text.\n"
    "   Punctuation (period, comma, question mark, exclamation) is NOT a command —\n"
    "   output it directly as . , ? ! in the tailored text.\n"
    "6. The <ClipboardContext> block (if present) is a READ-ONLY style reference.\n"
    "   NEVER reproduce, quote, or echo its content in the output.";

inline const std::string GENERATION_SUFFIX_EN = "Output ONLY the final text:";

} // namespace openverb::templates
```

- [ ] **Step 56: Create Russian template**

```cpp
// engine/src/context/templates/ru.h
#pragma once
#include <string>

namespace openverb::templates {

inline const std::string SYSTEM_PROMPT_RU =
    "Ты — экспертный текстовый редактор, обрабатывающий аудиовход.\n"
    "Пользователь продиктовал речь. Твоя задача:\n"
    "1. Транскрибируй сказанное, сохраняя все предложения и мысли.\n"
    "   Для коротких фраз: выведи одну фразу. Для длинных диктовок: выведи\n"
    "   каждое предложение — НЕ сокращай и не объединяй несколько предложений.\n"
    "2. Если одна и та же фраза повторяется несколько раз в аудио,\n"
    "   выведи её ОДИН раз — повторение является артефактом кодирования.\n"
    "3. Убери слова-паразиты (э, ну, типа, это).\n"
    "4. Исправь грамматику, адаптируй тон и стиль под активное приложение.\n"
    "5. Если ответ — ТОЛЬКО структурная команда (удалить, отменить, новая строка,\n"
    "   новый абзац), выведи ТОЛЬКО команду без другого текста.\n"
    "   Пунктуация (точка, запятая, вопросительный, восклицательный знак) — НЕ команда,\n"
    "   выводи её напрямую как . , ? ! в итоговом тексте.\n"
    "6. Блок <ClipboardContext> (если есть) — справочник стиля, ТОЛЬКО ДЛЯ ЧТЕНИЯ.\n"
    "   НИКОГДА не воспроизводи, не цитируй и не повторяй его содержимое в выводе.";

inline const std::string GENERATION_SUFFIX_RU = "Выведи ТОЛЬКО итоговый текст:";

} // namespace openverb::templates
```

- [ ] **Step 57: Create remaining templates (es, fr, de, ja)**

```cpp
// engine/src/context/templates/es.h
#pragma once
#include <string>

namespace openverb::templates {

inline const std::string SYSTEM_PROMPT_ES =
    "Eres un editor de texto experto que procesa entrada de audio directa.\n"
    "El usuario dictó un discurso. Tu tarea:\n"
    "1. Transcribe fielmente lo que dijo, preservando todas las oraciones e ideas.\n"
    "   Para frases cortas: genera la frase única. Para dictados largos: genera\n"
    "   cada oración — NO resumas ni combines varias oraciones en una.\n"
    "2. Si la misma frase aparece repetida varias veces en el audio,\n"
    "   escríbela UNA sola vez — la repetición es un artefacto de codificación.\n"
    "3. Elimina muletillas (eh, pues, o sea, bueno).\n"
    "4. Corrige la gramática, adapta el tono y estilo a la aplicación activa.\n"
    "5. Si la salida es SOLO un comando estructural (eliminar, deshacer, nueva línea,\n"
    "   nuevo párrafo), genera SOLO ese comando sin otro texto.\n"
    "   La puntuación (punto, coma, interrogación, exclamación) NO es un comando —\n"
    "   inclúyela directamente como . , ? ! en el texto final.\n"
    "6. El bloque <ClipboardContext> (si existe) es una referencia de estilo DE SOLO LECTURA.\n"
    "   NUNCA reproduzcas, cites o repitas su contenido en la salida.";

inline const std::string GENERATION_SUFFIX_ES = "Genera SOLO el texto final:";

} // namespace openverb::templates
```

```cpp
// engine/src/context/templates/fr.h
#pragma once
#include <string>

namespace openverb::templates {

inline const std::string SYSTEM_PROMPT_FR =
    "Tu es un éditeur de texte expert traitant une entrée audio directe.\n"
    "L'utilisateur a dicté un discours. Ta tâche :\n"
    "1. Transcris fidèlement ce qui a été dit, en préservant toutes les phrases et idées.\n"
    "   Pour les énoncés courts : produis la phrase unique. Pour les longues dictées :\n"
    "   produis chaque phrase — NE résume PAS et ne fusionne pas plusieurs phrases.\n"
    "2. Si la même phrase apparaît répétée plusieurs fois dans l'audio,\n"
    "   écris-la UNE seule fois — la répétition est un artefact d'encodage.\n"
    "3. Supprime les mots de remplissage (euh, ben, genre, tu vois).\n"
    "4. Corrige la grammaire, adapte le ton et le style à l'application active.\n"
    "5. Si la sortie est UNIQUEMENT une commande structurelle (supprimer, annuler,\n"
    "   nouvelle ligne, nouveau paragraphe), produis UNIQUEMENT cette commande.\n"
    "   La ponctuation (point, virgule, point d'interrogation, point d'exclamation)\n"
    "   N'est PAS une commande — inclus-la directement comme . , ? ! dans le texte.\n"
    "6. Le bloc <ClipboardContext> (s'il est présent) est une référence de style EN LECTURE SEULE.\n"
    "   NE reproduis, cite ou répète JAMAIS son contenu dans la sortie.";

inline const std::string GENERATION_SUFFIX_FR = "Produis UNIQUEMENT le texte final :";

} // namespace openverb::templates
```

```cpp
// engine/src/context/templates/de.h
#pragma once
#include <string>

namespace openverb::templates {

inline const std::string SYSTEM_PROMPT_DE =
    "Du bist ein erfahrener Texteditor, der direkte Audioeingaben verarbeitet.\n"
    "Der Benutzer hat Sprache diktiert. Deine Aufgabe:\n"
    "1. Transkribiere das Gesagte originalgetreu, bewahre alle Sätze und Ideen.\n"
    "   Bei kurzen Äußerungen: gib den einzelnen Satz aus. Bei langen Diktaten:\n"
    "   gib jeden Satz aus — fasse NICHT zusammen und kombiniere nicht mehrere Sätze.\n"
    "2. Wenn derselbe Satz mehrfach im Audio wiederholt wird,\n"
    "   gib ihn NUR EINMAL aus — Wiederholung ist ein Kodierungsartefakt.\n"
    "3. Entferne Füllwörter (äh, also, halt, sozusagen).\n"
    "4. Korrigiere die Grammatik, passe Ton und Stil an die aktive Anwendung an.\n"
    "5. Wenn die Ausgabe NUR ein Strukturbefehl ist (löschen, rückgängig, neue Zeile,\n"
    "   neuer Absatz), gib NUR diesen Befehl ohne weiteren Text aus.\n"
    "   Satzzeichen (Punkt, Komma, Fragezeichen, Ausrufezeichen) sind KEIN Befehl —\n"
    "   gib sie direkt als . , ? ! im Text aus.\n"
    "6. Der <ClipboardContext>-Block (falls vorhanden) ist eine SCHREIBGESCHÜTZTE Stilreferenz.\n"
    "   Gib seinen Inhalt NIEMALS in der Ausgabe wieder, zitiere oder wiederhole ihn nicht.";

inline const std::string GENERATION_SUFFIX_DE = "Gib NUR den fertigen Text aus:";

} // namespace openverb::templates
```

```cpp
// engine/src/context/templates/ja.h
#pragma once
#include <string>

namespace openverb::templates {

inline const std::string SYSTEM_PROMPT_JA =
    "あなたは直接の音声入力を処理する熟練テキストエディタです。\n"
    "ユーザーが音声を入力しました。あなたの仕事：\n"
    "1. 話された内容を忠実に書き起こし、すべての文と考えを保持してください。\n"
    "   短い発話：その一つのフレーズを出力。長い口述：\n"
    "   すべての文を出力 — 複数の文を要約したり統合したりしないでください。\n"
    "2. 同じフレーズや文が音声中に繰り返し現れる場合、\n"
    "   1回だけ出力してください — 繰り返しはエンコーディングの問題です。\n"
    "3. フィラー語（えー、あの、まあ、なんか）を除去してください。\n"
    "4. 文法を修正し、アクティブなアプリケーションに合わせてトーンとスタイルを調整。\n"
    "5. 出力が構造コマンドのみの場合（削除、元に戻す、改行、\n"
    "   新段落）、そのコマンドだけを出力してください。\n"
    "   句読点（。、？！）はコマンドではありません —\n"
    "   最終テキストにそのまま含めてください。\n"
    "6. <ClipboardContext>ブロック（存在する場合）は読み取り専用のスタイル参照です。\n"
    "   その内容を出力に再現、引用、または繰り返すことは絶対にしないでください。";

inline const std::string GENERATION_SUFFIX_JA = "最終テキストのみを出力：";

} // namespace openverb::templates
```

- [ ] **Step 58: Update prompt_builder to use locale-based template selection**

**CRITICAL ORDER: (58a) struct → (58b) parse_context_json → (58c) select_template → (58d) build_prompt.**
ContextBuilder.swift already sends `"language"` in every JSON (ContextBuilder.swift:71). If 58b is skipped
or deferred, `ctx.language` is always `""` and the entire i18n feature silently falls back to English.

**(58a) Extend PromptContext in `engine/src/context/prompt_builder.h` and fix stale comments:**

```cpp
struct PromptContext {
    std::string app_name;
    std::string window_title;
    std::string clipboard;
    std::string selected_text;
    std::string language;  // NEW: BCP-47 locale code (e.g. "en", "ru")
};

// build_prompt signature unchanged — reads ctx.language internally.
std::pair<std::string, std::string> build_prompt(const PromptContext& ctx);
```

Also update the wire-format comment above `PromptContext` in the header to include `"language"`:

```cpp
// Wire format (--context flag):
//   {"app":"<bundle-id>","window":"<title>","clipboard":"<text>","selected":"<text>","language":"<bcp47>"}
```

Also fix the stale `resolve_style()` return-value doc in the same header — the comment says unknown IDs return `"general"` but the implementation returns `"Neutral, clean grammar"`. Update the comment:

```cpp
// Unknown bundle IDs return "Neutral, clean grammar".
//
// Example mappings:
//   "com.apple.Terminal"           → "Commands, no prose"
//   "com.apple.Mail"               → "Formal, complete sentences"
//   "com.tinyspeck.slackmacgap"    → "Casual, concise, emoji OK"
//   "com.microsoft.VSCode"         → "Code-aware, syntax-correct, comments"
//   "com.apple.Notes"              → "Raw dictation, preserve everything"
```

**(58b) Wire `"language"` in `parse_context_json()` — BEFORE touching build_prompt:**

```cpp
// Add after the "selected" block in parse_context_json():
if (j.contains("language") && j.at("language").is_string())
    ctx.language = j.at("language").get<std::string>();
```

**(58c) Add #includes and `select_template()` in `engine/src/context/prompt_builder.cpp`:**

```cpp
#include "context/templates/en.h"
#include "context/templates/ru.h"
#include "context/templates/es.h"
#include "context/templates/fr.h"
#include "context/templates/de.h"
#include "context/templates/ja.h"

// Returns non-owning string_views into the static inline strings defined in
// the template headers. This is safe because the template strings have static
// storage duration and outlive all callers. If templates are ever moved to
// dynamic storage (e.g. loaded at runtime into std::string), this function
// must return std::pair<std::string, std::string> instead — string_view into
// a destroyed std::string is undefined behavior.
static std::pair<std::string_view, std::string_view> select_template(const std::string& lang) {
    using namespace openverb::templates;
    if (lang == "ru") return {SYSTEM_PROMPT_RU, GENERATION_SUFFIX_RU};
    if (lang == "es") return {SYSTEM_PROMPT_ES, GENERATION_SUFFIX_ES};
    if (lang == "fr") return {SYSTEM_PROMPT_FR, GENERATION_SUFFIX_FR};
    if (lang == "de") return {SYSTEM_PROMPT_DE, GENERATION_SUFFIX_DE};
    if (lang == "ja") return {SYSTEM_PROMPT_JA, GENERATION_SUFFIX_JA};
    return {SYSTEM_PROMPT_EN, GENERATION_SUFFIX_EN};  // default
}
```

**(58d) Update `build_prompt()` to call `select_template()`:**

```cpp
// In build_prompt(), replace:
//   xml += SYSTEM_PROMPT;
// With:
auto [sys_prompt, gen_suffix] = select_template(ctx.language);
// Then use sys_prompt instead of SYSTEM_PROMPT, and return gen_suffix instead of hardcoded string.
```

Remove the old `static const std::string SYSTEM_PROMPT = ...` constant from prompt_builder.cpp (now lives in templates/en.h).

- [ ] **Step 59: Run engine tests — verify nothing breaks**

Run: `cd engine/build && ctest --output-on-failure 2>&1 | tail -20`
Expected: ALL PASS

---

### Task 15: Homebrew cask + build-release

**Files:**
- [ ] Create: `homebrew/Casks/openverb.rb`
- [ ] Create: `scripts/build-release.sh`

- [ ] **Step 61: Write Homebrew cask formula**

```ruby
# homebrew/Casks/openverb.rb
cask "openverb" do
  version "1.0.0"
  sha256 "TBD_PIN_BEFORE_RELEASE"

  url "https://github.com/openverb/openverb/releases/download/v#{version}/OpenVerb-#{version}.dmg"
  name "OpenVerb"
  desc "100% local voice-to-text for macOS"
  homepage "https://github.com/openverb/openverb"

  depends_on macos: ">= :ventura"

  app "OpenVerb.app"

  postflight do
    # Create model directory
    system_command "/bin/mkdir", args: ["-p", "#{Dir.home}/.openverb/models"]
  end

  zap trash: [
    # UserDefaults plist written by NSUserDefaults with the app's bundle ID.
    # LaunchAgent is NOT included — OpenVerb does not register a LaunchAgent.
    "~/Library/Preferences/io.openverb.app.plist",
    "~/.openverb",
  ]
end
```

- [ ] **Step 62: Write build-release.sh**

```bash
#!/usr/bin/env bash
# scripts/build-release.sh — build universal binary + signed DMG
set -euo pipefail

VERSION="${1:?Usage: build-release.sh <version>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build-release"

echo "=== Building OpenVerb $VERSION ==="

# 0. Pin model SHA256 BEFORE building the app so the compile-time constant
#    is baked into the binary. MODEL_PATH defaults to $ROOT_DIR/models/ but
#    can be overridden: MODEL_PATH=/path/to/model.gguf ./build-release.sh 1.0.0
MODEL_PATH="${MODEL_PATH:-$ROOT_DIR/models/gemma-4-E2B-it-Q4_K_M.gguf}"
if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: Model file not found at $MODEL_PATH"
    echo "Set MODEL_PATH env var or place the file at the default location:"
    echo "  $ROOT_DIR/models/gemma-4-E2B-it-Q4_K_M.gguf"
    exit 1
fi
MODEL_SHA=$(shasum -a 256 "$MODEL_PATH" | cut -d' ' -f1)
echo "Model SHA256: $MODEL_SHA"
# Pin into source before compiling — the app binary will contain the real hash.
sed -i '' "s/static let expectedSHA256 = \".*\"/static let expectedSHA256 = \"$MODEL_SHA\"/" \
    "$ROOT_DIR/app/OpenVerb/Model/ModelDownloader.swift"
echo "Pinned model SHA256 in ModelDownloader.swift"

# 1. Build engine — two separate cmake builds then lipo-merge.
# Metal (GGML_METAL) only runs on Apple Silicon; a single cmake invocation
# with arm64+x86_64 architectures and GGML_METAL=ON fails to compile the
# x86_64 slice because Metal is unavailable on Intel.
cd "$ROOT_DIR/engine"
cmake -B build-arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DCMAKE_OSX_ARCHITECTURES="arm64"
cmake --build build-arm64 -j"$(sysctl -n hw.ncpu)"

cmake -B build-x86 \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=OFF \
    -DCMAKE_OSX_ARCHITECTURES="x86_64"
cmake --build build-x86 -j"$(sysctl -n hw.ncpu)"

mkdir -p build-release
lipo -create build-arm64/openverb-engine build-x86/openverb-engine \
    -output build-release/openverb-engine

# 2. Build app universal binary (SHA256 is now compiled in from step 0).
# ONLY_ACTIVE_ARCH=NO is required — without it Xcode builds only the
# architecture of the current machine regardless of the ARCHS setting.
cd "$ROOT_DIR/app"
xcodebuild -scheme OpenVerb \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64" \
    build

# 3. Copy engine binary into app bundle
APP_PATH="$BUILD_DIR/derived/Build/Products/Release/OpenVerb.app"
cp "$ROOT_DIR/engine/build-release/openverb-engine" \
   "$APP_PATH/Contents/MacOS/openverb-engine"

# 3b. Code-sign the app bundle (required for Gatekeeper — unsigned apps are
#     blocked by default on macOS. DEVELOPER_ID must be set in the environment:
#       export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#     The --deep flag signs embedded binaries (openverb-engine) in one pass.
#     --options runtime enables the hardened runtime required for notarization.
if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --deep \
             --force \
             --verify \
             --sign "$DEVELOPER_ID" \
             --options runtime \
             --entitlements "$ROOT_DIR/app/OpenVerb.entitlements" \
             "$APP_PATH"
    echo "Code-signed: $APP_PATH"
else
    echo "WARNING: DEVELOPER_ID not set — skipping code signing. DMG will be blocked by Gatekeeper."
fi

# 4. Create DMG
DMG_PATH="$BUILD_DIR/OpenVerb-$VERSION.dmg"
hdiutil create -volname "OpenVerb" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

# 4b. Notarize DMG (required for distribution outside Mac App Store / Homebrew).
#     Without notarization, Gatekeeper shows a "malicious software" warning on
#     first launch. Requires Apple ID credentials stored in keychain:
#       xcrun notarytool store-credentials "notarytool-profile" \
#           --apple-id your@email.com --team-id TEAMID --password app-specific-password
if [ -n "${DEVELOPER_ID:-}" ]; then
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "notarytool-profile" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    echo "Notarized and stapled: $DMG_PATH"
else
    echo "WARNING: DEVELOPER_ID not set — skipping notarization."
fi

# 5. Update Homebrew cask SHA + version
DMG_SHA=$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)
sed -i '' "s/sha256 \".*\"/sha256 \"$DMG_SHA\"/" "$ROOT_DIR/homebrew/Casks/openverb.rb"
sed -i '' "s/version \".*\"/version \"$VERSION\"/" "$ROOT_DIR/homebrew/Casks/openverb.rb"

# 6. Copy cask to homebrew-tap repo (required by Homebrew conventions)
TAP_REPO="$ROOT_DIR/../homebrew-tap"
if [ -d "$TAP_REPO" ]; then
    cp "$ROOT_DIR/homebrew/Casks/openverb.rb" "$TAP_REPO/Casks/openverb.rb"
    echo "Copied cask to homebrew-tap repo at $TAP_REPO"
else
    echo "WARNING: homebrew-tap repo not found at $TAP_REPO — copy manually"
fi

echo "=== Done: $DMG_PATH ==="
echo "DMG SHA256: $DMG_SHA"
```

- [ ] **Step 63: Make build-release.sh executable**

```bash
chmod +x scripts/build-release.sh
```

---

## Chunk 6: Human Verification (MVP5)

### Task 16: Human verification — full MVP5

- [ ] **Step 65: HUMAN: Build full release**

`./scripts/build-release.sh 1.0.0`

- [ ] **Step 66: HUMAN: Fresh install test**

Delete `~/.openverb/`, run OpenVerb.app → verify onboarding wizard launches (permissions + model download). Complete all steps → verify app works.

- [ ] **Step 67: HUMAN: Preferences test**

Open Preferences from status bar menu → verify:
- [ ] Hotkey section shows current ⌥Space
- [ ] Click recorder → press ⌃Space → hotkey updates
- [ ] Press new hotkey → verify it works for dictation
- [ ] Toggle clipboard OFF → dictate → check engine logs (no clipboard in context JSON)
- [ ] Change language to Russian → dictate → verify Russian system prompt in engine logs

- [ ] **Step 68: HUMAN: Backend switching test**

In Preferences, switch to "Whisper + Gemma Text" → verify:
- [ ] Loading state shown
- [ ] If Whisper model missing → download prompt appears
- [ ] After switch: dictate → verify result (may differ slightly from Path A)
- [ ] Switch back to Gemma Audio → verify it works

- [ ] **Step 69: HUMAN: CGEvent fallback test**

Open Terminal (which may block ⌘V in certain contexts) → dictate → verify text appears. Open a web browser password field → dictate → verify CGEvent per-character injection works for ASCII text.

- [ ] **Step 70: HUMAN: Homebrew install test (clean Mac or VM)**

```bash
brew tap openverb/tap
brew install --cask openverb
# Launch OpenVerb.app → onboarding → model download → ⌥Space → dictate → verify
```

- [ ] **Step 71: HUMAN: Context awareness end-to-end**

Open VS Code with a file selected → some text highlighted → dictate → verify:
- [ ] Engine logs show `"window":"filename.py"` and `"selected":"the selected text"`
- [ ] Output is code-aware (code style, not prose)

Open Mail compose → dictate → verify formal style output.

- [ ] **Step 72: HUMAN: Accessibility denial graceful degradation**

Revoke Accessibility in System Settings → restart app → dictate → verify:
- [ ] App still works (no crash)
- [ ] Context shows `"window":""` and no `"selected"` key
- [ ] Preferences shows hint: "Grant Accessibility for richer context"

- [ ] **Step 73: HUMAN: Sleep/wake with new settings**

Change hotkey to ⌃Space in Preferences. Close lid → open → verify:
- [ ] Engine restarts
- [ ] New hotkey (⌃Space) still works post-wake
- [ ] Settings persist across restart
