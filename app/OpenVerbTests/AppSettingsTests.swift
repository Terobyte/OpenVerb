import XCTest
@testable import OpenVerb

final class AppSettingsTests: XCTestCase {

    override func setUp() {
        // Use a volatile suite so tests don't pollute real UserDefaults.
        UserDefaults.standard.removePersistentDomain(forName: "io.openverb.test")
    }

    @MainActor
    func testDefaultHotkeyIsOptionSpace() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        XCTAssertEqual(settings.hotkeyKeyCode, 0x31) // Space
        XCTAssertTrue(settings.hotkeyModifiers.contains(.maskAlternate))
    }

    @MainActor
    func testClipboardContextDefaultsToTrue() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        XCTAssertTrue(settings.includeClipboard)
    }

    @MainActor
    func testBackendDefaultsToGemmaAudio() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        XCTAssertEqual(settings.backend, .gemmaAudio)
    }

    @MainActor
    func testLanguageDefaultsToSystemLocale() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        let expected = Locale.current.language.languageCode?.identifier ?? "en"
        XCTAssertEqual(settings.language, expected)
    }

    @MainActor
    func testSetAndGetCustomHotkey() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        settings.hotkeyKeyCode = 0x32 // backtick
        settings.hotkeyModifiers = .maskAlternate
        XCTAssertEqual(settings.hotkeyKeyCode, 0x32)
    }

    @MainActor
    func testClipboardToggle() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
        settings.includeClipboard = false
        XCTAssertFalse(settings.includeClipboard)
    }
}
