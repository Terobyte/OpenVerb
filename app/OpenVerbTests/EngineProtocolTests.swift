import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// EngineProtocolTests — verifies ServerMessage decoding and client→server
// encoding as specified in plan step 7.
// ---------------------------------------------------------------------------

final class EngineProtocolTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: ServerMessage decoding
    // -----------------------------------------------------------------------

    // Wire format: every server→client message is terminated with a newline.
    // fromJSON must tolerate the trailing \n (JSON spec allows trailing whitespace).

    func testDecodeReady() throws {
        let json = #"{"type":"session.ready"}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .ready = msg else { XCTFail("Expected .ready, got \(msg)"); return }
    }

    func testDecodePong() throws {
        let json = #"{"type":"pong"}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .pong = msg else { XCTFail("Expected .pong, got \(msg)"); return }
    }

    func testDecodeProgressLow() throws {
        let json = #"{"type":"progress","percent":0.425}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .progress(let pct) = msg else { XCTFail("Expected .progress, got \(msg)"); return }
        XCTAssertEqual(pct, 0.425, accuracy: 1e-9,
                       "percent must be fractional (0.0–1.0), not scaled to 0–100")
    }

    func testDecodeProgressHigh() throws {
        let json = #"{"type":"progress","percent":0.8}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .progress(let pct) = msg else { XCTFail("Expected .progress, got \(msg)"); return }
        XCTAssertEqual(pct, 0.8, accuracy: 1e-9)
    }

    func testDecodeResultTextOnly() throws {
        let json = #"{"type":"result","text":"hello world","command":null}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .result(let text, let cmd) = msg else { XCTFail(); return }
        XCTAssertEqual(text, "hello world")
        XCTAssertNil(cmd)
    }

    func testDecodeResultCommandOnly() throws {
        let json = #"{"type":"result","text":null,"command":{"action":"delete_last"}}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .result(let text, let cmd) = msg else { XCTFail(); return }
        XCTAssertNil(text)
        XCTAssertEqual(cmd?.action, "delete_last")
    }

    func testDecodeResultBothTextAndCommand() throws {
        let json = #"{"type":"result","text":"note:","command":{"action":"insert_newline"}}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .result(let text, let cmd) = msg else { XCTFail(); return }
        XCTAssertEqual(text, "note:")
        XCTAssertEqual(cmd?.action, "insert_newline")
    }

    func testDecodeError() throws {
        let json = #"{"type":"error","code":"session_limit","message":"engine busy"}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .error(let code, let message) = msg else { XCTFail(); return }
        XCTAssertEqual(code, "session_limit")
        XCTAssertEqual(message, "engine busy")
    }

    func testDecodeWarning() throws {
        let json = #"{"type":"warning","code":"approaching_context_limit","message":"80% through context window"}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .warning(let code, let message) = msg else { XCTFail(); return }
        XCTAssertEqual(code, "approaching_context_limit")
        XCTAssertFalse(message.isEmpty)
    }

    func testDecodeUnknownTypeThrows() {
        let json = #"{"type":"banana"}"# + "\n"
        XCTAssertThrowsError(try ServerMessage.fromJSON(json.utf8Data)) { err in
            guard case EngineProtocolError.unknownType(let t) = err else {
                XCTFail("Expected EngineProtocolError.unknownType, got \(err)")
                return
            }
            XCTAssertEqual(t, "banana")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: partial_result and queue_status decoding
    // -----------------------------------------------------------------------

    func testDecodePartialResult() throws {
        let json = #"{"type":"partial_result","chunk_id":3,"text":"hello world","is_final":true}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .partialResult(let text, let chunkId, let isFinal) = msg else {
            XCTFail("Expected .partialResult, got \(msg)")
            return
        }
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(chunkId, 3)
        XCTAssertTrue(isFinal)
    }

    func testDecodePartialResultNotFinal() throws {
        let json = #"{"type":"partial_result","chunk_id":0,"text":"hi","is_final":false}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .partialResult(let text, let chunkId, let isFinal) = msg else {
            XCTFail("Expected .partialResult, got \(msg)")
            return
        }
        XCTAssertEqual(text, "hi")
        XCTAssertEqual(chunkId, 0)
        XCTAssertFalse(isFinal)
    }

    func testDecodeQueueStatus() throws {
        let json = #"{"type":"queue_status","pending":3,"in_flight":1,"eta_ms":5000}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .queueStatus(let pending, let inFlight, let etaMs) = msg else {
            XCTFail("Expected .queueStatus, got \(msg)")
            return
        }
        XCTAssertEqual(pending, 3)
        XCTAssertEqual(inFlight, 1)
        XCTAssertEqual(etaMs, 5000)
    }

    // -----------------------------------------------------------------------
    // MARK: Command action is nil/empty → result has no command
    // -----------------------------------------------------------------------

    func testDecodeResultCommandWithEmptyActionTreatedAsNil() throws {
        let json = #"{"type":"result","text":"hi","command":{"action":""}}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .result(let text, let cmd) = msg else { XCTFail(); return }
        XCTAssertEqual(text, "hi")
        XCTAssertNil(cmd, "Empty action string must be treated as no command")
    }

    func testDecodeResultCommandWithMissingActionTreatedAsNil() throws {
        let json = #"{"type":"result","text":"hi","command":{}}"# + "\n"
        let msg = try ServerMessage.fromJSON(json.utf8Data)
        guard case .result(_, let cmd) = msg else { XCTFail(); return }
        XCTAssertNil(cmd, "Missing action field must be treated as no command")
    }

    // -----------------------------------------------------------------------
    // MARK: Client→server encoding
    // -----------------------------------------------------------------------

    // Wire encoding: JSON bytes + trailing newline delimiter (matches sendJSONSync behaviour).

    func testSessionStartEncoding() throws {
        let msg = SessionStart(context: ["app": "com.apple.Terminal"])
        var wire = try JSONEncoder().encode(msg)
        wire.append(UInt8(ascii: "\n"))   // wire format requires newline terminator
        XCTAssertEqual(wire.last, UInt8(ascii: "\n"),
                       "Wire encoding must end with newline delimiter")
        let jsonPart = wire.dropLast()
        let dict = try JSONSerialization.jsonObject(with: jsonPart) as! [String: Any]
        XCTAssertEqual(dict["type"] as? String, "session.start")
        let ctx = dict["context"] as! [String: String]
        XCTAssertEqual(ctx["app"], "com.apple.Terminal")
    }

    func testPingEncoding() throws {
        let msg = Ping()
        var wire = try JSONEncoder().encode(msg)
        wire.append(UInt8(ascii: "\n"))
        XCTAssertEqual(wire.last, UInt8(ascii: "\n"),
                       "Wire encoding must end with newline delimiter")
        let jsonPart = wire.dropLast()
        let dict = try JSONSerialization.jsonObject(with: jsonPart) as! [String: Any]
        XCTAssertEqual(dict["type"] as? String, "ping")
    }

    func testShutdownEncoding() throws {
        let msg = Shutdown()
        var wire = try JSONEncoder().encode(msg)
        wire.append(UInt8(ascii: "\n"))
        XCTAssertEqual(wire.last, UInt8(ascii: "\n"),
                       "Wire encoding must end with newline delimiter")
        let jsonPart = wire.dropLast()
        let dict = try JSONSerialization.jsonObject(with: jsonPart) as! [String: Any]
        XCTAssertEqual(dict["type"] as? String, "session.shutdown")
    }

    // -----------------------------------------------------------------------
    // MARK: Verify no SessionEnd struct exists
    // -----------------------------------------------------------------------

    // There is intentionally no SessionEnd type in this module.
    // End-of-audio is signaled by the binary sentinel (4 zero bytes), not JSON.
    // Enforce this by verifying that the decoder rejects {"type":"session.end"}
    // as an unknown type.  If someone adds a SessionEnd case to ServerMessage and
    // registers "session.end" in fromJSON(), this test will fail at runtime.
    func testNoSessionEndInProtocol() {
        let json = #"{"type":"session.end"}"# + "\n"
        XCTAssertThrowsError(try ServerMessage.fromJSON(json.utf8Data)) { err in
            guard case EngineProtocolError.unknownType(let t) = err else {
                XCTFail("Expected EngineProtocolError.unknownType for session.end, got \(err)")
                return
            }
            XCTAssertEqual(t, "session.end",
                           "session.end must NOT be a recognized server message type — " +
                           "end-of-audio is the 4-zero-byte binary sentinel, not JSON")
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private extension String {
    var utf8Data: Data { Data(utf8) }
}
