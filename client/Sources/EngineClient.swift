import Foundation

// ---------------------------------------------------------------------------
// EngineClient — low-level Unix-domain-socket client for the OpenVerb engine.
//
// Manages the binary protocol:
//   Phase 1 — JSON messages (session.start → ready, ping/pong)
//   Phase 2 — binary audio frames (4-byte BE length prefix + payload)
//   Phase 3 — JSON messages (progress, result, error)
//
// During Phase 2 a background DispatchQueue polls the socket for
// incoming server messages (error/warning) so that a fatal engine error
// does not sit unread in the kernel buffer.
// ---------------------------------------------------------------------------

public final class EngineClient {
    private var fd: Int32 = -1
    private var recvBuffer = RecvAccumulator()
    private let recvLock = NSLock()

    private let readQueue = DispatchQueue(label: "ai.openverb.client.read",
                                          qos: .userInitiated)

    // Set by the background read when an error arrives during Phase 2.
    private var phase2Error: ServerMessage?
    private let phase2Lock = NSLock()
    private var phase2MonitorStopped = false
    private let monitorGroup = DispatchGroup()
    private var monitorPipeRead: Int32 = -1
    private var monitorPipeWrite: Int32 = -1

    public init() {}

    // ---------------------------------------------------------------------------
    // RecvAccumulator — buffers partial reads across recv_json calls.
    // ---------------------------------------------------------------------------

    private struct RecvAccumulator {
        var data = Data()
        static let maxJSONSize = 65_536

        mutating func append(_ chunk: Data) {
            data.append(chunk)
        }

        mutating func extractMessage() -> Data? {
            guard let newlineIdx = data.firstIndex(of: UInt8(ascii: "\n")) else {
                return nil
            }
            let message = data[data.startIndex...newlineIdx]
            let trimmed = message.dropLast() // drop the newline
            data = Data(data[newlineIdx...].dropFirst())
            return Data(trimmed)
        }

        mutating func prepend(_ data: Data) {
            var combined = data
            combined.append(self.data)
            self.data = combined
        }

        var isOverSize: Bool { data.count > Self.maxJSONSize }
    }

    // ---------------------------------------------------------------------------
    // Connect / disconnect
    // ---------------------------------------------------------------------------

    public func connect(path: String) throws {
        guard fd == -1 else { return }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw EngineClientError.systemError(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { p in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
                dst.update(from: p, count: strlen(p) + 1)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let ok = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            let err = errno
            close(socketFD)
            throw EngineClientError.connectionFailed(err)
        }

        fd = socketFD
        recvBuffer = RecvAccumulator()
    }

    public func disconnect() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
        recvLock.lock()
        recvBuffer = RecvAccumulator()
        recvLock.unlock()
        if monitorPipeRead >= 0 { close(monitorPipeRead); monitorPipeRead = -1 }
        if monitorPipeWrite >= 0 { close(monitorPipeWrite); monitorPipeWrite = -1 }
    }

    public var isConnected: Bool { fd >= 0 }

    // ---------------------------------------------------------------------------
    // JSON send helpers
    // ---------------------------------------------------------------------------

    private func writeFully(_ buffer: UnsafeRawPointer, count: Int) throws {
        var remaining = count
        var ptr = buffer
        while remaining > 0 {
            let written = write(fd, ptr, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                throw EngineClientError.writeFailed(errno)
            }
            guard written > 0 else {
                throw EngineClientError.connectionClosed
            }
            ptr = ptr + written
            remaining -= written
        }
    }

    private func sendJSON<T: Encodable>(_ msg: T) throws {
        guard fd >= 0 else { throw EngineClientError.notConnected }
        let data = try JSONEncoder().encode(msg)
        var payload = data
        payload.append(UInt8(ascii: "\n"))

        try payload.withUnsafeBytes { ptr in
            try writeFully(ptr.baseAddress!, count: ptr.count)
        }
    }

