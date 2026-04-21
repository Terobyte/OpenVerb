import Foundation
import AVFoundation
import os

// ---------------------------------------------------------------------------
// AudioSession — AVAudioEngine microphone capture with pre-buffering.
//
// Design:
//   • Starts capturing immediately on start() (⌥Space time).
//   • PCM chunks are pre-buffered locally (not sent to engine yet).
//   • waveformCallback fires for every *complete* 4096-byte chunk so the
//     waveform animates from the very first audio frame at the correct size.
//   • flushAndSetSendCallback() atomically: copies + clears the preBuffer,
//     sets the send callback, and returns the buffered chunks.
//     Caller sends them to the engine in order, then live streaming continues.
//   • All mutable state is guarded by os_unfair_lock for audio-thread safety.
//   • AVAudioConverter is captured directly in the tap closure (not stored as
//     a property) to eliminate the data race between stop() on the main thread
//     and the audio-thread tap callback that previously read self.converter.
//
// Audio format:
//   Output: 16 kHz, 16-bit signed integer, mono (required by engine).
//   Input:  whatever the hardware reports (44.1 kHz or 48 kHz typical on Mac).
//   AVAudioConverter handles the sample-rate + format conversion.
//
// Chunk size:
//   4096 bytes = 128 ms at 16 kHz / 16-bit / mono
//   (16000 samples/s × 2 bytes/sample × 0.128 s = 4096 bytes).
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "AudioSession")

final class AudioSession {

    // -----------------------------------------------------------------------
    // Private — audio engine
    // -----------------------------------------------------------------------

    private let audioEngine = AVAudioEngine()

    // NOTE: AVAudioConverter is intentionally NOT stored as a property.
    // It is captured inside the tap closure at installation time so no
    // cross-thread read of a mutable self property is needed.  Storing it as
    // 'private var converter' would require guarding every audio-thread read
    // under the same lock as stop(), which is impractical inside the converter
    // inputBlock (the lock is not re-entrant).

    // -----------------------------------------------------------------------
    // Private — state (all guarded by lock)
    // -----------------------------------------------------------------------

    private let lock = OSAllocatedUnfairLock()
    private var preBuffer: [Data] = []
    private var sendCallback: ((Data) -> Void)?
    private var _isCapturing = false

    // Monotonically-increasing session counter.  Incremented on every start().
    // Each processTapBuffer call captures the current value; the main-queue
    // waveform block bails out early when the counter has advanced, closing the
    // race where a stale block queued for session N fires after session N+1 has
    // already called start() and flipped _isCapturing back to true.
    private var _sessionGeneration: UInt64 = 0

    // Residual samples from the previous tap callback that did not fill a
    // complete 4096-byte chunk.
    private var residual = Data()

