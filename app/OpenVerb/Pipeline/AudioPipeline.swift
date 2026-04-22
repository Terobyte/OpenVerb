import Foundation
import os

// ---------------------------------------------------------------------------
// AudioPipeline — @MainActor orchestrator for the producer/consumer recording
// session. Owns the state machine and coordinates AudioRingBuffer, AudioSession,
// and EngineClient.
//
// State machine:
//   idle → capturing  (beginRecording)
//   capturing → idle  (cancel)
//   capturing → streaming (internal, once engine is ready — Phase 6)
//   streaming → finalizing (endRecording)
//   finalizing → idle  (result received — Phase 6)
//   any → idle         (cancel)
//   any → error        (engine error — Phase 6)
//
// Phase 5 delivers the state machine scaffold with public lifecycle methods.
// Phase 6 adds the full streamLive consumer coroutine.
//
// Handle lifecycle:
//   • Issued by beginRecording. Invariant: one live handle per pipeline.
//   • Invalidated on transition to idle (cancel / result / error).
//   • Stale handle passed to any method is a no-op (debug log).
//   • beginRecording() called while state ≠ .idle returns nil (no-op).
// ---------------------------------------------------------------------------

private let pipelineLogger = Logger(subsystem: "io.openverb.app", category: "AudioPipeline")

@MainActor
final class AudioPipeline {

    // -----------------------------------------------------------------------
    // MARK: State machine
    // -----------------------------------------------------------------------

    enum State: Equatable {
        case idle
        case capturing
        case streaming
        case finalizing
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.capturing, .capturing),
                 (.streaming, .streaming),
                 (.finalizing, .finalizing):
                return true
            case (.error(let l), .error(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    private(set) var state: State = .idle

    // -----------------------------------------------------------------------
    // MARK: Dependencies
    // -----------------------------------------------------------------------

    private let ringBuffer: AudioRingBuffer
    private var activeHandle: AudioRingBuffer.Handle?

    // Callbacks wired by AppDelegate (Phase 8).
    var onResult: ((_ text: String?, _ command: Command?) -> Void)?
    var onError:  ((_ message: String) -> Void)?

    // -----------------------------------------------------------------------
    // MARK: Initialiser
    // -----------------------------------------------------------------------

    init(ringBuffer: AudioRingBuffer) {
        self.ringBuffer = ringBuffer
    }

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    /// Allocates a fresh Handle, transitions idle → capturing, and returns the
    /// handle.  Returns nil if the pipeline is not currently idle (no-op with
    /// debug log).
    @discardableResult
    func beginRecording(context: [String: String]) -> AudioRingBuffer.Handle? {
        guard state == .idle else {
            pipelineLogger.debug("AudioPipeline.beginRecording ignored: state is \(String(describing: self.state))")
            return nil
        }
        let handle = AudioRingBuffer.Handle(id: UUID())
        activeHandle = handle
        ringBuffer.markStart(handle: handle, timestamp: Date().timeIntervalSinceReferenceDate)
        state = .capturing
        pipelineLogger.info("AudioPipeline: idle → capturing (handle \(handle.id))")
        return handle
    }

    /// Signals end of user speech; transitions streaming → finalizing so the
    /// consumer can drain the buffer tail and send the sentinel.
    /// No-op if the handle is stale or state is not .streaming.
    func endRecording(handle: AudioRingBuffer.Handle) {
        guard handle == activeHandle else {
            pipelineLogger.debug("AudioPipeline.endRecording ignored: stale handle \(handle.id)")
            return
        }
        guard state == .streaming else {
            pipelineLogger.debug("AudioPipeline.endRecording ignored: state is \(String(describing: self.state))")
            return
        }
        ringBuffer.markEnd(handle: handle, timestamp: Date().timeIntervalSinceReferenceDate)
        state = .finalizing
        pipelineLogger.info("AudioPipeline: streaming → finalizing (handle \(handle.id))")
    }

    /// Cancels the current session: any state → idle. Buffer is cleared.
    /// No-op if the handle is stale.
    func cancel(handle: AudioRingBuffer.Handle) {
        guard handle == activeHandle else {
            pipelineLogger.debug("AudioPipeline.cancel ignored: stale handle \(handle.id)")
            return
        }
        let prev = state
        ringBuffer.clear(handle: handle)
        activeHandle = nil
        state = .idle
        pipelineLogger.info("AudioPipeline: \(String(describing: prev)) → idle via cancel (handle \(handle.id))")
    }
}
