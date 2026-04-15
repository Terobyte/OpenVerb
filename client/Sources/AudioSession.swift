import AVFoundation

// ---------------------------------------------------------------------------
// AudioSession — wraps AVAudioEngine to capture microphone audio and deliver
// 16 kHz / 16-bit / mono PCM chunks to a callback.
//
// Pre-buffer: audio captured between start() and the first call to
// flushPreBuffer() is accumulated internally and delivered as a single
// burst before live streaming begins.
// ---------------------------------------------------------------------------

public final class AudioSession {
    private let audioEngine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private var converter: AVAudioConverter?
    private var callback: ((Data) -> Void)?
    private var preBuffer = Data()
    private var isPreBuffering = true
    private let preBufferLock = NSLock()

    public private(set) var isCapturing = false

    public init() {}

    // ---------------------------------------------------------------------------
    // start — begin capturing from the default input device.
    //
    // The callback receives 16kHz/16-bit/mono PCM Data chunks (~4096 bytes).
    // ---------------------------------------------------------------------------

    public func start(callback: @escaping (Data) -> Void) throws {
        guard !isCapturing else { return }
        self.callback = callback

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        // Reset pre-buffer state under the lock BEFORE starting the engine so
        // the tap callback always sees isPreBuffering == true on its first run,
        // even if AVAudioEngine fires it synchronously on the same thread.
        preBufferLock.lock()
        isPreBuffering = true
        preBuffer = Data()
        preBufferLock.unlock()

        try audioEngine.start()
        isCapturing = true
    }

    // ---------------------------------------------------------------------------
    // stop — halt capture and release the tap.
    // ---------------------------------------------------------------------------

    public func stop() {
        guard isCapturing else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isCapturing = false
        callback = nil
        converter = nil
    }

    // ---------------------------------------------------------------------------
    // flushPreBuffer — deliver accumulated pre-buffer audio to the callback,
    // then switch to live streaming mode.
    // ---------------------------------------------------------------------------

    public func flushPreBuffer() {
        preBufferLock.lock()
        let data = preBuffer
        preBuffer = Data()
        isPreBuffering = false
        preBufferLock.unlock()

        if !data.isEmpty {
            dispatchChunks(data)
        }
    }

    // ---------------------------------------------------------------------------
    // dispatchChunks — send data to the callback in 4096-byte pieces.
    // ---------------------------------------------------------------------------

    private func dispatchChunks(_ data: Data) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + 4096, data.count)
            callback?(data[offset..<end])
            offset = end
        }
    }

    // ---------------------------------------------------------------------------
    // processBuffer — convert to 16kHz/16-bit/mono and deliver chunks.
    // ---------------------------------------------------------------------------

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        let outFmt = targetFormat
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * outFmt.sampleRate / buffer.format.sampleRate
        ) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outFmt,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        var inputConsumed = false
        let status = converter.convert(to: outputBuffer, error: &error) {
            inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else { return }

        let frameLength = outputBuffer.frameLength
        guard frameLength > 0 else { return }

        let channelData = outputBuffer.int16ChannelData![0]
        let byteCount = Int(frameLength) * 2
        let data = Data(bytes: channelData, count: byteCount)

        preBufferLock.lock()
        if isPreBuffering {
            preBuffer.append(data)
            preBufferLock.unlock()
        } else {
            preBufferLock.unlock()
            dispatchChunks(data)
        }
    }
}

public enum AudioSessionError: Error, CustomStringConvertible {
    case formatError

    public var description: String {
        switch self {
        case .formatError: return "failed to create audio format"
        }
    }
}
