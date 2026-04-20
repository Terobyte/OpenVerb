import XCTest
@testable import OpenVerb

final class AppSettingsTests: XCTestCase {

    // Bug 131 fix: generate a unique suite name per test run so no two tests
    // share the same UserDefaults store and order-dependence is eliminated.
    private var suiteName: String = ""

    override func setUp() {
        suiteName = UUID().uuidString
    }

    @MainActor
    func testDefaultHotkeyIsOptionSpace() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(settings.hotkeyKeyCode, 0x31) // Space
        XCTAssertTrue(settings.hotkeyModifiers.contains(.maskAlternate))
    }

    @MainActor
    func testClipboardContextDefaultsToTrue() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertTrue(settings.includeClipboard)
    }

    @MainActor
    func testBackendDefaultsToGemmaAudio() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(settings.backend, .gemmaAudio)
    }

    @MainActor
    func testLanguageDefaultsToSystemLocale() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        let expected = Locale.current.language.languageCode?.identifier ?? "en"
        XCTAssertEqual(settings.language, expected)
    }

    // Bug 130 fix: verify UserDefaults round-trip by reading back from a
    // SECOND AppSettings instance backed by the same suite — this proves the
    // value was actually persisted, not just held in-memory.
    @MainActor
    func testSetAndGetCustomHotkey() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        settings.hotkeyKeyCode = 0x32 // backtick
        settings.hotkeyModifiers = .maskAlternate
        // Create a fresh instance backed by the same suite to test persistence.
        let settings2 = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(settings2.hotkeyKeyCode, 0x32)
    }

    @MainActor
    func testClipboardToggle() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        settings.includeClipboard = false
        XCTAssertFalse(settings.includeClipboard)
    }
}
