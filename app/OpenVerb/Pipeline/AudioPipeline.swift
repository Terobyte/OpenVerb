import Foundation
import os

// ---------------------------------------------------------------------------
// AudioPipeline — @MainActor orchestrator for the producer/consumer recording
// session. Owns the state machine and drives the streamLive consumer coroutine.
//
// State machine:
//   idle       → capturing   (beginRecording)
//   capturing  → streaming   (internal: engine ready)
//   streaming  → finalizing  (endRecording — user ⌥Space stop)
//   finalizing → idle        (result received)
//   any        → idle        (cancel)
//   any        → error       (engine error; buffer retained for retry)
//
// Handle lifecycle:
//   • Issued by beginRecording. Invariant: one live handle per pipeline at a time.
//   • Invalidated on transition to idle (result / cancel / error-with-no-retry).
//   • Stale handle passed to any method is a no-op (debug log).
//   • beginRecording() called while state ≠ .idle returns nil (no-op).
//
// Concurrency:
//   • All public methods and state transitions are @MainActor.
//   • streamLive runs in Task.detached(priority: .userInitiated) — not MainActor.
//   • Results are sent back via await MainActor.run { }.
//   • lastSentTimestamp is owned by the streamLive Task (not MainActor) and
//     used on retry to resume from the correct ring-buffer position.
//
// Error recovery:
//   • On engine crash mid-recording, streamLive catches the error, calls
//     engineManager.handleCrash(), then re-connects and resumes sending from
//     lastSentTimestamp. The ring buffer retains audio during the restart window.
// ---------------------------------------------------------------------------

private let pipelineLogger = Logger(subsystem: "io.openverb.app", category: "AudioPipeline")

