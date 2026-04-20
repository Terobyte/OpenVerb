import Foundation
import os

// ---------------------------------------------------------------------------
// EngineClient — async/await Unix-domain-socket client for the engine IPC.
//
// Design: class (NOT actor) — sendAudioFrame() must be callable synchronously
// from the AVAudioEngine tap callback (background audio thread) without await.
//
// Thread safety:
//   • fd is wrapped behind `fdLock` (Bug 5) — writes happen on ioQueue
//     (connectSync / disconnect); reads also happen from the Phase 2 monitor's
//     detached Task inside recvJSONSync, so the Int32 itself needs locked access.
//   • recvBuffer is protected by recvLock.
//   • sendAudioFrame dispatches fire-and-forget onto ioQueue.
//   • phase2Error is protected by phase2Lock (NSLock).
//   • onError closure must capture [weak self] to prevent retain cycles.
//
// Wire protocol (same as engine's IPC server):
//   Phase 1 : JSON (session.start → ready, ping/pong)
//   Phase 2 : binary frames (4-byte big-endian length + payload)
//   Phase 3 : JSON (progress, result, error, warning)
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "EngineClient")

final class EngineClient {

    // -----------------------------------------------------------------------
    // Private state
    // -----------------------------------------------------------------------

    /// Bug 5: storage for the socket fd is wrapped behind `fdLock` so concurrent
    /// readers (Phase 2 monitor's detached Task calling recvJSONSync) and the
    /// ioQueue writer (connectSync / disconnect) never race on the Int32 itself.
    /// The `fd` computed property below provides transparent locked access so
    /// existing call sites do not need to change.
    private let fdLock = NSLock()
    private var _fd: Int32 = -1
    private var fd: Int32 {
        get { fdLock.lock(); defer { fdLock.unlock() }; return _fd }
        set { fdLock.lock(); defer { fdLock.unlock() }; _fd = newValue }
    }

    private var recvBuffer = RecvAccumulator()
    private let recvLock = NSLock()

    /// Serializes the poll()+read(fd)+append() syscall cycle inside recvJSONSync.
    /// Bug 28: without this, drainResult (ioQueue) and the Phase 2 monitor
    /// (detached Task) race on read(fd) and can split a single JSON message's
    /// bytes between them, producing two undecodable halves.
    private let socketReadLock = NSLock()

    /// Serial queue for all fd write operations and connect/disconnect.
    private let ioQueue = DispatchQueue(label: "io.openverb.engineclient",
                                        qos: .userInitiated)

    // Phase 2 concurrent error monitoring
    private var phase2Error: ServerMessage?
    private let phase2Lock = NSLock()
    private var phase2MonitorTask: Task<Void, Never>?
    private var phase2MonitorStopped = false

    // Wakeup pipe used to interrupt the phase2 poll loop quickly.
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    /// Called when an error or fatal warning arrives during Phase 2 streaming.
    /// Caller MUST capture [weak self] in the closure to avoid retain cycles.
    var onError: ((ServerMessage) -> Void)?

    /// Called each time a partial_result message arrives from the engine.
    /// (text, chunkId, isFinal)
    var onPartialResult: ((String, Int, Bool) -> Void)?

    /// Called each time a queue_status message arrives from the engine.
    /// (pending, inFlight, etaMs) — inFlight is true when the worker is actively processing a chunk.
    var onQueueStatus: ((Int, Bool, Int) -> Void)?

    /// Called when the engine's LLM polish pass has produced a cleaned transcript.
    /// The caller should replace the pending injected text with the polished version.
    var onPolishedResult: ((String) -> Void)?

    // -----------------------------------------------------------------------
    // RecvAccumulator — buffers partial reads across receiveMessage() calls.
    // -----------------------------------------------------------------------

    // RecvAccumulator — grows dynamically; no hard cap.
    // Long dictation results from Whisper can exceed many kilobytes of JSON,
    // so capping at a fixed size would cause spurious failures.
    private struct RecvAccumulator {
        var data = Data()

        mutating func append(_ chunk: Data) {
            data.append(chunk)
        }

        mutating func extractMessage() -> Data? {
            guard let idx = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            let msg = Data(data[data.startIndex..<idx])
            data = Data(data[data.index(after: idx)...])
            return msg
        }

        mutating func prepend(_ prefix: Data) {
            var combined = prefix
            combined.append(data)
            data = combined
        }
    }

