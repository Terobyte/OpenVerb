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
    // Serialises the poll+read loop — prevents the Phase 2 monitor and a Phase 3
    // caller from both calling read(fd) concurrently, splitting the byte stream.
    private let readSerializerLock = NSLock()

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

        // #24: sun_path is only 104 bytes; overflow silently truncates the path,
        // connecting to the wrong (or garbage) socket without error.
        guard path.utf8.count < 104 else {
            close(socketFD)
            throw EngineClientError.connectionFailed(ENAMETOOLONG)
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
        // Stop the Phase 2 monitor before closing fd — the monitor may be blocked
        // in read(fd); closing first leaves it reading from a closed or kernel-reused fd.
        // stopPhase2ErrorMonitor() also closes the wakeup pipe fds.
        stopPhase2ErrorMonitor()
        close(fd)
        fd = -1
        recvLock.lock()
        recvBuffer = RecvAccumulator()
        recvLock.unlock()
    }

    public var isConnected: Bool { fd >= 0 }

    // ---------------------------------------------------------------------------
    // JSON send helpers
    // ---------------------------------------------------------------------------

    // writeFully — must be called from a single thread at a time.
    // sendJSON and sendAudioFrame both call this; the caller is responsible for
    // ensuring they are not invoked concurrently.  In the normal flow main.swift
    // calls these sequentially (no concurrent writers), so no lock is needed here.
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

        // Serialise the entire poll+read loop: the Phase 2 monitor (readQueue)
        // and Phase 3 callers (main thread) must never call read(fd) concurrently
        // — the kernel would split the byte stream between them, fragmenting both.
        readSerializerLock.lock()
        defer { readSerializerLock.unlock() }

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
            // #43: clamp to valid Int32 range; negative remaining would make
            // poll() block indefinitely, and values > Int32.max crash in Swift.
            let pollTimeout = Int32(max(0, min(remaining, Double(Int32.max))))
            let pr = poll(&pfd, 1, pollTimeout)
            guard pr > 0 else {
                if pr == 0 { throw EngineClientError.timeout }
                throw EngineClientError.systemError(errno: errno)
            }
            // #37: POLLHUP/POLLERR without POLLIN means the peer closed the
            // connection; translate to connectionClosed rather than systemError.
            if pfd.revents & (Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                throw EngineClientError.connectionClosed
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
        guard Darwin.pipe(&pipefds) == 0 else {
            fputs("[warning] EngineClient: pipe() failed — phase 2 error monitoring disabled\n", stderr)
            return
        }
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
                    // #38: unexpected message type during Phase 2 — discard and
                    // keep monitoring.  Using return here would exit permanently,
                    // causing any subsequent .error to go undetected.
                    continue
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