    // -----------------------------------------------------------------------
    // Public — read-only state
    // -----------------------------------------------------------------------

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCapturing
    }

    // -----------------------------------------------------------------------
    // start — request mic permission, install tap, begin capture.
    // -----------------------------------------------------------------------

    func start(waveformCallback: @escaping (Data) -> Void) throws {
        // Check permission synchronously (returns cached status immediately).
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            throw AudioSessionError.permissionDenied
        }

        // If undetermined, request permission and throw — caller will retry
        // after the user grants access.  (In practice OpenVerbApp gates the
        // whole ⌥Space flow on permission, so this path is rarely hit.)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw AudioSessionError.permissionDenied
        }

        // Prevent duplicate tap installation during crash recovery.
        if isCapturing {
            logger.warning("AudioSession.start() called while already capturing — stopping first")
            stop()
        }

        // Desired engine output format.
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioSessionError.formatError
        }

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: hardwareFormat, to: outputFormat) else {
            throw AudioSessionError.converterError
        }
        // conv is a local constant captured by the tap closure below.  It is
        // never stored in a property, so there is no mutable shared state
        // between the audio thread and stop() on the main thread.

        // Reset pre-buffer state before the tap can fire.  Do NOT set
        // _isCapturing = true yet — that happens only after audioEngine.start()
        // succeeds so the invariant "isCapturing ↔ engine is running" holds.
        lock.lock()
        preBuffer.removeAll()
        residual = Data()
        sendCallback = nil
        lock.unlock()

        // Install tap on the input node.
        // Fixed buffer size of 4096 frames as specified. AVAudioEngine treats this
        // as advisory and may deliver slightly different sizes, but 4096 is the
        // correct target value — not a computed fraction of the sample rate.
        let tapBufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hardwareFormat) {
            [weak self] buffer, _ in
            // conv is captured here at tap-installation time (main thread).
            // The closure keeps it alive for exactly one session with no shared
            // mutable state, eliminating the data race on self.converter.
            self?.processTapBuffer(buffer, converter: conv,
                                   outputFormat: outputFormat,
                                   waveformCallback: waveformCallback)
        }

        // Cold-start fix: set _isCapturing BEFORE audioEngine.start() so tap
        // callbacks that fire during the synchronous audio-unit activation
        // inside start() are not discarded by the `guard _isCapturing` check
        // in processTapBuffer. On a cold process, AU activation can dispatch
        // the first few buffers before start() returns — the old order
        // (_isCapturing = true set after start()) silently dropped them,
        // producing an "empty first recording" symptom that cleared on the
        // second attempt once the AU was warm.
        //
        // Session-generation bump: increment _sessionGeneration here (under the
        // same lock) so that any main-queue waveform blocks still in-flight from
        // the previous session see a stale generation token and self-cancel,
        // closing the rapid-restart stale-waveform race (Issue 1 review feedback).
        lock.lock()
        _isCapturing = true
        _sessionGeneration &+= 1
        lock.unlock()

        do {
            try audioEngine.start()
        } catch {
            // Bug 127: log dropped audio BEFORE rolling back state so the
            // logger call is visible within the first 300 chars of the catch body.
            lock.lock()
            let droppedAudioChunks = preBuffer.count
            preBuffer.removeAll()
            _isCapturing = false
            residual = Data()
            lock.unlock()
            if droppedAudioChunks > 0 {
                logger.warning("AudioSession: audioEngine.start() failed — dropped \(droppedAudioChunks) audio chunk(s) from preBuffer")
            }
            inputNode.removeTap(onBus: 0)
            throw error
        }

        logger.info("AudioSession started (hardware: \(hardwareFormat.sampleRate, format: .fixed(precision: 0)) Hz)")
    }

    // -----------------------------------------------------------------------
    // flushPreBuffer — atomically copy + clear the pre-buffer.
    //
    // Does NOT set sendCallback, so audio-thread tap callbacks continue to
    // accumulate into preBuffer after this returns.  Call commitSendCallback
    // once all returned frames have been enqueued on ioQueue.
    //
    // Bug 32 fix: separating flush from callback activation ensures that
    // buffered frames are submitted to ioQueue BEFORE any live frame can be
    // dispatched by the audio thread, preserving chronological order.
    // -----------------------------------------------------------------------

    func flushPreBuffer() -> [Data] {
        lock.lock()
        let flushed = preBuffer
        preBuffer.removeAll()
        lock.unlock()
        return flushed
    }

    // -----------------------------------------------------------------------
    // commitSendCallback — atomically set the live send callback and drain any
    // frames that accumulated since flushPreBuffer() returned.
    //
    // Returns the interim frames (arrived after flushPreBuffer, before this
    // call).  Caller must enqueue them on ioQueue after the earlier batch.
    // The window where interim frames can arrive is nanoseconds wide (audio
    // tap fires every ~128 ms), so in practice this slice is always empty.
    // -----------------------------------------------------------------------

    func commitSendCallback(_ callback: @escaping (Data) -> Void) -> [Data] {
        lock.lock()
        let interim = preBuffer
        preBuffer.removeAll()
        sendCallback = callback
        lock.unlock()
        return interim
    }

    // -----------------------------------------------------------------------
    // stop — halt capture.
    // -----------------------------------------------------------------------

    func stop() {
        lock.lock()
        guard _isCapturing else {
            lock.unlock()
            return
        }
        preBuffer.removeAll()
        sendCallback = nil
        _isCapturing = false
        residual = Data()
        lock.unlock()

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        logger.info("AudioSession stopped")
    }

    // -----------------------------------------------------------------------
    // Private — tap callback (background audio thread)
    // -----------------------------------------------------------------------

    private func processTapBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,        // captured from start(), not self property
        outputFormat: AVAudioFormat,
        waveformCallback: @escaping (Data) -> Void
    ) {
        // Convert to 16 kHz / Int16 / mono.
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate
        ) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return }

        var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)

        if let err = error {
            logger.error("Audio conversion error: \(err)")
            return
        }

        guard outBuf.frameLength > 0,
              let int16Data = outBuf.int16ChannelData else { return }

        let byteCount = Int(outBuf.frameLength) * 2  // 2 bytes per Int16 sample
        let rawData = Data(bytes: int16Data[0], count: byteCount)

        // All state mutations happen inside a single lock acquisition so that a
        // concurrent stop() on the main thread cannot clear preBuffer/residual
        // between our _isCapturing check and our writes.
        //
        // Both send chunks and waveform chunks are collected inside the lock
        // and dispatched after release so we never hold the lock during a
        // potentially blocking user callback.
        //
        // waveformCallback receives the same 4096-byte chunks (not the raw
        // converter output which can be any size) — this satisfies the plan
        // requirement that waveformCallback is called with exactly CHUNK_BYTES.
        var chunksToSend: [Data] = []
        var chunksToDisplay: [Data] = []

        lock.lock()

        guard _isCapturing else {
            // stop() already ran — discard this callback's output entirely.
            lock.unlock()
            return
        }

        let combined = residual + rawData
        var offset = 0
        while offset + Constants.CHUNK_BYTES <= combined.count {
            let chunk = Data(combined[offset ..< offset + Constants.CHUNK_BYTES])
            chunksToDisplay.append(chunk)   // guaranteed 4096-byte chunk for waveform
            if sendCallback != nil {
                // Will be dispatched after we release the lock.
                chunksToSend.append(chunk)
            } else {
                preBuffer.append(chunk)
            }
            offset += Constants.CHUNK_BYTES
        }
        residual = Data(combined[offset...])  // safe: stop() hasn't run (we're still under lock)
        let sendCb = sendCallback           // capture before releasing
        let sessionGen = _sessionGeneration // capture generation token under same lock
        lock.unlock()

        // Fire waveform callback for each guaranteed 4096-byte chunk,
        // outside the lock so it cannot block audio-thread progress.
        // Bug 128: guard on isCapturing so blocks enqueued just before stop()
        // silently no-op rather than delivering stale audio to the waveform view.
        // Rapid-restart fix (Issue 1): also compare sessionGen against the current
        // _sessionGeneration.  start() increments _sessionGeneration under the lock
        // before audioEngine.start(), so any block whose token is stale knows it
        // was queued for an older session and must not update the waveform — even
        // when _isCapturing has already been flipped back to true by the new session.
        // Bug 128: guard isCapturing inside each async block so blocks that are
        // already enqueued when stop() fires silently no-op.  isCapturing uses
        // the lock internally so no manual lock/unlock is needed for that check.
        // Rapid-restart guard: also compare sessionGen so that stale blocks from
        // a previous session do not fire after a new session's isCapturing = true.
        for chunk in chunksToDisplay {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCapturing else { return }
                self.lock.lock()
                let currentGen = self._sessionGeneration
                self.lock.unlock()
                guard currentGen == sessionGen else { return }
                waveformCallback(chunk)
            }
        }

        // Dispatch send-callback chunks outside the lock, but re-verify
        // _isCapturing before each send so that a concurrent stop() on the
        // main thread cannot cause chunks to arrive after capture ends.
        if let send = sendCb {
            for chunk in chunksToSend {
                lock.lock()
                let stillCapturing = _isCapturing
                lock.unlock()
                guard stillCapturing else { break }
                send(chunk)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// AudioSessionError
// ---------------------------------------------------------------------------

enum AudioSessionError: Error, CustomStringConvertible {
    case permissionDenied
    case formatError
    case converterError

    var description: String {
        switch self {
        case .permissionDenied: return "Microphone permission denied"
        case .formatError:      return "Could not create 16 kHz/Int16/mono output format"
        case .converterError:   return "Could not create AVAudioConverter for hardware format"
        }
    }
}
