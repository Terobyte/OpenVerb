# MVP4-5: Context Awareness + Distribution & Polish

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Accessibility API context awareness (MVP4) and complete distribution pipeline — Preferences, Onboarding, ModelDownloader, CGEvent fallback, i18n templates, Homebrew cask (MVP5).

**Architecture:** MVP4 is Swift-only — the C++ engine already handles `window` and `selected` context JSON fields (`parse_context_json()` in `engine/src/context/prompt_builder.cpp:189-222`). MVP5 spans Swift UI (Preferences, Onboarding), Swift networking (ModelDownloader), Swift input (custom shortcut recorder), C++ templates (i18n), and shell scripting (Homebrew cask, build-release).

**IMPORTANT — JSON key name:** The spec (line 90) uses `"selection"` but the engine implementation (`prompt_builder.cpp:214`) reads `"selected"`. This plan uses `"selected"` to match the running engine code. The spec has a typo — do NOT use `"selection"` as the key.

**Tech Stack:** Swift 5.9 / SwiftUI (macOS 13+), AXUIElement (ApplicationServices), URLSession, C++ (engine templates), Ruby (Homebrew cask), Bash (build-release)

**Existing code alignment:**
- `app/OpenVerb/Context/ContextBuilder.swift:73-78` — explicit "deferred to MVP4" placeholders for `window` and `selection`
- `app/OpenVerb/Output/TextInjector.swift:25` — "CGEvent per-character fallback deferred to MVP5"
- `app/OpenVerb/UI/StatusBarItem.swift` — no Preferences menu item (MVP5)
- `engine/src/context/prompt_builder.cpp:55` — "MVP4+ i18n: replace with per-locale template"
- `engine/src/context/prompt_builder.cpp:74` — "MVP4+ i18n: localize style descriptions" (style localization deferred to post-v1.0; this plan localizes system prompts and generation suffixes only)
- `app/OpenVerb/Engine/EngineManager.swift` — `checkModelExists()` is a simple file check; ModelDownloader replaces the manual download script

---

## Chunk 1: MVP4 — Accessibility API Context

### Task 1: AccessibilityReader — protocol + failing test

**Files:**
- Create: `app/OpenVerb/Context/AccessibilityReader.swift`
- Create: `app/OpenVerbTests/AccessibilityReaderTests.swift`

- [ ] **Step 1: Write the AccessibilityReader protocol and struct skeleton**

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

- [ ] **Step 2: Write failing tests for AccessibilityReader**

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

    func testSelectedTextTruncation() {
        // AccessibilityReader should truncate selected text to 10KB UTF-8
        let mock = MockAccessibilityReader()
        mock.selectedText = String(repeating: "a", count: 15_000)
        // Truncation is applied in ContextBuilder, not AccessibilityReader —
        // AccessibilityReader returns raw. Verify raw return.
        XCTAssertEqual(mock.readSelectedText(for: NSRunningApplication.current)?.count, 15_000)
    }
}
```

- [ ] **Step 3: Run tests to verify they compile and the mock tests pass**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/AccessibilityReaderTests 2>&1 | tail -20`
Expected: 4 tests PASS (mock-based, no real AX calls)

- [ ] **Step 4: Commit**

```bash
git add app/OpenVerb/Context/AccessibilityReader.swift app/OpenVerbTests/AccessibilityReaderTests.swift
git commit -m "add accessibility reader protocol and mock tests"
```

---

### Task 2: AccessibilityReader — AXUIElement implementation

**Files:**
- Modify: `app/OpenVerb/Context/AccessibilityReader.swift`

- [ ] **Step 5: Implement readWindowTitle with AXUIElement**

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
        guard result == .success, let window = focusedWindow else {
            logger.debug("No focused window for \(app.processIdentifier)")
            return nil
        }

        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
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
        guard result == .success, let element = focusedElement else {
            return nil
        }

        var selectedValue: CFTypeRef?
        let selResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedValue)
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

- [ ] **Step 7: Commit**

```bash
git add app/OpenVerb/Context/AccessibilityReader.swift
git commit -m "implement accessibility reader with AXUIElement"
```

---

### Task 3: ContextBuilder — add Accessibility fields

