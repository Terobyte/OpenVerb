import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// AudioPipelineTests — state machine contract for AudioPipeline.
//
// Phase 5 scaffold tests (steps 24-27):
//   testInitialStateIsIdle          — freshly constructed pipeline is .idle
//   testBeginRecordingTransitionsToCapturing — beginRecording → .capturing
//   testBeginRecordingReturnsHandle — beginRecording returns a non-nil Handle
//   testCancelFromCapturingGoesToIdle — cancel(handle) → .idle
//   testDoubleBeginIsNoOp           — second beginRecording while capturing is ignored
//   testCancelStaleHandleIsNoOp     — cancel with wrong handle does not change state
// ---------------------------------------------------------------------------

@MainActor
final class AudioPipelineTests: XCTestCase {

    // Shared setup
    private var ringBuffer: AudioRingBuffer!
    private var pipeline: AudioPipeline!

    override func setUp() async throws {
        ringBuffer = AudioRingBuffer(capacitySeconds: 300, chunkBytes: 4096, sampleRate: 16_000)
        pipeline = AudioPipeline(ringBuffer: ringBuffer)
    }

    // -----------------------------------------------------------------------
    // MARK: Initial state
    // -----------------------------------------------------------------------

    func testInitialStateIsIdle() {
        XCTAssertEqual(pipeline.state, .idle,
            "freshly constructed AudioPipeline must be .idle")
    }

    // -----------------------------------------------------------------------
    // MARK: beginRecording
    // -----------------------------------------------------------------------

    func testBeginRecordingTransitionsToCapturing() {
        let handle = pipeline.beginRecording(context: [:])
        XCTAssertNotNil(handle)
        XCTAssertEqual(pipeline.state, .capturing,
            "beginRecording must transition state to .capturing")
    }

    func testBeginRecordingReturnsHandle() {
        let h1 = pipeline.beginRecording(context: [:])
        let h2 = pipeline.beginRecording(context: [:])  // second call while capturing
        XCTAssertNotNil(h1, "first beginRecording must return a handle")
        // second call while not idle must return nil (no-op)
        XCTAssertNil(h2, "beginRecording while capturing must return nil (no-op)")
    }

    // -----------------------------------------------------------------------
    // MARK: cancel
    // -----------------------------------------------------------------------

    func testCancelFromCapturingGoesToIdle() {
        let handle = pipeline.beginRecording(context: [:])!
        pipeline.cancel(handle: handle)
        XCTAssertEqual(pipeline.state, .idle,
            "cancel must transition any state → .idle")
    }

    func testDoubleBeginIsNoOp() {
        let h1 = pipeline.beginRecording(context: [:])
        let h2 = pipeline.beginRecording(context: [:])
        XCTAssertNotNil(h1)
        XCTAssertNil(h2,
            "beginRecording while capturing must be a no-op and return nil")
        XCTAssertEqual(pipeline.state, .capturing,
            "state must remain .capturing after no-op second beginRecording")
    }

    func testCancelStaleHandleIsNoOp() {
        let liveHandle = pipeline.beginRecording(context: [:])!
        let staleHandle = AudioRingBuffer.Handle(id: UUID())  // never issued
        pipeline.cancel(handle: staleHandle)
        XCTAssertEqual(pipeline.state, .capturing,
            "cancel with a stale handle must not change state")
        // Cleanup
        pipeline.cancel(handle: liveHandle)
    }
}
