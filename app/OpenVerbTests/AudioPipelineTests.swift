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
//
// Phase 14 integration test (steps 78-79):
//   testLivePartialTextUpdatesFromPartialResult — onPartialResult → livePartialText wiring
// ---------------------------------------------------------------------------

@MainActor
final class AudioPipelineTests: XCTestCase {

    // Shared setup
    private var ringBuffer: AudioRingBuffer!
    private var pipeline: AudioPipeline!

    override func setUp() async throws {
        ringBuffer = AudioRingBuffer(capacitySeconds: 300, chunkBytes: 4096, sampleRate: 16_000)
        // Phase 6 (step 30): AudioPipeline owns engineClient/engineManager to
        // drive streamLive. We wire a non-routable socketPath so the detached
        // consumer Task fails connect() immediately — the state-machine
        // assertions only inspect synchronous MainActor transitions, so the
        // Task's cleanup (if any) runs after the assertion point.
        let client = EngineClient()
        let manager = EngineManager(
            socketPath: "/tmp/openverb-audiopipelinetests-nonexistent.sock",
            enginePath: "/usr/bin/false",
            client: client
        )
        pipeline = AudioPipeline(
            engineClient: client,
            engineManager: manager,
            ringBuffer: ringBuffer
        )
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

    // -----------------------------------------------------------------------
    // MARK: Bug regression proofs
    // -----------------------------------------------------------------------

    func testProveBug16_staleHandleIsNoOp() {
        // Prove Bug 16: a handle from a previous session cannot cancel the
        // current session. The pipeline's handle-identity check replaces the
        // drainGeneration counter that was needed in OpenVerbApp.swift.
        let oldHandle = pipeline.beginRecording(context: [:])!
        pipeline.cancel(handle: oldHandle)           // session 1 ends → idle

        let newHandle = pipeline.beginRecording(context: [:])!  // session 2 starts
        pipeline.cancel(handle: oldHandle)           // stale cancel: must be no-op

        XCTAssertEqual(pipeline.state, .capturing,
            "Bug 16: stale handle from previous session must not affect active session")
        pipeline.cancel(handle: newHandle)
    }

    func testProveBug81_doubleStopIsNoOp() {
        // Prove Bug 81: endRecording is idempotent — a second call while not
        // in .streaming state returns early, so two concurrent stopRecording
        // callers cannot corrupt the state machine.
        let handle = pipeline.beginRecording(context: [:])!
        pipeline.endRecording(handle: handle)  // no-op: not yet .streaming
        pipeline.endRecording(handle: handle)  // second call: also no-op

        XCTAssertEqual(pipeline.state, .capturing,
            "Bug 81: double endRecording must not corrupt state")
        pipeline.cancel(handle: handle)
    }

    // -----------------------------------------------------------------------
    // MARK: Phase 14 — live subtitle wiring integration test
    // -----------------------------------------------------------------------

    func testLivePartialTextUpdatesFromPartialResult() async {
        // Verify the onPartialResult → AppState.livePartialText wiring works
        // correctly on @MainActor. This test replicates the closure assignment
        // in OpenVerbApp.swift and checks the actor-hopped update.
        let appState = AppState()

        // Replicate the OpenVerbApp wiring: fire a Task { @MainActor } to update livePartialText.
        let client = EngineClient()
        client.onPartialResult = { text, _, _ in
            Task { @MainActor in
                guard appState.state == .inferring || appState.state == .recording else { return }
                appState.livePartialText += text
            }
        }

        // Simulate .recording state so the guard allows updates.
        appState.transition(to: .preparing)
        appState.transition(to: .recording)

        // Fire a simulated partial result.
        client.onPartialResult?("hello ", 1, false)
        client.onPartialResult?("world", 2, true)

        // Yield to allow the @MainActor Task hops to complete.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(appState.livePartialText, "hello world",
            "onPartialResult must update livePartialText via @MainActor hop during .recording")
    }
}