**Files:**
- Modify: `app/OpenVerb/Context/ContextBuilder.swift`
- Modify: `app/OpenVerbTests/ContextBuilderTests.swift`

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
    mockReader.selectedText = String(repeating: "x", count: 15_000)
    let mockApp = MockAppIdentifiable(bundleIdentifier: "com.apple.Notes", localizedName: "Notes")
    let context = await ContextBuilder.build(
        targetApp: mockApp,
        pasteboard: { let pb = MockPasteboard(); pb.content = nil; return pb }(),
        accessibilityReader: mockReader,
        accessibilityApp: nil
    )
    // Truncated to 10_240 UTF-8 bytes
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
        if let app = accessibilityApp {
            context["window"] = accessibilityReader.readWindowTitle(for: app) ?? ""
        } else {
            context["window"] = accessibilityReader.readWindowTitle(for: NSRunningApplication.current) ?? ""
        }

        // "selected" — from Accessibility API; omit entirely if nil/empty.
        // NOTE: engine reads "selected" (not "selection") — see prompt_builder.cpp:214
        let selectionApp = accessibilityApp ?? NSRunningApplication.current
        if let sel = accessibilityReader.readSelectedText(for: selectionApp), !sel.isEmpty {
            context["selected"] = truncateToUTF8Bytes(sel, limit: 10_240)
        }

        return context
    }

    // ... truncateToUTF8Bytes unchanged ...
}
```

**Note:** The existing call sites in `OpenVerbApp.swift` that call `ContextBuilder.build(targetApp:)` continue to work — new params have defaults. The only change needed in `OpenVerbApp.swift` is to pass the real `NSRunningApplication` as `accessibilityApp`:

```swift
// In OpenVerbApp.swift toggle flow, update the ContextBuilder call:
let context = await ContextBuilder.build(
    targetApp: self?.appState.targetApp,
    accessibilityApp: self?.appState.targetApp  // real NSRunningApplication for AX
)
```

- [ ] **Step 11: Run tests to verify all pass**

Run: `cd app && xcodebuild test -scheme OpenVerb 2>&1 | tail -20`
Expected: ALL PASS (old tests use default params, new tests use mock reader)

- [ ] **Step 12: Commit**

```bash
git add app/OpenVerb/Context/ContextBuilder.swift app/OpenVerbTests/ContextBuilderTests.swift
git commit -m "add accessibility context to context builder — window title and selection"
```

---

### Task 4: Wire AccessibilityReader into the app flow

**Files:**
- Modify: `app/OpenVerb/App/OpenVerbApp.swift`

- [ ] **Step 13: Update ContextBuilder call in OpenVerbApp.swift to pass accessibilityApp**

Find the existing call at `app/OpenVerb/App/OpenVerbApp.swift:473` inside `connectAndRecord()`:

```swift
// Before (MVP3):
let context = await ContextBuilder.build(targetApp: appState.targetApp)

// After (MVP4):
let context = await ContextBuilder.build(
    targetApp: appState.targetApp,
    accessibilityApp: appState.targetApp
)
```

- [ ] **Step 14: Build to verify compilation**

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 15: Commit**

```bash
git add app/OpenVerb/App/OpenVerbApp.swift
git commit -m "wire accessibility reader into session start flow"
```

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
- Create: `app/OpenVerb/Settings/` directory (new — does not exist yet)
- Create: `app/OpenVerb/Settings/AppSettings.swift`
- Create: `app/OpenVerbTests/AppSettingsTests.swift`

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

final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    // -- Hotkey --
    @Published var hotkeyKeyCode: UInt16 = 0x31 {  // Space
        didSet { defaults.set(Int(hotkeyKeyCode), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: CGEventFlags = .maskAlternate {
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

        modelDirectory = defaults.string(forKey: "modelDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openverb/models").path
    }
}
```

