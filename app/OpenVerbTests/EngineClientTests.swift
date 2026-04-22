import XCTest
@testable import OpenVerb

final class EngineClientTests: XCTestCase {

    // MARK: initial state

    func testInitialIsConnectedFalse() {
        let client = EngineClient()
        XCTAssertFalse(client.isConnected)
    }

    func testCheckPhase2ErrorInitiallyNil() {
        let client = EngineClient()
        XCTAssertNil(client.checkPhase2Error())
    }

    func testCallbacksInitiallyNil() {
        let client = EngineClient()
        XCTAssertNil(client.onError)
        XCTAssertNil(client.onPartialResult)
        XCTAssertNil(client.onQueueStatus)
        XCTAssertNil(client.onPolishedResult)
    }

    // MARK: safe no-op operations on disconnected client

    func testSendAudioFrameEmptyDataIsNoOp() {
        let client = EngineClient()
        // Guard: data.count > 0 — empty data returns immediately, no crash
        client.sendAudioFrame(Data())
    }

    func testSendAudioFrameNonEmptyWhenDisconnectedIsNoOp() {
        let client = EngineClient()
        // fd == -1 → ioQueue block exits immediately via guard fd >= 0
        client.sendAudioFrame(Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    func testSendEndOfAudioWhenDisconnectedIsNoOp() {
        let client = EngineClient()
        client.sendEndOfAudio()
    }

    func testDisconnectWhenNotConnectedIsNoOp() {
        let client = EngineClient()
        client.disconnect()
        XCTAssertFalse(client.isConnected)
    }

    func testSendShutdownWhenNotConnectedIsNoOp() {
        let client = EngineClient()
        client.sendShutdown()
    }

    func testSyncOnIOQueueDoesNotCrash() {
        let client = EngineClient()
        client.syncOnIOQueue()
    }

    func testStopPhase2MonitorWhenNotStartedIsNoOp() {
        let client = EngineClient()
        client.stopPhase2Monitor()
        // still not connected, no phase2 error
        XCTAssertNil(client.checkPhase2Error())
    }

    // MARK: EngineClientError descriptions

    func testErrorDescriptionNotConnected() {
        let e = EngineClientError.notConnected
        XCTAssertEqual(e.description, "not connected to engine")
    }

    func testErrorDescriptionConnectionFailed() {
        let e = EngineClientError.connectionFailed(111)
        XCTAssertTrue(e.description.contains("111"))
    }

    func testErrorDescriptionConnectionClosed() {
        let e = EngineClientError.connectionClosed
        XCTAssertEqual(e.description, "connection closed by engine")
    }

    func testErrorDescriptionTimeout() {
        let e = EngineClientError.timeout
        XCTAssertEqual(e.description, "timed out waiting for engine")
    }

    func testErrorDescriptionWriteFailed() {
        let e = EngineClientError.writeFailed(32)
        XCTAssertTrue(e.description.contains("32"))
    }

    func testErrorDescriptionProtocolViolation() {
        let e = EngineClientError.protocolViolation
        XCTAssertTrue(e.description.contains("protocol violation"))
    }

    func testErrorDescriptionSystemError() {
        let e = EngineClientError.systemError(errno: 2)
        XCTAssertTrue(e.description.contains("2"))
    }

    func testErrorDescriptionUnexpectedMessage() {
        let e = EngineClientError.unexpectedMessage(.pong)
        XCTAssertTrue(e.description.contains("unexpected message"))
    }

    func testErrorDescriptionEngineError() {
        let e = EngineClientError.engineError("E001", "something went wrong")
        XCTAssertTrue(e.description.contains("E001"))
        XCTAssertTrue(e.description.contains("something went wrong"))
    }

    // MARK: Bug 174 — concurrent read / socketReadLock serialization
    //
    // Bug 28/147 fix uses socketReadLock to serialize poll()+read() inside
    // recvJSONSync so Phase 2 monitor and drainResult cannot split a single
    // JSON frame across two readers. Full exercise requires a real fd pair;
    // these tests verify the lock and ioQueue invariants hold under the
    // disconnected-state operations that race on the same internal state.

    func testBug174_concurrentIsConnectedReadsAreSafe() {
        let client = EngineClient()
        let exp = expectation(description: "concurrent isConnected reads")
        exp.expectedFulfillmentCount = 16
        for _ in 0..<16 {
            DispatchQueue.global().async {
                XCTAssertFalse(client.isConnected)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testBug174_concurrentDisconnectedOperationsDoNotCrash() {
        // Exercises the guard fd >= 0 barrier inside ioQueue blocks under load.
        // All callers hit the same fd/recvBuffer state; socketReadLock plus the
        // serial ioQueue must keep this safe even with bursty parallel calls.
        let client = EngineClient()
        let exp = expectation(description: "concurrent ops on disconnected client")
        exp.expectedFulfillmentCount = 32
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        for i in 0..<32 {
            DispatchQueue.global().async {
                switch i % 4 {
                case 0: client.sendAudioFrame(payload)
                case 1: client.sendEndOfAudio()
                case 2: client.disconnect()
                default: client.sendShutdown()
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5.0)
        XCTAssertFalse(client.isConnected)
    }

    func testBug174_syncOnIOQueueFromMultipleThreads() {
        // syncOnIOQueue() forces a barrier on the serial ioQueue. Calling it
        // from multiple threads must not deadlock or crash.
        let client = EngineClient()
        let exp = expectation(description: "concurrent syncOnIOQueue")
        exp.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            DispatchQueue.global().async {
                client.syncOnIOQueue()
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 3.0)
    }

    func testBug174_stopPhase2MonitorIsSafeWhenNotStarted() {
        // drainResult → phase2 handoff may be aborted before Phase 2 monitor
        // ever starts. stopPhase2Monitor must tolerate that without touching
        // the lock in a bad state.
        let client = EngineClient()
        client.stopPhase2Monitor()
        client.stopPhase2Monitor()
        XCTAssertNil(client.checkPhase2Error())
    }
}