private enum StreamDrainResult {
    case keepGoing
    case finished(text: String?, command: Command?)
    case failed
}

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
    private let engineClient: EngineClient
    private let engineManager: EngineManager

    /// Active handle for the current session. Nil when idle.
    private var activeHandle: AudioRingBuffer.Handle?

    /// Async closure that produces context for startSession. Injected by AppDelegate.
    /// Called from the streamLive detached Task (not MainActor).
    var contextProvider: (() async -> [String: String])?

    // Callbacks wired by AppDelegate (Phase 8).
    var onResult:    ((_ text: String?, _ command: Command?) -> Void)?
    var onError:     ((_ message: String) -> Void)?
    /// Fires on @MainActor when the engine sends .ready and streaming begins.
    /// AppDelegate uses this to transition AppState → .recording and start the
    /// max-duration timer.
    var onStreaming:  (() -> Void)?

    // -----------------------------------------------------------------------
    // MARK: Initialiser
    // -----------------------------------------------------------------------

    init(engineClient: EngineClient, engineManager: EngineManager,
         ringBuffer: AudioRingBuffer) {
        self.engineClient = engineClient
        self.engineManager = engineManager
        self.ringBuffer   = ringBuffer
    }

    // -----------------------------------------------------------------------
    // MARK: Public API
    // -----------------------------------------------------------------------

    /// Allocates a fresh Handle, transitions idle → capturing, and launches
    /// the streamLive consumer coroutine. Returns the handle, or nil if the
    /// pipeline is not currently idle (no-op with debug log).
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

        // Capture dependencies for the detached Task.
        let client        = engineClient
        let manager       = engineManager
        let buffer        = ringBuffer
        let ctxProvider   = contextProvider
        let localContext  = context

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.streamLive(
                handle: handle,
                engineClient: client,
                engineManager: manager,
                ringBuffer: buffer,
                contextProvider: ctxProvider,
                staticContext: localContext
            )
        }

        return handle
    }

    /// Signals end of user speech; transitions streaming → finalizing so the
    /// consumer drains the buffer tail and sends the sentinel.
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

    /// Cancels the current session: any state → idle. Buffer is cleared and
    /// socket is disconnected so the engine does not hang waiting for EOF.
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
        // Disconnect so the engine sees EOF and the streamLive consumer Task exits.
        // Without this the engine blocks on recv() indefinitely after cancel().
        engineManager.disconnect()
    }

    // -----------------------------------------------------------------------
    // MARK: Internal — transition helpers (called from streamLive on MainActor)
    // -----------------------------------------------------------------------

    /// capturing → streaming (called by streamLive after engine sends .ready).
    fileprivate func beginStreaming(handle: AudioRingBuffer.Handle) {
        guard handle == activeHandle, state == .capturing else { return }
        state = .streaming
        pipelineLogger.info("AudioPipeline: capturing → streaming (handle \(handle.id))")
        onStreaming?()
    }

    /// streaming/finalizing → idle after result received. Clears buffer.
    fileprivate func finalize(handle: AudioRingBuffer.Handle,
                              text: String?, command: Command?) {
        guard handle == activeHandle else { return }
        ringBuffer.clear(handle: handle)
        activeHandle = nil
        state = .idle
        pipelineLogger.info("AudioPipeline: → idle via result (handle \(handle.id))")
        onResult?(text, command)
    }

    /// → error state (called by streamLive on unrecoverable engine error).
    /// Transitions directly to .idle after firing onError so that the next
    /// beginRecording() can proceed without an explicit reset call.
    fileprivate func enterError(handle: AudioRingBuffer.Handle, message: String) {
        guard handle == activeHandle else { return }
        pipelineLogger.error("AudioPipeline: → error: \(message) (handle \(handle.id))")
        ringBuffer.clear(handle: handle)
        activeHandle = nil
        state = .idle
        onError?(message)
    }

    // -----------------------------------------------------------------------
    // MARK: streamLive — detached consumer coroutine
    //
    // NOT @MainActor. Runs on a cooperative thread. Communicates state back
    // via await MainActor.run { }.
    // -----------------------------------------------------------------------

    private func streamLive(
        handle: AudioRingBuffer.Handle,
        engineClient: EngineClient,
        engineManager: EngineManager,
        ringBuffer: AudioRingBuffer,
        contextProvider: (() async -> [String: String])?,
        staticContext: [String: String]
    ) async {
        var lastSentTimestamp: TimeInterval = 0.0

        // Build context — prefer async contextProvider (wires ContextBuilder.build),
        // fall back to the static snapshot passed from beginRecording.
        let context: [String: String]
        if let provider = contextProvider {
            context = await provider()
        } else {
            context = staticContext
        }

        // --- Ensure engine is running, then connect ---
        // ensureRunning() starts the engine process if needed and waits up to
        // 30 s for the socket to become available. The ring buffer retains all
        // audio captured since beginRecording(), so no chunks are lost during
        // a cold-start delay.
        do {
            try await engineManager.ensureRunning()

            // Guard: cancel() may have fired during the ensureRunning wait.
            let isActive = await MainActor.run { self.activeHandle == handle }
            guard isActive else {
                pipelineLogger.debug("AudioPipeline streamLive: cancelled during ensureRunning")
                return
            }

            try await engineClient.connect(path: engineManager.socketPath)
            try await engineClient.startSession(context: context)

            let readyMsg = try await engineClient.receiveMessage(timeoutMs: 120_000)
            guard case .ready = readyMsg else {
                throw EngineClientError.unexpectedMessage(readyMsg)
            }
        } catch {
            pipelineLogger.error("AudioPipeline: connect/ready failed: \(error)")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.enterError(handle: handle, message: "Connection failed")
            }
            return
        }

        // Transition to streaming now that the engine is ready.
        await MainActor.run { [weak self] in
            self?.beginStreaming(handle: handle)
        }

        // --- Tail-follow consumer loop ---
        var streamSentFrames = 0
        var streamSentBytes = 0

        func userMessage(forEngineError code: String, message: String) -> String {
            switch code {
            case "inference_failed":  return "Could not process — try again"
            case "model_load_failed": return "Model error — check ~/.openverb/models/"
            case "timeout":           return "Inference timed out"
            case "duration_exceeded": return "Recording too long"
            default:                  return message
            }
        }

        func dispatchServerMessage(_ msg: ServerMessage,
                                   allowFinalResult: Bool) async -> StreamDrainResult {
            switch msg {
            case .result(let text, let command):
                guard allowFinalResult else {
                    pipelineLogger.warning("AudioPipeline: result arrived before end-of-audio")
                    return .keepGoing
                }
                return .finished(text: text, command: command)

            case .error(let code, let message):
                pipelineLogger.error("AudioPipeline: engine error \(code): \(message)")
                let userMsg = userMessage(forEngineError: code, message: message)
                await MainActor.run { [weak self] in
                    self?.enterError(handle: handle, message: userMsg)
                }
                return .failed

            case .partialResult(let text, let chunkId, let isFinal):
                engineClient.onPartialResult?(text, chunkId, isFinal)
                return .keepGoing

            case .progress(let pct):
                pipelineLogger.debug("AudioPipeline: progress \(pct)")
                return .keepGoing

            case .queueStatus(let pending, let inFlight, let etaMs):
                engineClient.onQueueStatus?(pending, inFlight > 0, etaMs)
                return .keepGoing

            case .polishStarted:
                engineClient.onPolishStarted?()
                return .keepGoing

            case .polishedResult(let text):
                engineClient.onPolishedResult?(text)
                if allowFinalResult {
                    return .finished(text: text, command: nil)
                }
                return .keepGoing

            case .warning(let code, let msg):
                pipelineLogger.warning("AudioPipeline warning \(code): \(msg)")
                return .keepGoing

            default:
                return .keepGoing
            }
        }

        func drainAvailableServerMessages() async throws -> StreamDrainResult {
            while true {
                do {
                    let msg = try await engineClient.receiveMessage(timeoutMs: 1)
                    let result = await dispatchServerMessage(msg, allowFinalResult: false)
                    switch result {
                    case .keepGoing:
                        continue
                    case .finished, .failed:
                        return result
                    }
                } catch EngineClientError.timeout {
                    return .keepGoing
                }
            }
        }

        do {
            // Check current pipeline state on MainActor each iteration to respect
            // cancel() and endRecording() transitions.
            while true {
                let currentState: State = await MainActor.run { self.state }
                let isActive = await MainActor.run { self.activeHandle == handle }
                guard isActive else {
                    // Handle was cancelled or finalized externally — stop.
                    pipelineLogger.debug("AudioPipeline streamLive: handle invalidated, exiting")
                    break
                }

                if currentState == .finalizing || currentState == .idle {
                    // User stopped recording — drain remaining buffer entries then sentinel.
                    break
                }

                // Read next chunk from ring buffer (tail-follow from lastSentTimestamp).
                if let (chunk, ts) = await ringBuffer.readNext(
                    handle: handle,
                    afterTimestamp: lastSentTimestamp,
                    maxWait: .milliseconds(50)
                ) {
                    engineClient.sendAudioFrame(chunk)
                    lastSentTimestamp = ts
                    streamSentFrames += 1
                    streamSentBytes += chunk.count
                }
                // The engine can emit partial_result while the user is still
                // speaking. Drain any waiting JSON now so the HUD updates live
                // instead of receiving a burst only after the end-of-audio sentinel.
                switch try await drainAvailableServerMessages() {
                case .keepGoing:
                    break
                case .finished:
                    pipelineLogger.warning("AudioPipeline: ignoring early result during live stream")
                case .failed:
                    return
                }
                // If readNext timed out, loop again — state or server messages may have changed.
            }

            // --- Finalizing: drain tail then send sentinel ---
            // If state was cancelled before we entered the drain, skip.
            let shouldDrain: Bool = await MainActor.run {
                self.activeHandle == handle && (self.state == .finalizing || self.state == .streaming)
            }
            if shouldDrain {
                // Drain remaining chunks already in the buffer.
                while let (chunk, ts) = await ringBuffer.readNext(
                    handle: handle,
                    afterTimestamp: lastSentTimestamp,
                    maxWait: .milliseconds(100)
                ) {
                    engineClient.sendAudioFrame(chunk)
                    lastSentTimestamp = ts
                    streamSentFrames += 1
                    streamSentBytes += chunk.count
                }
                pipelineLogger.info("AudioPipeline streamLive: sent \(streamSentFrames) frames, \(streamSentBytes) bytes before sentinel")
                engineClient.sendEndOfAudio()

                // Wait for .result
                var finalText: String?
                var finalCommand: Command?
                drainLoop: while true {
                    let msg: ServerMessage
                    do {
                        msg = try await engineClient.receiveMessage(timeoutMs: 180_000)
                    } catch {
                        throw error
                    }

                    switch await dispatchServerMessage(msg, allowFinalResult: true) {
                    case .finished(let text, let command):
                        finalText = text
                        finalCommand = command
                        break drainLoop
                    case .failed:
                        return
                    case .keepGoing:
                        continue
                    }
                }

                engineManager.disconnect()
                await MainActor.run { [weak self] in
                    self?.finalize(handle: handle, text: finalText, command: finalCommand)
                }
            }

        } catch {
            pipelineLogger.error("AudioPipeline streamLive error: \(error)")
            // Attempt crash recovery and report error to AppDelegate.
            do {
                try await engineManager.handleCrash()
            } catch {
                pipelineLogger.error("AudioPipeline: handleCrash failed: \(error)")
            }
            await MainActor.run { [weak self] in
                self?.enterError(handle: handle, message: "Engine error")
            }
        }
    }
}