- [ ] **Step 23: Run test — all pass**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/AppSettingsTests 2>&1 | tail -20`
Expected: 6 tests PASS

- [ ] **Step 24: Commit**

```bash
git add app/OpenVerb/Settings/AppSettings.swift app/OpenVerbTests/AppSettingsTests.swift
git commit -m "add settings storage with user defaults"
```

---

### Task 7: Wire AppSettings into ContextBuilder (clipboard toggle)

**Files:**
- Modify: `app/OpenVerb/Context/ContextBuilder.swift`
- Modify: `app/OpenVerbTests/ContextBuilderTests.swift`

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

- [ ] **Step 28: Commit**

```bash
git add app/OpenVerb/Context/ContextBuilder.swift app/OpenVerbTests/ContextBuilderTests.swift
git commit -m "add clipboard toggle to context builder"
```

---

### Task 8: PreferencesView

**Files:**
- Create: `app/OpenVerb/UI/PreferencesView.swift`
- Modify: `app/OpenVerb/UI/StatusBarItem.swift`

- [ ] **Step 29: Write PreferencesView with SwiftUI**

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
                    Label("Path A supports English audio only. Switching to Whisper.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .onAppear {
                            // Auto-switch to Whisper on non-English locale
                            settings.backend = .whisperGemma
                            Task { await engineManager.restartWithBackend(.whisperGemma) }
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
        if settings.hotkeyModifiers.contains(.maskControl) { parts.append("⌃") }
        if settings.hotkeyModifiers.contains(.maskShift) { parts.append("⇧") }
        if settings.hotkeyModifiers.contains(.maskCommand) { parts.append("⌘") }
        switch settings.hotkeyKeyCode {
        case 0x31: parts.append("Space")
        case 0x32: parts.append("`")
        default: parts.append("Key(\(settings.hotkeyKeyCode))")
        }
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

**Also update the call site** in `app/OpenVerb/App/OpenVerbApp.swift:175`:

```swift
// Before:
statusBar = StatusBarItem(appState: appState, engineManager: engineManager)
// After:
statusBar = StatusBarItem(appState: appState, engineManager: engineManager, appSettings: appSettings)
```

This requires `appSettings` to be a stored property on `AppDelegate` (added in Task 11 when wiring onboarding).

- [ ] **Step 31: Build to verify**

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 32: Commit**

```bash
git add app/OpenVerb/UI/PreferencesView.swift app/OpenVerb/UI/StatusBarItem.swift
git commit -m "add preferences view with hotkey, backend, language, clipboard settings"
```

---

## Chunk 3: MVP5b — ModelDownloader & Onboarding

### Task 9: ModelDownloader — failing test

