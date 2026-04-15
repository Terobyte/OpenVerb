import XCTest
import ApplicationServices
@testable import OpenVerb

// ---------------------------------------------------------------------------
// CommandExecutorTests — validates the action-mapping layer of CommandExecutor.
//
// Scope (plan step 20):
//   • Verified: CommandExecutor.action(for:) returns the correct KeyAction
//     tuples for each supported command string.
//   • Not tested: actual CGEvent posting — this requires Accessibility
//     permission and a live display; verified in human-testing phase.
//
// MockEventPoster records postKeyDown calls so callers can verify what would
// have been posted without touching the real HID stream.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// MockEventPoster — records CGEvent post requests for inspection.
// ---------------------------------------------------------------------------

final class MockEventPoster: EventPoster {
    struct Call: Equatable {
        let keyCode: CGKeyCode
        let flags:   CGEventFlags
    }
    private(set) var calls: [Call] = []

    func postKeyDown(virtualKey: CGKeyCode, flags: CGEventFlags) {
        calls.append(Call(keyCode: virtualKey, flags: flags))
    }
}

// ---------------------------------------------------------------------------
// CommandExecutorTests
// ---------------------------------------------------------------------------

final class CommandExecutorTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: delete_last
    // -----------------------------------------------------------------------

    func testDeleteLastIsRecognised() {
        let actions = CommandExecutor.action(for: Command(action: "delete_last"))
        XCTAssertNotNil(actions, "'delete_last' must return a non-nil action list")
    }

    func testDeleteLastMapsToCommandZ() {
        let actions = CommandExecutor.action(for: Command(action: "delete_last"))!
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].keyCode, 6,
                       "keyCode 6 is the Z key (ANSI scan code)")
        XCTAssertEqual(actions[0].flags, CGEventFlags.maskCommand,
                       "delete_last must use .maskCommand (⌘Z)")
    }

    // -----------------------------------------------------------------------
    // MARK: undo
    // -----------------------------------------------------------------------

    func testUndoIsRecognised() {
        let actions = CommandExecutor.action(for: Command(action: "undo"))
        XCTAssertNotNil(actions, "'undo' must return a non-nil action list")
    }

    func testUndoMapsToCommandZ() {
        let actions = CommandExecutor.action(for: Command(action: "undo"))!
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].keyCode, 6)
        XCTAssertEqual(actions[0].flags, CGEventFlags.maskCommand)
    }

    func testDeleteLastAndUndoMapIdentically() {
        let deleteLast = CommandExecutor.action(for: Command(action: "delete_last"))!
        let undo       = CommandExecutor.action(for: Command(action: "undo"))!
        XCTAssertEqual(deleteLast.count, undo.count,
                       "delete_last and undo must produce the same number of key actions")
        XCTAssertEqual(deleteLast[0].keyCode, undo[0].keyCode,
                       "delete_last and undo must map to the same virtual key code")
        XCTAssertEqual(deleteLast[0].flags, undo[0].flags,
                       "delete_last and undo must use the same modifier flags")
    }

    // -----------------------------------------------------------------------
    // MARK: insert_newline
    // -----------------------------------------------------------------------

    func testInsertNewlineIsRecognised() {
        let actions = CommandExecutor.action(for: Command(action: "insert_newline"))
        XCTAssertNotNil(actions, "'insert_newline' must return a non-nil action list")
    }

    func testInsertNewlineMapsToReturn() {
        let actions = CommandExecutor.action(for: Command(action: "insert_newline"))!
        XCTAssertEqual(actions.count, 1,
                       "insert_newline must produce exactly one key action")
        XCTAssertEqual(actions[0].keyCode, 0x24,
                       "keyCode 0x24 (36) is kVK_Return")
        XCTAssertEqual(actions[0].flags, CGEventFlags([]),
                       "insert_newline must use no modifier flags")
    }

    // -----------------------------------------------------------------------
    // MARK: insert_newparagraph
    // -----------------------------------------------------------------------

    func testInsertNewparagraphIsRecognised() {
        let actions = CommandExecutor.action(for: Command(action: "insert_newparagraph"))
        XCTAssertNotNil(actions, "'insert_newparagraph' must return a non-nil action list")
    }

    func testInsertNewparagraphMapsTwoReturns() {
        let actions = CommandExecutor.action(for: Command(action: "insert_newparagraph"))!
        XCTAssertEqual(actions.count, 2,
                       "insert_newparagraph must produce two Return key actions")
        XCTAssertEqual(actions[0].keyCode, 0x24)
        XCTAssertEqual(actions[1].keyCode, 0x24)
        XCTAssertEqual(actions[0].flags, CGEventFlags([]))
        XCTAssertEqual(actions[1].flags, CGEventFlags([]))
    }

    // -----------------------------------------------------------------------
    // MARK: no-op cases
    // -----------------------------------------------------------------------

    func testUnknownCommandIsNoop() {
        let actions = CommandExecutor.action(for: Command(action: "unknown_command"))
        XCTAssertNil(actions,
                     "'unknown_command' must return nil (no-op)")
    }

    func testEmptyActionIsNoop() {
        // Command(action: "") would normally be filtered by EngineProtocol
        // (nil cmd returned for empty action), but CommandExecutor must also
        // be defensive.
        let actions = CommandExecutor.action(for: Command(action: ""))
        XCTAssertNil(actions,
                     "Empty action string must return nil (no-op)")
    }

    // -----------------------------------------------------------------------
    // MARK: MockEventPoster integration
    // -----------------------------------------------------------------------

    func testMockPosterRecordsDeleteLastCall() async throws {
        // Verify the MockEventPoster infrastructure works correctly.
        let mock = MockEventPoster()
        mock.postKeyDown(virtualKey: 6, flags: .maskCommand)
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls[0].keyCode, 6)
        XCTAssertEqual(mock.calls[0].flags, .maskCommand)
    }
}