    // ---------------------------------------------------------------------------
    // JSON receive — buffered, scans for newline delimiter.
    // ---------------------------------------------------------------------------

    private func recvJSON(timeoutMs: Int = 15_000) throws -> Data {
        guard fd >= 0 else { throw EngineClientError.notConnected }

        recvLock.lock()
        if let msg = recvBuffer.extractMessage() {
            recvLock.unlock()
            return msg
        }
        recvLock.unlock()

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let remaining = deadline.timeIntervalSinceNow * 1000.0
            guard remaining > 0 else { throw EngineClientError.timeout }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(remaining))
            guard pr > 0 else {
                if pr == 0 { throw EngineClientError.timeout }
                throw EngineClientError.systemError(errno: errno)
            }
            guard pfd.revents & Int16(POLLIN) != 0 else {
                throw EngineClientError.systemError(errno: errno)
            }

            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else {
                throw EngineClientError.connectionClosed
            }

            recvLock.lock()
            recvBuffer.append(Data(chunk[0..<n]))
            if recvBuffer.isOverSize {
                recvLock.unlock()
                throw EngineClientError.jsonTooLarge
            }
            if let msg = recvBuffer.extractMessage() {
                recvLock.unlock()
                return msg
            }
            recvLock.unlock()
        }
    }

    // ---------------------------------------------------------------------------
    // Public high-level operations
    // ---------------------------------------------------------------------------

    public func startSession(context: [String: String] = [:]) throws {
        try sendJSON(SessionStart(context: context))
    }

    public func sendPing() throws {
        try sendJSON(Ping())
    }

    public func ping(timeoutMs: Int = 5000) throws {
        try sendPing()
        let msg = try receiveMessage(timeoutMs: timeoutMs)
        guard case .pong = msg else {
            throw EngineClientError.unexpectedMessage(msg)
        }
    }

    public func sendEndOfAudio() throws {
        guard fd >= 0 else { throw EngineClientError.notConnected }
        let sentinel: [UInt8] = [0, 0, 0, 0]
        try sentinel.withUnsafeBufferPointer { ptr in
            try writeFully(UnsafeRawPointer(ptr.baseAddress!), count: ptr.count)
        }
    }

    public func sendShutdown() throws {
        try sendJSON(Shutdown())
    }

    public func sendSessionEnd() throws {
        try sendJSON(SessionEnd())
    }

    // ---------------------------------------------------------------------------
    // Binary audio frame — 4-byte big-endian length prefix + payload.
    // ---------------------------------------------------------------------------

    public func sendAudioFrame(_ data: Data) throws {
        guard fd >= 0 else { throw EngineClientError.notConnected }
        guard data.count > 0 else { return }

        var header = [UInt8](repeating: 0, count: 4)
        let len = UInt32(data.count)
        header[0] = UInt8((len >> 24) & 0xFF)
        header[1] = UInt8((len >> 16) & 0xFF)
        header[2] = UInt8((len >> 8) & 0xFF)
        header[3] = UInt8(len & 0xFF)

        try header.withUnsafeBufferPointer { ptr in
            try writeFully(UnsafeRawPointer(ptr.baseAddress!), count: ptr.count)
        }

        try data.withUnsafeBytes { ptr in
            try writeFully(ptr.baseAddress!, count: ptr.count)
        }
    }

    // ---------------------------------------------------------------------------
    // receiveMessage — read one JSON message and decode it.
    // ---------------------------------------------------------------------------

    public func receiveMessage(timeoutMs: Int = 15_000) throws -> ServerMessage {
        let data = try recvJSON(timeoutMs: timeoutMs)
        return try ServerMessage.fromJSON(data)
    }

    // ---------------------------------------------------------------------------
    // waitForReady — convenience: send session.start, wait for .ready.
    // ---------------------------------------------------------------------------

    public func waitForReady(context: [String: String] = [:]) throws {
        try startSession(context: context)
        let msg = try receiveMessage(timeoutMs: 30_000)
        if case .error(let code, let message) = msg {
            throw EngineClientError.engineError(code, message)
        }
        guard case .ready = msg else {
            throw EngineClientError.unexpectedMessage(msg)
        }
    }

    // ---------------------------------------------------------------------------
    // Phase 2 concurrent error monitoring.
    //
    // While the write loop sends binary frames, a background DispatchQueue
    // polls the socket with poll(fd, POLLIN, 100ms).  If POLLIN fires during
    // Phase 2, read and parse the incoming JSON (engine sent an error).
    // On error: set a flag to abort the write loop.
    // ---------------------------------------------------------------------------

    public func startPhase2ErrorMonitor() {
        phase2Error = nil
        phase2MonitorStopped = false

        var pipefds: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipefds) == 0 else { return }
        monitorPipeRead = pipefds[0]
        monitorPipeWrite = pipefds[1]
        _ = fcntl(monitorPipeRead, F_SETFL, O_NONBLOCK)

        monitorGroup.enter()
        readQueue.async { [weak self] in
            defer { self?.monitorGroup.leave() }
            guard let self = self, self.fd >= 0 else { return }
            while self.fd >= 0 && !self.phase2MonitorStopped {
                var pfds = [
                    pollfd(fd: self.fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: self.monitorPipeRead, events: Int16(POLLIN), revents: 0)
                ]
                let pr = poll(&pfds, 2, 100)
                if pr <= 0 { continue }
                if pfds[1].revents & Int16(POLLIN) != 0 { break }
                guard pfds[0].revents & Int16(POLLIN) != 0 else { continue }
                if self.phase2MonitorStopped { break }

                do {
                    let rawData = try self.recvJSON(timeoutMs: 1000)
                    let msg = try ServerMessage.fromJSON(rawData)
                    if case .error = msg {
                        self.phase2Lock.lock()
                        self.phase2Error = msg
                        self.phase2Lock.unlock()
                        return
                    }
                    if case .warning(let code, let message) = msg {
                        fputs("[warning] \(code): \(message)\n", stderr)
                        continue
                    }
                    self.recvLock.lock()
                    var restored = rawData
                    restored.append(UInt8(ascii: "\n"))
                    self.recvBuffer.prepend(restored)
                    self.recvLock.unlock()
                    return
                } catch {
                    return
                }
            }
        }
    }

    public func checkPhase2Error() -> ServerMessage? {
        phase2Lock.lock()
        defer { phase2Lock.unlock() }
        return phase2Error
    }

    public func stopPhase2ErrorMonitor() {
        phase2MonitorStopped = true
        if monitorPipeWrite >= 0 {
            var byte: UInt8 = 0
            _ = Darwin.write(monitorPipeWrite, &byte, 1)
        }
        _ = monitorGroup.wait(timeout: .now() + .milliseconds(1500))
        if monitorPipeRead >= 0 { close(monitorPipeRead); monitorPipeRead = -1 }
        if monitorPipeWrite >= 0 { close(monitorPipeWrite); monitorPipeWrite = -1 }
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

public enum EngineClientError: Error, CustomStringConvertible {
    case notConnected
    case connectionFailed(Int32)
    case connectionClosed
    case timeout
    case jsonTooLarge
    case writeFailed(Int32)
    indirect case systemError(errno: Int32)
    case engineError(String, String)
    indirect case unexpectedMessage(ServerMessage)

    public var description: String {
        switch self {
        case .notConnected:         return "not connected to engine"
        case .connectionFailed(let e): return "connection failed: \(e)"
        case .connectionClosed:     return "connection closed by engine"
        case .timeout:              return "timed out waiting for engine"
        case .jsonTooLarge:         return "JSON message exceeds 64KB"
        case .writeFailed(let e):   return "write failed: \(e)"
        case .systemError(let e):   return "system error: \(e)"
        case .engineError(let c, let m):
            return "engine error: \(c): \(m)"
        case .unexpectedMessage(let m):
            return "unexpected message: \(m)"
        }
    }
}
