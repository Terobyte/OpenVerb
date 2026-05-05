import XCTest
@testable import OpenVerb

@MainActor
final class PolishStreamingTests: XCTestCase {

    func testAppendPolishedTextLiftsFromNil() {
        let s = AppState()
        XCTAssertNil(s.polishedText, "polishedText must start nil")
        s.appendPolishedText("Hello")
        XCTAssertEqual(s.polishedText, "Hello")
    }

    func testAppendPolishedTextAccumulates() {
        let s = AppState()
        s.appendPolishedText("Hello")
        s.appendPolishedText(", ")
        s.appendPolishedText("world.")
        XCTAssertEqual(s.polishedText, "Hello, world.")
    }

    func testFinalResultReplacesAccumulatedDeltas() {
        let s = AppState()
        s.appendPolishedText("hellow")    // raw token glitch
        s.appendPolishedText(" wrld")
        XCTAssertEqual(s.polishedText, "hellow wrld")
        s.setPolishedText("Hello, world.") // cleaned final replaces
        XCTAssertEqual(s.polishedText, "Hello, world.")
    }

    func testEmptyDeltaIsNoOpAfterValue() {
        let s = AppState()
        s.appendPolishedText("Hi")
        s.appendPolishedText("")
        XCTAssertEqual(s.polishedText, "Hi")
    }

    func testEmptyFirstDeltaLiftsFromNilToEmpty() {
        // UTF-8 holdback may produce an empty delta as the first emitted piece.
        // Lifting nil -> "" is still a valid state transition; the next delta
        // appends as expected.
        let s = AppState()
        s.appendPolishedText("")
        XCTAssertEqual(s.polishedText, "")
        s.appendPolishedText("ok")
        XCTAssertEqual(s.polishedText, "ok")
    }
}
