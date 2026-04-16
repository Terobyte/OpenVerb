import Foundation
import OpenVerbClient

// ---------------------------------------------------------------------------
// main — OpenVerb Swift client entry point.
//
// Usage: openverb-client [--context JSON] [--socket PATH] [--engine-path PATH]
//
// Flow:
//   1. ensureRunning()  — start engine if not running
//   2. connect + startSession → wait for ready
//   3. AudioSession.start() → stream chunks to engine
//   4. Enter / Ctrl-C → AudioSession.stop() → sendEndOfAudio()
//   5. Drain progress/result → print to stdout → exit 0
// ---------------------------------------------------------------------------

private func parseArgs() -> (context: [String: String], socket: String, enginePath: String) {
    var context: [String: String] = [:]
    var socket = EngineManager.defaultSocketPath
    var enginePath = EngineManager.defaultEnginePath

    let args = CommandLine.arguments.dropFirst()
    var i = args.startIndex

    while i < args.endIndex {
        switch args[i] {
        case "--context":
            i += 1
            guard i < args.endIndex else {
                fputs("error: --context requires a JSON argument\n", stderr)
                exit(1)
            }
            if let data = args[i].data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let dict = obj as? [String: String] {
                context = dict
            } else {
                fputs("error: --context must be a JSON object with string values\n", stderr)
                exit(1)
            }
        case "--socket":
            i += 1
            guard i < args.endIndex else {
                fputs("error: --socket requires a path argument\n", stderr)
                exit(1)
            }
            socket = String(args[i])
        case "--engine-path":
            i += 1
            guard i < args.endIndex else {
                fputs("error: --engine-path requires a path argument\n", stderr)
                exit(1)
            }
            enginePath = String(args[i])
        case "--help", "-h":
            print("Usage: openverb-client [--context JSON] [--socket PATH] [--engine-path PATH]")
            exit(0)
        default:
            fputs("error: unknown argument: \(args[i])\n", stderr)
            exit(1)
        }
        i += 1
    }

    return (context, socket, enginePath)
}

private func expandPath(_ path: String) -> String {
    if path.hasPrefix("~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }
    return path
}

// ---------------------------------------------------------------------------
// Signal handling — Ctrl-C triggers end-of-audio instead of immediate exit.
// ---------------------------------------------------------------------------

// #36: sig_atomic_t (Int32 on Darwin) is the only type guaranteed safe for
// signal handler writes.  Plain Bool can be cached by the optimizer, making
// the while-loop spin forever after Ctrl-C in optimized builds.
private var shouldStop: Int32 = 0

private func setupSignalHandler() {
    signal(SIGINT) { _ in
        shouldStop = 1
    }
    signal(SIGTERM) { _ in
        shouldStop = 1
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

do {
    let (context, socket, enginePath) = parseArgs()
    setupSignalHandler()

    let manager = EngineManager(socketPath: socket, enginePath: enginePath)

    func runSession() throws {
        try manager.ensureRunning()

        let expandedSocket = expandPath(socket)

        try manager.client.connect(path: expandedSocket)
        try manager.client.waitForReady(context: context)

        let audioSession = AudioSession()
        // #39: defer ensures audioSession.stop() runs even if sendEndOfAudio()
        // or the Phase 3 drain throws — prevents AVAudioEngine tap leak.
        defer { audioSession.stop() }
        let client = manager.client

        client.startPhase2ErrorMonitor()

        var streamingError: Error?
        try audioSession.start { data in
            if let err = client.checkPhase2Error() {
                streamingError = EngineClientError.unexpectedMessage(err)
                return
            }
            do {
                try client.sendAudioFrame(data)
            } catch {
                streamingError = error
            }
        }

        audioSession.flushPreBuffer()

        while shouldStop == 0 {
            if let err = client.checkPhase2Error() {
                audioSession.stop()
                throw EngineClientError.unexpectedMessage(err)
            }
            if let err = streamingError {
                audioSession.stop()
                throw err
            }

            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 100)
            if pr > 0 && pfd.revents & Int16(POLLIN) != 0 {
                var buf = [UInt8](repeating: 0, count: 256)
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n > 0 { break }
            }
        }

        audioSession.stop()
        client.stopPhase2ErrorMonitor()
        try client.sendEndOfAudio()

        while true {
            let msg = try client.receiveMessage(timeoutMs: 30_000)
            switch msg {
            case .progress(let percent):
                fputs(String(format: "\r[progress] %.0f%%", percent), stderr)
                fflush(stderr)
            case .result(let text, let command):
                fputs("\n", stderr)
                if let text = text, !text.isEmpty {
                    print(text)
                }
                if let cmd = command {
                    fputs("[command] \(cmd.action)\n", stderr)
                }
                return
            case .error(let code, let message):
                throw EngineClientError.engineError(code, message)
            case .warning(let code, let message):
                fputs("[warning] \(code): \(message)\n", stderr)
            default:
                break
            }
        }
    }

    // Restart loop: handleCrash() throws EngineManagerError.crashLoop when it
    // detects 3 crashes within the 60-second window, so we don't need a
    // separate counter here.  We do reset the crash history when the session
    // was stable for a full crash window so that occasional one-off failures
    // don't accumulate toward the limit.
    var sessionStart = Date()
    while true {
        do {
            sessionStart = Date()
            try runSession()
            exit(0)
        } catch let err as EngineClientError {
            switch err {
            case .connectionClosed, .systemError, .writeFailed:
                if Date().timeIntervalSince(sessionStart) >= 60.0 {
                    manager.resetCrashCounter()
                }
                try manager.handleCrash()
            default:
                throw err
            }
        }
    }

} catch let err as EngineManagerError {
    fputs("error: \(err)\n", stderr)
    exit(1)
} catch let err as EngineClientError {
    fputs("error: \(err)\n", stderr)
    exit(1)
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