    // -----------------------------------------------------------------------
    // Connect / disconnect
    // -----------------------------------------------------------------------

    func connect(path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try self.connectSync(path: path)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func connectSync(path: String) throws {
        // Bug 119 fix: clear the receive buffer unconditionally so stale bytes
        // from any prior session are never returned as the first message of a
        // new session, even when fd != -1 (already-connected early return).
        recvLock.lock()
        recvBuffer = RecvAccumulator()
        recvLock.unlock()

        guard fd == -1 else { return }  // already connected

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw EngineClientError.systemError(errno: errno) }

        // Prevent SIGPIPE on this socket — write() returns EPIPE instead.
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // #23: validate path length before writing to sun_path (104-byte buffer).
        guard path.utf8.count < 104 else {
            close(sock)
            throw EngineClientError.connectionFailed(ENAMETOOLONG)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        path.withCString { p in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
                dst.update(from: p, count: strlen(p) + 1)
            }
        }

        let result = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let e = errno; close(sock)
            throw EngineClientError.connectionFailed(e)
        }

        // Set O_NONBLOCK so that write() returns EAGAIN when the kernel send buffer
        // is full (backpressure for sendAudioFrame) rather than blocking ioQueue.
        var flags = fcntl(sock, F_GETFL, 0)
        if flags < 0 { flags = 0 }
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        fd = sock
        recvLock.lock()
        recvBuffer = RecvAccumulator()
        recvLock.unlock()
    }

    func disconnect() {
        ioQueue.async {
            // #41: move the wakeup write inside ioQueue to eliminate the TOCTOU
            // race where the caller's thread checks wakeWrite >= 0 concurrently
            // with the monitor's defer closing it.  Writing before close(fd) also
            // ensures the monitor sees the signal before a POLLHUP from fd close.
            if self.wakeWrite >= 0 {
                var b: UInt8 = 0
                _ = Darwin.write(self.wakeWrite, &b, 1)
                // Bug 12 fix: clear the wake fds only AFTER the signal byte was
                // delivered.  Previously stopPhase2Monitor() cleared them first,
                // causing disconnect() to see wakeWrite < 0 and skip the signal.
                self.wakeWrite = -1
                self.wakeRead  = -1
            }
            guard self.fd >= 0 else { return }
            close(self.fd)
            self.fd = -1
            self.recvLock.lock()
            self.recvBuffer = RecvAccumulator()
            self.recvLock.unlock()
        }
    }

    // Bug 120 fix: read fd via fdLock instead of ioQueue.sync. Calling ioQueue.sync
    // from the MainActor deadlocks if any ioQueue block dispatches back to MainActor.
    // fdLock is a plain NSLock — no actor hop needed.
    var isConnected: Bool { fd >= 0 }

    // -----------------------------------------------------------------------
    // Low-level write helpers (called from ioQueue)
    // -----------------------------------------------------------------------

    // writeFully — used for JSON control messages (session.start, ping, shutdown).
    // Must never leave a partial frame on the wire.  On EAGAIN, polls up to 50 ms
    // for the send buffer to drain, then retries.  The audio-frame path uses
    // writeAudioFrameOrDrop() instead.
    private func writeFully(_ buffer: UnsafeRawPointer, count: Int) throws {
        var remaining = count
        var ptr = buffer
        while remaining > 0 {
            let n = write(fd, ptr, remaining)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // Poll up to 50 ms for the send buffer to drain, then retry.
                    // Control messages are short and rare; blocking briefly is fine.
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 50)
                    continue
                }
                let e = errno
                // EPIPE and ECONNRESET both mean the peer closed the connection.
                if e == EPIPE || e == ECONNRESET { throw EngineClientError.connectionClosed }
                throw EngineClientError.writeFailed(e)
            }
            guard n > 0 else { throw EngineClientError.connectionClosed }
            ptr = ptr.advanced(by: n)
            remaining -= n
        }
    }

    // writeAudioFrameOrDrop — writes a complete audio frame (4-byte header + payload)
    // as a single logical unit.  Returns false if EAGAIN fires before any bytes are
    // written (safe to drop the whole frame — brief audio glitch is acceptable).
    // Throws connectionClosed if EAGAIN fires after a partial write, because the
    // stream is already corrupted at that point.
    @discardableResult
    private func writeAudioFrameOrDrop(header: [UInt8], payload: Data) throws -> Bool {
        var combined = Data(header)
        combined.append(payload)
        return try combined.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base.advanced(by: offset), remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        if offset == 0 {
                            // No bytes written yet — safe to drop the entire frame.
                            logger.warning("Audio frame dropped: socket send buffer full (backpressure)")
                            return false
                        }
                        // Partial bytes already on the wire — stream corrupted.
                        logger.error("Audio frame: partial write (\(offset) B) before EAGAIN — closing")
                        throw EngineClientError.connectionClosed
                    }
                    let e = errno
                    if e == EPIPE || e == ECONNRESET { throw EngineClientError.connectionClosed }
                    throw EngineClientError.writeFailed(e)
                }
                guard n > 0 else { throw EngineClientError.connectionClosed }
                offset += n
                remaining -= n
            }
            return true
        }
    }

    private func sendJSONSync<T: Encodable>(_ msg: T) throws {
        guard fd >= 0 else { throw EngineClientError.notConnected }
        var data = try JSONEncoder().encode(msg)
        data.append(UInt8(ascii: "\n"))
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeFully(base, count: raw.count)
        }
    }

    // -----------------------------------------------------------------------
    // Receive helpers (called from ioQueue or a dedicated background Task)
    // -----------------------------------------------------------------------

    private func recvJSONSync(timeoutMs: Int = 15_000) throws -> Data {
        guard fd >= 0 else { throw EngineClientError.notConnected }

        // Return any already-buffered message first.
        recvLock.lock()
        if let msg = recvBuffer.extractMessage() {
            recvLock.unlock(); return msg
        }
        recvLock.unlock()

        // Bug 28: serialize the poll()+read(fd)+append() cycle so two entrants
        // (ioQueue drainResult + detached Phase 2 monitor) cannot split a
        // single message's bytes between them.
        socketReadLock.lock()

        // Re-check buffer: another caller may have drained a whole message into
        // recvBuffer while we were blocked on socketReadLock. Handing it back
        // without entering poll() preserves FIFO delivery.
        recvLock.lock()
        if let msg = recvBuffer.extractMessage() {
            recvLock.unlock()
            socketReadLock.unlock()
            return msg
        }
        recvLock.unlock()

        // fd may have been closed by disconnect() while we waited.
        guard fd >= 0 else {
            socketReadLock.unlock()
            throw EngineClientError.notConnected
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var chunk = [UInt8](repeating: 0, count: 4096)

        // Bug 76: release socketReadLock before entering the blocking poll loop.
        // Holding it across the full timeoutMs (up to 180 s for drainResult) would
        // prevent the Phase 2 monitor from acquiring it within its 100 ms window,
        // effectively disabling crash detection for the entire inference window.
        socketReadLock.unlock()

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw EngineClientError.timeout }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(remaining * 1000))
            if pr == 0 { throw EngineClientError.timeout }
            if pr < 0 { throw EngineClientError.systemError(errno: errno) }
            // Bug 27: check POLLIN BEFORE treating POLLHUP/POLLERR as EOF.
            // poll() can return revents = POLLIN | POLLHUP when the engine
            // writes its final message and immediately closes the socket —
            // throwing connectionClosed on POLLHUP first would discard the
            // unread bytes still sitting in the kernel's receive buffer.
            // The actual EOF signal is read() returning 0 (handled below).
            guard pfd.revents & Int16(POLLIN) != 0 else {
                if pfd.revents & Int16(POLLHUP | POLLERR) != 0 {
                    throw EngineClientError.connectionClosed
                }
                continue
            }

            let currentFd = fd  // Bug 95: snapshot fd once under implicit lock before read()
            let n = read(currentFd, &chunk, chunk.count)
            if n == 0 { throw EngineClientError.connectionClosed }
            if n < 0 {
                let e = errno
                // EAGAIN/EWOULDBLOCK: O_NONBLOCK socket; poll indicated data but
                // read raced — loop back to poll rather than treating it as fatal.
                if e == EAGAIN || e == EWOULDBLOCK { continue }
                // ECONNRESET means the peer forcibly closed the connection.
                if e == ECONNRESET { throw EngineClientError.connectionClosed }
                throw EngineClientError.systemError(errno: e)
            }

            recvLock.lock()
            recvBuffer.append(Data(chunk[0..<n]))
            if let msg = recvBuffer.extractMessage() {
                recvLock.unlock()
                return msg
            }
            recvLock.unlock()
        }
    }

    // -----------------------------------------------------------------------
    // Public session management (async)
    // -----------------------------------------------------------------------

    /// Send session.start and wait for session.ready.
    func startSession(context: [String: String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try self.sendJSONSync(SessionStart(context: context))
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Receive one JSON message from the engine.
    /// NOTE: Does NOT forward `.error` messages through `onError`.  The Phase 2
    /// monitor calls `onError` directly for mid-stream errors.  Callers that
    /// receive errors via this method (connectAndRecord, drainResult) handle
    /// them in their own error-handling paths — forwarding here would cause
    /// duplicate crash recovery and unnecessary engine restarts.
    func receiveMessage(timeoutMs: Int = 30_000) async throws -> ServerMessage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ServerMessage, Error>) in
            ioQueue.async {
                do {
                    let data = try self.recvJSONSync(timeoutMs: timeoutMs)
                    if data.first != UInt8(ascii: "{") {
                        cont.resume(throwing: EngineClientError.protocolViolation)
                        return
                    }
                    let msg = try ServerMessage.fromJSON(data)
                    cont.resume(returning: msg)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Send ping and wait up to 5 seconds for pong.
    func sendPing() async throws {
        // Write the ping JSON on ioQueue.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                do {
                    try self.sendJSONSync(Ping())
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        // Wait up to 5 s for the pong response.
        let msg = try await receiveMessage(timeoutMs: 5_000)
        guard case .pong = msg else {
            throw EngineClientError.unexpectedMessage(msg)
        }
    }

    // -----------------------------------------------------------------------
    // sendShutdown — fire-and-forget (called from any context)
    // -----------------------------------------------------------------------

    func sendShutdown() {
        ioQueue.async {
            try? self.sendJSONSync(Shutdown())
        }
    }

    // -----------------------------------------------------------------------
    // sendAudioFrame — SYNCHRONOUS; called from AVAudioEngine tap (audio thread).
    //
    // Dispatches fire-and-forget onto ioQueue.  Do NOT use queue.sync here —
    // the audio thread must never block.  If the kernel send buffer is full,
    // writeFully logs and drops the frame (brief audio glitch is acceptable).
    // -----------------------------------------------------------------------

    func sendAudioFrame(_ data: Data) {
        guard data.count > 0 else { return }
        // Abort the write loop before each frame if Phase 2 monitor detected an error.
        phase2Lock.lock()
        let hasPhase2Error = phase2Error != nil
        phase2Lock.unlock()
        guard !hasPhase2Error else { return }
        let copy = data  // capture by value
        ioQueue.async {
            guard self.fd >= 0 else { return }
            let len = UInt32(copy.count)
            let header: [UInt8] = [
                UInt8((len >> 24) & 0xFF),
                UInt8((len >> 16) & 0xFF),
                UInt8((len >>  8) & 0xFF),
                UInt8( len        & 0xFF),
            ]
            do {
                // writeAudioFrameOrDrop writes header+payload as a single unit.
                // Returns false (log already emitted) if the frame was dropped.
                _ = try self.writeAudioFrameOrDrop(header: header, payload: copy)
            } catch {
                logger.error("sendAudioFrame failed: \(error)")
            }
        }
    }

    /// Send the end-of-audio sentinel: four zero bytes.
    func sendEndOfAudio() {
        ioQueue.async {
            guard self.fd >= 0 else { return }
            var sentinel: [UInt8] = [0, 0, 0, 0]
            try? sentinel.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                try self.writeFully(base, count: raw.count)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Phase 2 concurrent error monitoring.
    //
    // A detached background Task polls the socket (100 ms interval).  If the
    // engine sends an error or warning mid-stream, it sets phase2Error and
    // calls onError so the UI can react.  The write loop checks phase2Error
    // before each sendAudioFrame via checkPhase2Error().
    // -----------------------------------------------------------------------

    /// Bug 32 fix: execute a synchronous fence on ioQueue to guarantee all
    /// previously-dispatched sendAudioFrame writes complete before any live
    /// audio frame can overtake them on the serial queue.
    func syncOnIOQueue() {
        ioQueue.sync {}
    }

    func startPhase2Monitor() {
        // #21: protect phase2MonitorStopped with phase2Lock — it is written
        // here (MainActor) and read from a detached background Task.
        phase2Lock.lock()
        phase2Error = nil
        phase2MonitorStopped = false
        phase2Lock.unlock()

        // Create a wakeup pipe so stopPhase2Monitor() can interrupt poll()
        // immediately rather than waiting for the 100 ms timeout.
        var pipefds: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipefds) == 0 else { return }
        let rfd = pipefds[0]
        let wfd = pipefds[1]
        _ = fcntl(rfd, F_SETFL, O_NONBLOCK)

        // Bug 77: serialise wakeRead/wakeWrite assignments on ioQueue so all
        // accesses (writes here, reads in disconnect/stopPhase2Monitor) run on
        // the same queue and cannot race across threads.
        ioQueue.sync {
            wakeRead  = rfd
            wakeWrite = wfd
        }

        // #22: capture the pipe fds as local constants so the task's defer
        // closes the fds it opened — not self.wakeRead/wakeWrite, which a
        // subsequent startPhase2Monitor() may have already overwritten with
        // a new pipe.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer { close(rfd); close(wfd) }
            guard let self else { return }
            await self.runPhase2Monitor(wakeReadFD: rfd)
        }
        phase2MonitorTask = task
    }

    private func runPhase2Monitor(wakeReadFD: Int32) async {
        // #21: read phase2MonitorStopped under phase2Lock throughout the loop.
        phase2Lock.lock()
        var stopped = phase2MonitorStopped
        phase2Lock.unlock()

        while !stopped && ioQueue.sync(execute: { self.fd >= 0 }) {
            // poll(fd, POLLIN, 100 ms) + wakeup pipe
            let currentFd = ioQueue.sync(execute: { self.fd })
            var pfds = [
                pollfd(fd: currentFd,   events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeReadFD,  events: Int16(POLLIN), revents: 0),
            ]
            let pr = poll(&pfds, 2, 100)
            if pr <= 0 {
                phase2Lock.lock()
                stopped = phase2MonitorStopped
                phase2Lock.unlock()
                continue
            }
            if pfds[1].revents & Int16(POLLIN) != 0 { break }  // wakeup signal
            // Bug 75: check POLLIN before POLLHUP so a message written just before
            // socket close is never discarded. When the engine writes its final
            // message and closes the socket simultaneously, poll() sets both POLLIN
            // and POLLHUP. We must drain POLLIN first, then treat HUP as fatal.
            guard pfds[0].revents & Int16(POLLIN) != 0 else {
                // No data — check if the connection dropped with no pending data.
                if pfds[0].revents & Int16(POLLHUP | POLLERR) != 0 {
                    logger.error("Phase 2 monitor: engine connection dropped (POLLHUP/POLLERR)")
                    let errMsg = ServerMessage.error(code: "connection_closed",
                                                     message: "Engine connection dropped mid-recording")
                    callOnErrorIfLive(errMsg)
                    return
                }
                phase2Lock.lock()
                stopped = phase2MonitorStopped
                phase2Lock.unlock()
                continue
            }

            phase2Lock.lock()
            stopped = phase2MonitorStopped
            phase2Lock.unlock()
            if stopped { break }

            // Data available — read one message.
            // #20: use 100 ms timeout (matching the outer poll) so stopPhase2Monitor()
            // is never blocked for more than 200 ms waiting for this read to return.
            let data: Data
            do {
                data = try recvJSONSync(timeoutMs: 100)
            } catch {
                logger.error("Phase 2 monitor: fatal read error — aborting stream: \(error)")
                // Bug 17: callOnErrorIfLive re-checks phase2MonitorStopped so an
                // intentional disconnect() (which closes fd and causes recvJSONSync
                // to throw) does not surface as a spurious error.
                let errMsg = ServerMessage.error(code: "stream_read_error",
                                                 message: "Phase 2 monitor read failed: \(error)")
                callOnErrorIfLive(errMsg)
                return
            }

            guard data.first == UInt8(ascii: "{") else {
                logger.error("Phase 2 monitor: fatal protocol violation — non-JSON byte — aborting stream")
                let errMsg = ServerMessage.error(code: "protocol_violation",
                                                 message: "Unexpected non-JSON byte in Phase 2 stream")
                callOnErrorIfLive(errMsg)
                return
            }

            let msg: ServerMessage
            do {
                msg = try ServerMessage.fromJSON(data)
            } catch {
                logger.warning("Phase 2 monitor JSON decode error: \(error)")
                phase2Lock.lock()
                stopped = phase2MonitorStopped
                phase2Lock.unlock()
                continue
            }

            switch msg {
            case .error:
                // Bug 17: use helper so a late .error arriving after
                // stopPhase2Monitor() does not fire onError spuriously.
                callOnErrorIfLive(msg)
                return

            case .warning(let code, let message):
                logger.warning("Engine warning: \(code): \(message)")
                // Continue streaming — warning does not end the session.

            default:
                if case .partialResult(let text, let chunkId, let isFinal) = msg {
                    // Bug 98 fix: only forward partials from the phase 2 monitor
                    // when the monitor is still active (not stopped). drainResult
                    // delivers any partials buffered after the monitor stops,
                    // preventing double-delivery of the same message.
                    phase2Lock.lock()
                    let alreadyStopped = phase2MonitorStopped
                    phase2Lock.unlock()
                    if !alreadyStopped {
                        onPartialResult?(text, chunkId, isFinal)  // Bug 55 / Bug 98
                    }
                } else {
                    recvLock.lock()
                    var r = data; r.append(UInt8(ascii: "\n"))
                    recvBuffer.prepend(r); recvLock.unlock()
                }
                continue  // Bug 56: poll next, don't re-read just-prepended msg
            }

            phase2Lock.lock()
            stopped = phase2MonitorStopped
            phase2Lock.unlock()
        }
    }

    func checkPhase2Error() -> ServerMessage? {
        phase2Lock.lock()
        defer { phase2Lock.unlock() }
        return phase2Error
    }

    /// Bug 17: invoke onError only if the monitor hasn't been stopped yet.
    /// Re-reads phase2MonitorStopped under phase2Lock to close the race where
    /// stopPhase2Monitor() flipped the flag while we were mid-message. Also
    /// stores phase2Error atomically with the stopped check so the two fields
    /// never disagree.
    private func callOnErrorIfLive(_ msg: ServerMessage) {
        phase2Lock.lock()
        let stopped = phase2MonitorStopped
        if !stopped { phase2Error = msg }
        phase2Lock.unlock()
        if stopped { return }
        onError?(msg)
    }

    func stopPhase2Monitor() {
        // #21: write under phase2Lock.
        phase2Lock.lock()
        phase2MonitorStopped = true
        phase2Lock.unlock()

        // Bug 33 fix: dispatch the wakeup write via ioQueue so that all
        // accesses to wakeWrite/wakeRead are serialised on one queue.
        // Previously this read wakeWrite directly on MainActor while
        // disconnect() wrote wakeWrite = -1 on ioQueue — undefined behaviour.
        ioQueue.async { [self] in
            if wakeWrite >= 0 {
                var b: UInt8 = 0
                _ = Darwin.write(wakeWrite, &b, 1)
            }
        }
        // #19: do NOT block waiting for the monitor task to finish.
        // phase2MonitorStopped=true prevents it from processing further data.
        // The task exits within ~200 ms (one poll + one recvJSONSync cycle).
        // Pipe fds are closed by the task's defer in startPhase2Monitor().
        //
        // Bug 12 fix: do NOT clear wakeRead / wakeWrite here.  disconnect()
        // may run right after stopPhase2Monitor() and also needs to write a
        // wakeup byte; clearing the fd to -1 here would make disconnect()
        // skip its signal and leave the monitor blocked in poll() for up to
        // 100 ms.  disconnect() now owns the fd reset after its own wakeup
        // write completes.
        phase2MonitorTask?.cancel()
        phase2MonitorTask = nil
    }
}

// ---------------------------------------------------------------------------
// EngineClientError
// ---------------------------------------------------------------------------

enum EngineClientError: Error, CustomStringConvertible {
    case notConnected
    case connectionFailed(Int32)
    case connectionClosed
    case timeout
    case jsonTooLarge
    case writeFailed(Int32)
    case protocolViolation
    indirect case systemError(errno: Int32)
    indirect case unexpectedMessage(ServerMessage)
    case engineError(String, String)

    var description: String {
        switch self {
        case .notConnected:              return "not connected to engine"
        case .connectionFailed(let e):  return "connection failed: errno \(e)"
        case .connectionClosed:         return "connection closed by engine"
        case .timeout:                  return "timed out waiting for engine"
        case .jsonTooLarge:             return "JSON message exceeds 64 KB"
        case .writeFailed(let e):       return "write failed: errno \(e)"
        case .protocolViolation:        return "protocol violation: unexpected non-JSON byte"
        case .systemError(let e):       return "system error: errno \(e)"
        case .unexpectedMessage(let m): return "unexpected message: \(m)"
        case .engineError(let c, let m): return "engine error \(c): \(m)"
        }
    }
}
