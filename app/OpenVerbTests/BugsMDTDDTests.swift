import XCTest
import AppKit
@testable import OpenVerb

// ---------------------------------------------------------------------------
// BugsMDTDDTests — TDD tests proving bugs from bugs.md.
//
// Each test describes CORRECT expected behaviour and FAILS because the bug
// exists.  After fixes, all tests here should PASS.
//
// Already-fixed bugs (no failing test possible):
//   Bug 1  — CGEvent tap: passRetained → fixed to passUnretained
//   Bug 4  — recordingWindow.show() before audio start → fixed order
//   Bug 6  — unload_model + inference race → fixed with engine_mutex_
//   Bug 11 — truncateToUTF8Bytes over-striping → fixed with sequence-length
//
// Untestable without full runtime (model, hardware, IPC):
//   Bug 2  — EngineClient disconnect() fd race (needs real socket)
//   Bug 7  — server.cpp raw `this` in GCD (needs server lifecycle)
//   Bug 8  — session inference_thread_ gap (needs model + full session)
//   Bug 9  — shared RecvBuffer (design concern, not a code error)
//   Bug 12 — StatusBarItem no animation (UI, needs real NSStatusBar)
//   Bug 13 — shutdown() blocks MainActor (mitigated by Task.detached)
// ---------------------------------------------------------------------------

final class BugsMDTDDTests: XCTestCase {

    // =======================================================================
    // Bug 11 (was): truncateToUTF8Bytes over-stripping.
    //
    // These tests now PASS, confirming the fix in ContextBuilder.swift:83-109
    // correctly checks sequence length before removing a leading byte.
    // They remain as regression guards.
    // =======================================================================

    func testBug11_regression_2ByteCharAtLimit() {
        let result = ContextBuilder.truncateToUTF8Bytes("éa", limit: 2)
        XCTAssertEqual(result, "é")
    }

    func testBug11_regression_3ByteCharAtLimit() {
        let result = ContextBuilder.truncateToUTF8Bytes("€a", limit: 3)
        XCTAssertEqual(result, "€")
    }

    func testBug11_regression_4ByteCharAtLimit() {
        let result = ContextBuilder.truncateToUTF8Bytes("😂a", limit: 4)
        XCTAssertEqual(result, "😂")
    }

    func testBug11_incompleteLeadingByteIsStripped() {
        let result = ContextBuilder.truncateToUTF8Bytes("abécd", limit: 3)
        XCTAssertEqual(result, "ab")
    }
}
