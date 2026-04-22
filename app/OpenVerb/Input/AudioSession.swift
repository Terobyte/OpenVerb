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
    private var _sessionPeak: Int32 = 0
    private var _sessionSampleCount: Int = 0

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
    // Private — ring buffer write path (Phase 7)
    //
    // Separate lock so the realtime audio thread never contends with the
    // AudioRingBuffer's own lock under the main AudioSession lock.
    // -----------------------------------------------------------------------

    private let rbLock = OSAllocatedUnfairLock()
    private weak var _ringBuffer: AudioRingBuffer?
    private var _ringBufferHandle: AudioRingBuffer.Handle?
    // Monotonically-increasing timestamp seed, advanced 128 ms per chunk so
    // each chunk has a unique timestamp for AudioRingBuffer.readNext ordering.
    private var _ringBufferTimestamp: TimeInterval = 0

    // -----------------------------------------------------------------------
    // Public — read-only state
    // -----------------------------------------------------------------------

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCapturing
    }

    // Bug 172: expose the session generation via a locked getter so consumers
    // on other threads (waveform main-queue blocks) never hold self.lock
    // directly — only inside this accessor.
    var sessionGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _sessionGeneration
    }

    // -----------------------------------------------------------------------
    // setRingBuffer — called by AppDelegate to wire/unwire the ring buffer
    // path for the current recording session.
    //
    // Pass (nil, nil) to clear the handle (stop writes) on session end.
    // Thread-safe: protected by rbLock, separate from the main audio lock.
    // -----------------------------------------------------------------------

    func setRingBuffer(_ buffer: AudioRingBuffer?, handle: AudioRingBuffer.Handle?) {
        rbLock.lock()
        _ringBuffer = buffer
        _ringBufferHandle = handle
        if buffer != nil {
            _ringBufferTimestamp = Date().timeIntervalSinceReferenceDate
        }
        rbLock.unlock()
    }

    // -----------------------------------------------------------------------
    // start — request mic permission, install tap, begin capture.
    // -----------------------------------------------------------------------

    func start(waveformCallback: @escaping (Data) -> Void) throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            throw AudioSessionError.permissionDenied
        }
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            throw AudioSessionError.permissionDenied
        }
        if isCapturing {
            logger.warning("AudioSession.start() called while already capturing — stopping first")
            stop()
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ) else {
            throw AudioSessionError.formatError
        }

        let inputNode = audioEngine.inputNode

        lock.lock()
        preBuffer.removeAll()
        residual = Data()
        sendCallback = nil
        _sessionPeak = 0
        _sessionSampleCount = 0
        lock.unlock()

        // Bump _isCapturing/_sessionGeneration before engine.start() to keep
        // in-flight AU buffers from being dropped.
        lock.lock()
        _isCapturing = true
        _sessionGeneration &+= 1
        lock.unlock()

        do {
            try audioEngine.start()
        } catch {
            // Bug 127: log dropped audio BEFORE rolling back state.
            lock.lock()
            let droppedAudioChunks = preBuffer.count
            preBuffer.removeAll()
            _isCapturing = false
            residual = Data()
            lock.unlock()
            if droppedAudioChunks > 0 {
                logger.warning("AudioSession: audioEngine.start() failed — dropped \(droppedAudioChunks) audio chunk(s) from preBuffer")
            }
            throw error
        }

        // Bug 144: query hardwareFormat AFTER engine.start() so it reflects
        // post-negotiation sample rate rather than a stale pre-start guess.
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: hardwareFormat, to: outputFormat) else {
            audioEngine.stop()
            lock.lock()
            _isCapturing = false
            lock.unlock()
            throw AudioSessionError.converterError
        }

        // Bug 143: warmup the converter with one silent buffer so the first
        // real tap buffer produces valid Int16 (not zero-filled resampler state).
        primeConverter(conv, hardwareFormat: hardwareFormat, outputFormat: outputFormat)

        // Install tap after warmup so the first real buffer is valid.
        let tapBufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hardwareFormat) {
            [weak self] buffer, _ in
            self?.processTapBuffer(buffer, converter: conv,
                                   outputFormat: outputFormat,
                                   waveformCallback: waveformCallback)
        }

        // Bug 145: flowValidation — poll preBuffer.count > 0 up to 500 ms so
        // zero-filled first buffers (non-zero check) don't silently pass as
        // a firstBuffer. Surfaces waitForFirstChunk style flow assurance.
        let flowValidationDeadline = Date().addingTimeInterval(0.5)
        while Date() < flowValidationDeadline {
            lock.lock()
            let haveFirstBuffer = preBuffer.count > 0
            lock.unlock()
            if haveFirstBuffer { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        logger.info("AudioSession started (hardware: \(hardwareFormat.sampleRate, format: .fixed(precision: 0)) Hz)")
    }

    // warmup helper — primes the AVAudioConverter resampler state so the first
    // real tap callback produces valid Int16 PCM instead of silence.
    private func primeConverter(_ conv: AVAudioConverter,
                                hardwareFormat: AVAudioFormat,
                                outputFormat: AVAudioFormat) {
        let frames: AVAudioFrameCount = 1024
        guard let silentIn = AVAudioPCMBuffer(pcmFormat: hardwareFormat, frameCapacity: frames) else { return }
        silentIn.frameLength = frames
        guard let warmupOut = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else { return }
        var consumed = false
        var err: NSError?
        conv.convert(to: warmupOut, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return silentIn
        }
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
        let peak = _sessionPeak
        let samples = _sessionSampleCount
        let durationMs = samples * 1000 / 16_000  // output rate
        logger.info("AudioSession stopped — session peak=\(peak)/32767 (\(peak < 500 ? "near-silence, VAD will reject" : peak < 2000 ? "very quiet, may fail VAD" : "OK")) duration=\(durationMs)ms")
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

        // One-shot peak-level diagnostic: log the max absolute sample of the
        // first three converter output buffers so we can tell an empty mic
        // capture (peak == 0) from "mic is loud but VAD rejects" at a glance.
        // Session-wide peak tracker: every converter output buffer contributes.
        // Session ends log the total in stop() so we can tell "mic was quiet
        // whole time" (peak < 500) from "user spoke loudly" (peak > 5000).
        do {
            let samplePtr = int16Data[0]
            var peak: Int32 = 0
            for i in 0..<Int(outBuf.frameLength) {
                let s = Int32(samplePtr[i])
                let a = s < 0 ? -s : s
                if a > peak { peak = a }
            }
            if peak > self._sessionPeak { self._sessionPeak = peak }
            self._sessionSampleCount &+= Int(outBuf.frameLength)
        }

        // Lock guards _isCapturing / preBuffer / residual against stop().
        // Callbacks fire outside the lock so they never block audio.
        var chunksToSend: [Data] = []
        var chunksToDisplay: [Data] = []
        var chunksForRingBuffer: [Data] = []

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
            chunksForRingBuffer.append(chunk)
            if sendCallback != nil {
                // Will be dispatched after we release the lock.
                chunksToSend.append(chunk)
            } else {
                // Bug 142: cap preBuffer at ~24 chunks (~3 s of 128 ms audio)
                // so a slow engine cold start or a missed commit cannot grow
                // the pre-buffer unboundedly. When the cap is exceeded we
                // drop the oldest chunk, preserving the most recent audio.
                if preBuffer.count < 24 {
                    preBuffer.append(chunk)
                } else {
                    preBuffer.removeFirst()
                    preBuffer.append(chunk)
                }
            }
            offset += Constants.CHUNK_BYTES
        }
        residual = Data(combined[offset...])  // safe: stop() hasn't run (we're still under lock)
        let sendCb = sendCallback           // capture before releasing
        let sessionGen = _sessionGeneration // capture generation token under same lock
        lock.unlock()

        // Bug 128/172: dispatch to main and guard on isCapturing + sessionGen
        // so stale blocks from a previous session self-cancel without
        // re-acquiring self.lock inside the async block (deadlock risk).
        for chunk in chunksToDisplay {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCapturing else { return }
                guard self.sessionGeneration == sessionGen else { return }
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

        // Ring buffer write path — active whenever a handle is wired via
        // setRingBuffer(). Timestamps are monotonically increasing (128 ms per
        // chunk) so AudioRingBuffer.readNext ordering is always correct.
        if !chunksForRingBuffer.isEmpty {
            rbLock.lock()
            let rb = _ringBuffer
            let h = _ringBufferHandle
            var ts = _ringBufferTimestamp
            rbLock.unlock()
            if let rb, let h {
                for chunk in chunksForRingBuffer {
                    rb.write(chunk, timestamp: ts, handle: h)
                    ts += 0.128
                }
                rbLock.lock()
                _ringBufferTimestamp = ts
                rbLock.unlock()
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
