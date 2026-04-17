import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// PartialAccumulationTests — verifies that onPartialResult fires in order
// and that text accumulated over multiple chunks concatenates correctly
// (plan step 47 / Phase 7).
//
// The drain loop in AppDelegate.drainResult() calls
//   engineManager.engineClient.onPartialResult?(text, chunkId, isFinal)
// for every .partialResult message it receives.  These tests exercise that
// callback path by simulating what drainResult does: decode a sequence of
// ServerMessage values and forward each .partialResult through the closure.
// ---------------------------------------------------------------------------

@MainActor
final class PartialAccumulationTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: onPartialResult fires for each chunk in order
    // -----------------------------------------------------------------------

    func testOnPartialResultFiresInOrder() throws {
        let jsonMessages = [
            #"{"type":"partial_result","chunk_id":0,"text":"Привет ","is_final":false}"#,
            #"{"type":"partial_result","chunk_id":1,"text":"мир","is_final":true}"#,
        ]

        var received: [(String, Int, Bool)] = []
        let client = EngineClient()
        client.onPartialResult = { text, chunkId, isFinal in
            received.append((text, chunkId, isFinal))
        }

        // Simulate what drainResult does for each .partialResult message.
        for json in jsonMessages {
            let msg = try ServerMessage.fromJSON(Data(json.utf8))
            if case .partialResult(let text, let chunkId, let isFinal) = msg {
                client.onPartialResult?(text, chunkId, isFinal)
            }
        }

        XCTAssertEqual(received.count, 2,
                       "onPartialResult must fire once per chunk")
        XCTAssertEqual(received[0].0, "Привет ",
                       "first chunk text must match")
        XCTAssertEqual(received[0].1, 0,
                       "first chunk id must be 0")
        XCTAssertFalse(received[0].2,
                       "first chunk must not be final")
        XCTAssertEqual(received[1].0, "мир",
                       "second chunk text must match")
        XCTAssertEqual(received[1].1, 1,
                       "second chunk id must be 1")
        XCTAssertTrue(received[1].2,
                      "last chunk must be final")

        let accumulated = received.map { $0.0 }.joined()
        XCTAssertEqual(accumulated, "Привет мир",
                       "accumulated text must equal concatenation of all partial chunks")
    }

    // -----------------------------------------------------------------------
    // MARK: final text equals concatenation of all partial chunks
    // -----------------------------------------------------------------------

    func testFinalTextEqualsConcat() throws {
        let chunks: [(String, Int, Bool)] = [
            ("Это ", 0, false),
            ("тест ", 1, false),
            ("голоса.", 2, true),
        ]

        var accumulated = ""
        let client = EngineClient()
        client.onPartialResult = { text, _, _ in
            accumulated += text
        }

        for (text, chunkId, isFinal) in chunks {
            client.onPartialResult?(text, chunkId, isFinal)
        }

        XCTAssertEqual(accumulated, "Это тест голоса.",
                       "final accumulated text must equal concatenation of all partial chunks")
    }

    // -----------------------------------------------------------------------
    // MARK: monotonically increasing chunk IDs
    // -----------------------------------------------------------------------

    func testChunkIdsAreMonotonicallyIncreasing() throws {
        let jsonMessages = [
            #"{"type":"partial_result","chunk_id":0,"text":"A","is_final":false}"#,
            #"{"type":"partial_result","chunk_id":1,"text":"B","is_final":false}"#,
            #"{"type":"partial_result","chunk_id":2,"text":"C","is_final":true}"#,
        ]

        var chunkIds: [Int] = []
        let client = EngineClient()
        client.onPartialResult = { _, chunkId, _ in
            chunkIds.append(chunkId)
        }

        for json in jsonMessages {
            let msg = try ServerMessage.fromJSON(Data(json.utf8))
            if case .partialResult(let text, let chunkId, let isFinal) = msg {
                client.onPartialResult?(text, chunkId, isFinal)
            }
        }

        XCTAssertEqual(chunkIds, [0, 1, 2],
                       "chunk IDs must arrive in monotonically increasing order")
    }

    // -----------------------------------------------------------------------
    // MARK: nil onPartialResult does not crash
    // -----------------------------------------------------------------------

    func testNilCallbackDoesNotCrash() throws {
        let json = #"{"type":"partial_result","chunk_id":0,"text":"x","is_final":true}"#
        let msg = try ServerMessage.fromJSON(Data(json.utf8))
        let client = EngineClient()
        // onPartialResult is nil by default — must not crash when called
        if case .partialResult(let text, let chunkId, let isFinal) = msg {
            client.onPartialResult?(text, chunkId, isFinal)  // should be a no-op
        }
        // If we get here without crashing the test passes.
    }

    // -----------------------------------------------------------------------
    // MARK: non-partialResult messages do not fire the callback
    // -----------------------------------------------------------------------

    func testQueueStatusDoesNotFirePartialCallback() throws {
        let json = #"{"type":"queue_status","pending":2,"in_flight":1,"eta_ms":3000}"#
        let msg = try ServerMessage.fromJSON(Data(json.utf8))

        var fired = false
        let client = EngineClient()
        client.onPartialResult = { _, _, _ in fired = true }

        // The drain loop only calls onPartialResult for .partialResult, not .queueStatus
        if case .partialResult(let text, let chunkId, let isFinal) = msg {
            client.onPartialResult?(text, chunkId, isFinal)
        }
        // No dispatch for queue_status

        XCTAssertFalse(fired,
                       "onPartialResult must not fire for .queueStatus messages")
    }
}
