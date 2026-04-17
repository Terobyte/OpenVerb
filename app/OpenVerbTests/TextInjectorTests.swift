import XCTest
@testable import OpenVerb

final class TextInjectorTests: XCTestCase {

    func testCharacterToKeyCodeMappingCoversASCII() {
        XCTAssertNotNil(TextInjector.keyCodeForCharacter("a"))
        XCTAssertNotNil(TextInjector.keyCodeForCharacter(" "))
        XCTAssertNotNil(TextInjector.keyCodeForCharacter("."))
    }

    func testShiftFlagForUppercase() {
        let result = TextInjector.keyCodeAndFlags(for: "A")
        XCTAssertNotNil(result)
        let (keyCode, flags) = result!
        XCTAssertEqual(keyCode, TextInjector.keyCodeForCharacter("a")!.0)
        XCTAssertTrue(flags.contains(.maskShift))
    }

    func testNilForUnsupportedCharacter() {
        // CGEvent fallback cannot type CJK — returns nil
        XCTAssertNil(TextInjector.keyCodeForCharacter("漢"))
    }
}