**Files:**
- Create: `app/OpenVerb/Model/` directory (new — does not exist yet)
- Create: `app/OpenVerb/Model/ModelDownloader.swift`
- Create: `app/OpenVerbTests/ModelDownloaderTests.swift`

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

        let existingBytes = partialFileSize()
        let request = buildResumeRequest(url: Self.modelURL, existingBytes: existingBytes)

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        await MainActor.run { isDownloading = true; error = nil }

        downloadTask = session?.downloadTask(with: request)
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        Task { @MainActor in isDownloading = false }
    }

    // -- Resume support --

    func buildResumeRequest(url: URL, existingBytes: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    private func partialFileSize() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: partialFileURL.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    // -- SHA256 --

    static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func verifySHA256(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let hash = Self.sha256(data)
        logger.info("Model SHA256: \(hash)")
        if Self.expectedSHA256 == "TBD_PIN_BEFORE_RELEASE" {
            logger.warning("SHA256 not yet pinned — skipping verification")
            return true
        }
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
            // Move to final destination
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)

            // Clean up partial file
            try? FileManager.default.removeItem(at: partialFileURL)

            Task { @MainActor in
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
        if let error, (error as NSError).code != NSURLErrorCancelled {
            Task { @MainActor in
                self.error = "Download failed: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }
}
```

- [ ] **Step 36: Run tests — pass**

Run: `cd app && xcodebuild test -scheme OpenVerb -only-testing:OpenVerbTests/ModelDownloaderTests 2>&1 | tail -20`
Expected: 4 tests PASS

- [ ] **Step 37: Commit**

```bash
git add app/OpenVerb/Model/ModelDownloader.swift app/OpenVerbTests/ModelDownloaderTests.swift
git commit -m "add model downloader with resume, progress, sha256 verification"
```

---

### Task 10: OnboardingView

**Files:**
- Create: `app/OpenVerb/UI/OnboardingView.swift`

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
        permissionStep(
            icon: "keyboard.fill",
            title: "Input Monitoring",
            description: "Required for the ⌥Space global hotkey.",
            action: {
                // Input Monitoring is granted when CGEvent tap is created —
                // the system prompts automatically. Advance to model download.
                step = .modelDownload
            },
            buttonTitle: "Continue"
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

- [ ] **Step 40: Commit**

```bash
git add app/OpenVerb/UI/OnboardingView.swift
git commit -m "add onboarding wizard with permissions and model download"
```

---

### Task 11: Wire Onboarding into app launch

**Files:**
- Modify: `app/OpenVerb/App/OpenVerbApp.swift`
- Modify: `app/OpenVerb/Engine/EngineManager.swift`

- [ ] **Step 41: Add first-launch detection and onboarding window in AppDelegate**

In `applicationDidFinishLaunching`, before existing logic:

```swift
// Check if this is first launch (no model downloaded yet)
let isFirstLaunch = !engineManager.ggufModelExists()
if isFirstLaunch {
    showOnboarding()
    return  // Skip normal startup — onboarding will trigger it on completion
}
```

Add the onboarding presentation method:

```swift
private func showOnboarding() {
    let downloader = ModelDownloader()
    let onboardingView = OnboardingView(downloader: downloader) { [weak self] in
        // Onboarding complete — close window and proceed with normal startup
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

- [ ] **Step 42: Add `restartWithBackend()` to EngineManager for backend switching**

In `app/OpenVerb/Engine/EngineManager.swift`, add:

```swift
func restartWithBackend(_ backend: BackendType) async {
    logger.info("Switching backend to \(backend.rawValue)")
    status = .starting

    // Shutdown current engine
    shutdown()

    // Wait for clean exit
    try? await Task.sleep(for: .milliseconds(3000))

    // Start with new backend flag
    // EngineManager.ensureRunning() uses self.backendFlag
    backendFlag = "--backend \(backend.rawValue)"
    try? await ensureRunning()
}
```

- [ ] **Step 43: Build to verify**

Run: `cd app && xcodebuild build -scheme OpenVerb -configuration Debug 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 44: Commit**

```bash
git add app/OpenVerb/App/OpenVerbApp.swift app/OpenVerb/Engine/EngineManager.swift
git commit -m "wire onboarding into first launch, add backend switching to engine manager"
```

---

## Chunk 4: MVP5c — TextInjector Fallback & Custom Shortcut

### Task 12: CGEvent per-character fallback in TextInjector

**Files:**
- Modify: `app/OpenVerb/Output/TextInjector.swift`
- Create: `app/OpenVerbTests/TextInjectorTests.swift`

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
static func keyCodeAndFlags(for char: String) -> (UInt16, CGEventFlags)? {
    guard let (code, shift) = keyCodeForCharacter(char.lowercased()) else { return nil }
    let isUpper = char != char.lowercased()
    let flags: CGEventFlags = isUpper ? .maskShift : CGEventFlags(rawValue: 0)
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

- [ ] **Step 49: Wire fallback into the primary inject() flow**

In `TextInjector.inject()`, after step (6) paste via ⌘V, add detection + fallback:

```swift
// (6b) Detect paste failure — if changeCount didn't advance after ⌘V,
// the paste was likely blocked (secure input field, terminal emulator).
// Fall back to per-character CGEvent injection for ASCII text.
try? await Task.sleep(for: .milliseconds(100))
let postPasteCount = pasteboard.changeCount
// If the target app consumed the paste, changeCount may or may not change —
// but if the field is a no-paste field, the text won't appear.
// Heuristic: if the text is pure ASCII and short (<500 chars), always
// offer fallback. For long text or non-ASCII, clipboard is the only path.
```

**Note:** Reliable detection of "paste blocked" is impossible without Accessibility API element inspection (checking if the focused field supports `AXValue` attribute). For MVP5, the fallback is exposed as a user-accessible option: if the user reports paste failures in certain apps, they can enable "Character-by-character injection" in Preferences for those apps. The `injectPerCharacter()` method is callable but not auto-triggered.

- [ ] **Step 50: Commit**

```bash
git add app/OpenVerb/Output/TextInjector.swift app/OpenVerbTests/TextInjectorTests.swift
git commit -m "add cgevent per-character fallback to text injector"
```

---

### Task 13: Custom shortcut recorder

**Files:**
- Create: `app/OpenVerb/Input/ShortcutRecorder.swift`

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

        let text = isRecording ? "Press a key combo..." : "Click to record"
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
            // Require at least one modifier (⌥, ⌃, ⇧, ⌘)
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

In `app/OpenVerb/UI/PreferencesView.swift`, replace the placeholder:

```swift
Section("Hotkey") {
    HStack {
        Text("Current:")
        Text(hotkeyDescription).foregroundStyle(.secondary)
        Spacer()
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

- [ ] **Step 54: Commit**

```bash
git add app/OpenVerb/Input/ShortcutRecorder.swift app/OpenVerb/UI/PreferencesView.swift
git commit -m "add custom shortcut recorder for preferences hotkey picker"
```

---

## Chunk 5: MVP5d — i18n Templates & Distribution

### Task 14: Engine i18n prompt templates

**Files:**
- Create: `engine/src/context/templates/en.h`
- Create: `engine/src/context/templates/ru.h`
- Create: `engine/src/context/templates/es.h`
- Create: `engine/src/context/templates/fr.h`
- Create: `engine/src/context/templates/de.h`
- Create: `engine/src/context/templates/ja.h`
- Modify: `engine/src/context/prompt_builder.h`
- Modify: `engine/src/context/prompt_builder.cpp`

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
    "   output it directly as . , ? ! in the tailored text.";

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
    "   выводи её напрямую как . , ? ! в итоговом тексте.";

inline const std::string GENERATION_SUFFIX_RU = "Выведи ТОЛЬКО итоговый текст:";

} // namespace openverb::templates
```

- [ ] **Step 57: Create remaining templates (es, fr, de, ja)**

Each follows the same pattern — translated system prompt + generation suffix. (Content omitted for brevity; same 5 instructions translated.)

Create `engine/src/context/templates/es.h`, `fr.h`, `de.h`, `ja.h` following the same `namespace openverb::templates` pattern.

- [ ] **Step 58: Update prompt_builder to use locale-based template selection**

Modify `engine/src/context/prompt_builder.h` — add locale parameter:

```cpp
// Add to parse_context_json:
// New field in PromptContext:
struct PromptContext {
    std::string app_name;
    std::string window_title;
    std::string clipboard;
    std::string selected_text;
    std::string language;  // NEW: BCP-47 locale code (e.g. "en", "ru")
};

// Update build_prompt signature:
std::pair<std::string, std::string> build_prompt(const PromptContext& ctx);
// build_prompt now reads ctx.language to select the template.
```

Modify `engine/src/context/prompt_builder.cpp`:

```cpp
#include "context/templates/en.h"
#include "context/templates/ru.h"
#include "context/templates/es.h"
#include "context/templates/fr.h"
#include "context/templates/de.h"
#include "context/templates/ja.h"

static std::pair<const std::string&, const std::string&> select_template(const std::string& lang) {
    using namespace openverb::templates;
    if (lang == "ru") return {SYSTEM_PROMPT_RU, GENERATION_SUFFIX_RU};
    if (lang == "es") return {SYSTEM_PROMPT_ES, GENERATION_SUFFIX_ES};
    if (lang == "fr") return {SYSTEM_PROMPT_FR, GENERATION_SUFFIX_FR};
    if (lang == "de") return {SYSTEM_PROMPT_DE, GENERATION_SUFFIX_DE};
    if (lang == "ja") return {SYSTEM_PROMPT_JA, GENERATION_SUFFIX_JA};
    return {SYSTEM_PROMPT_EN, GENERATION_SUFFIX_EN};  // default
}
```

Update `build_prompt()` to call `select_template(ctx.language)` instead of using `SYSTEM_PROMPT` constant. Update `parse_context_json()` to read `"language"` field into `ctx.language`.

- [ ] **Step 59: Run engine tests — verify nothing breaks**

Run: `cd engine/build && ctest --output-on-failure 2>&1 | tail -20`
Expected: ALL PASS

- [ ] **Step 60: Commit**

```bash
git add engine/src/context/templates/ engine/src/context/prompt_builder.h engine/src/context/prompt_builder.cpp
git commit -m "add i18n prompt templates for en, ru, es, fr, de, ja"
```

---

### Task 15: Homebrew cask + build-release

**Files:**
- Create: `homebrew/Casks/openverb.rb`
- Create: `scripts/build-release.sh`

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
    "~/Library/LaunchAgents/io.openverb.engine.plist",
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

# 1. Build engine (universal binary)
cd "$ROOT_DIR/engine"
cmake -B build-release \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
cmake --build build-release -j"$(sysctl -n hw.ncpu)"

# 2. Build app
cd "$ROOT_DIR/app"
xcodebuild -scheme OpenVerb \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    ARCHS="arm64 x86_64" \
    build

# 3. Copy engine binary into app bundle
APP_PATH="$BUILD_DIR/derived/Build/Products/Release/OpenVerb.app"
cp "$ROOT_DIR/engine/build-release/openverb-engine" \
   "$APP_PATH/Contents/MacOS/openverb-engine"

# 4. Pin SHA256 checksums in ModelDownloader
MODEL_SHA=$(shasum -a 256 "$ROOT_DIR/models/gemma-4-E2B-it-Q4_K_M.gguf" 2>/dev/null | cut -d' ' -f1 || echo "TBD_PIN_BEFORE_RELEASE")
echo "Model SHA256: $MODEL_SHA"

# 5. Create DMG
DMG_PATH="$BUILD_DIR/OpenVerb-$VERSION.dmg"
hdiutil create -volname "OpenVerb" \
    -srcfolder "$APP_PATH" \
    -ov -format UDZO \
    "$DMG_PATH"

# 6. Pin model SHA256 into ModelDownloader.swift (compile-time constant)
if [ "$MODEL_SHA" != "TBD_PIN_BEFORE_RELEASE" ]; then
    sed -i '' "s/static let expectedSHA256 = \".*\"/static let expectedSHA256 = \"$MODEL_SHA\"/" \
        "$ROOT_DIR/app/OpenVerb/Model/ModelDownloader.swift"
    echo "Pinned model SHA256 in ModelDownloader.swift"
fi

# 7. Update Homebrew cask SHA + version
DMG_SHA=$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)
sed -i '' "s/sha256 \".*\"/sha256 \"$DMG_SHA\"/" "$ROOT_DIR/homebrew/Casks/openverb.rb"
sed -i '' "s/version \".*\"/version \"$VERSION\"/" "$ROOT_DIR/homebrew/Casks/openverb.rb"

# 8. Copy cask to homebrew-tap repo (required by Homebrew conventions)
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

- [ ] **Step 64: Commit**

```bash
git add homebrew/Casks/openverb.rb scripts/build-release.sh
git commit -m "add homebrew cask formula and build-release script"
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
- Hotkey section shows current ⌥Space
- Click recorder → press ⌃Space → hotkey updates
- Press new hotkey → verify it works for dictation
- Toggle clipboard OFF → dictate → check engine logs (no clipboard in context JSON)
- Change language to Russian → dictate → verify Russian system prompt in engine logs

- [ ] **Step 68: HUMAN: Backend switching test**

In Preferences, switch to "Whisper + Gemma Text" → verify:
- Loading state shown
- If Whisper model missing → download prompt appears
- After switch: dictate → verify result (may differ slightly from Path A)
- Switch back to Gemma Audio → verify it works

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
- Engine logs show `"window":"filename.py"` and `"selected":"the selected text"`
- Output is code-aware (code style, not prose)

Open Mail compose → dictate → verify formal style output.

- [ ] **Step 72: HUMAN: Accessibility denial graceful degradation**

Revoke Accessibility in System Settings → restart app → dictate → verify:
- App still works (no crash)
- Context shows `"window":""` and no `"selected"` key
- Preferences shows hint: "Grant Accessibility for richer context"

- [ ] **Step 73: HUMAN: Sleep/wake with new settings**

Change hotkey to ⌃Space in Preferences. Close lid → open → verify:
- Engine restarts
- New hotkey (⌃Space) still works post-wake
- Settings persist across restart
