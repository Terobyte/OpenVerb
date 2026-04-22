import XCTest
@testable import OpenVerb

final class AudioSessionTests: XCTestCase {

    // MARK: initial state invariants

    func testInitialIsCapturingFalse() {
        let session = AudioSession()
        XCTAssertFalse(session.isCapturing)
    }

    func testFlushPreBufferInitiallyEmpty() {
        let session = AudioSession()
        let flushed = session.flushPreBuffer()
        XCTAssertTrue(flushed.isEmpty)
    }

    func testCommitSendCallbackInitiallyReturnsEmpty() {
        let session = AudioSession()
        let interim = session.commitSendCallback { _ in }
        XCTAssertTrue(interim.isEmpty)
    }

    func testStopWhenNotCapturingIsNoOp() {
        let session = AudioSession()
        // Guard: guard _isCapturing else { return } — must not crash
        session.stop()
        XCTAssertFalse(session.isCapturing)
    }

    func testStopIsIdempotent() {
        let session = AudioSession()
        session.stop()
        session.stop()
        XCTAssertFalse(session.isCapturing)
    }

    func testFlushAfterCommitReturnsEmpty() {
        let session = AudioSession()
        _ = session.commitSendCallback { _ in }
        let flushed = session.flushPreBuffer()
        XCTAssertTrue(flushed.isEmpty)
    }

    // MARK: AudioSessionError descriptions

    func testErrorDescriptionPermissionDenied() {
        let e = AudioSessionError.permissionDenied
        XCTAssertEqual(e.description, "Microphone permission denied")
    }

    func testErrorDescriptionFormatError() {
        let e = AudioSessionError.formatError
        XCTAssertTrue(e.description.contains("16 kHz"))
    }

    func testErrorDescriptionConverterError() {
        let e = AudioSessionError.converterError
        XCTAssertTrue(e.description.contains("AVAudioConverter"))
    }

    // MARK: AudioSessionError is Error

    func testAudioSessionErrorIsError() {
        let e: Error = AudioSessionError.permissionDenied
        XCTAssertNotNil(e)
    }

    // MARK: Bug 173 — pre-buffer / flush / commit coverage
    //
    // Covers the Bug 32/141/142/146/172 contract: flushPreBuffer drains and
    // returns atomically, commitSendCallback installs the live path atomically,
    // stop() clears state, and sessionGeneration is readable from any thread
    // without deadlock (Bug 172).

    func testBug173_sessionGenerationInitiallyZero() {
        let session = AudioSession()
        XCTAssertEqual(session.sessionGeneration, 0,
            "fresh AudioSession must have sessionGeneration == 0 before any start()")
    }

    func testBug173_repeatedFlushIsIdempotent() {
        let session = AudioSession()
        XCTAssertTrue(session.flushPreBuffer().isEmpty)
        XCTAssertTrue(session.flushPreBuffer().isEmpty)
        XCTAssertTrue(session.flushPreBuffer().isEmpty)
    }

    func testBug173_flushThenCommitReturnsEmptyInterim() {
        // Bug 32 fix: flushPreBuffer returns buffered frames; commitSendCallback
        // returns any interim frames arrived between the two calls. On a cold
        // session (no audio thread running) the interim slice must be empty.
        let session = AudioSession()
        _ = session.flushPreBuffer()
        let interim = session.commitSendCallback { _ in }
        XCTAssertTrue(interim.isEmpty,
            "commitSendCallback must return empty interim on cold session")
    }

    func testBug173_commitReplacesCallbackWithoutCrash() {
        // Second commit must replace the first callback cleanly.
        let session = AudioSession()
        _ = session.commitSendCallback { _ in }
        _ = session.commitSendCallback { _ in }
        XCTAssertFalse(session.isCapturing)
    }

    func testBug173_stopAfterCommitClearsState() {
        let session = AudioSession()
        _ = session.commitSendCallback { _ in }
        session.stop()
        XCTAssertFalse(session.isCapturing)
        XCTAssertTrue(session.flushPreBuffer().isEmpty,
            "flushPreBuffer after stop must return empty")
    }

    func testBug173_sessionGenerationReadIsThreadSafe() {
        // Bug 172: sessionGeneration getter must be callable from any thread
        // without holding self.lock (would deadlock with stop()).
        let session = AudioSession()
        let exp = expectation(description: "concurrent generation reads")
        exp.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            DispatchQueue.global().async {
                _ = session.sessionGeneration
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2.0)
    }
}
