import Foundation

// ---------------------------------------------------------------------------
// EngineManager — manages the engine subprocess lifecycle.
//
// ensureRunning() — verifies the engine is alive (connect + ping), launches
//   it if needed, and waits up to 5 seconds for it to become responsive.
// shutdown() — sends session.shutdown or SIGTERM.
//
// Crash recovery: on dropped connection, restarts with exponential backoff
//   (1s, 2s, 4s).  If the engine crashes 3 times within 60 seconds, stops
//   auto-restarting and prints a persistent error to stderr.
// ---------------------------------------------------------------------------

public final class EngineManager {
    public let socketPath: String
    public let enginePath: String
    public let client: EngineClient

    public private(set) var process: Process?
    private var crashTimestamps: [Date] = []
    private let crashWindow: TimeInterval = 60.0
    private let maxCrashes = 3

    // Optional model paths forwarded to the engine subprocess.
    private let modelPath: String?
    private let mmprojPath: String?

    public init(socketPath: String = defaultSocketPath,
                enginePath: String = defaultEnginePath,
                modelPath: String? = nil,
                mmprojPath: String? = nil) {
        self.socketPath = socketPath
        self.enginePath = enginePath
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.client = EngineClient()
    }

    // ---------------------------------------------------------------------------
    // Static defaults
    // ---------------------------------------------------------------------------

    public static var defaultSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.openverb/engine.sock"
    }

    public static var defaultEnginePath: String {
        "/usr/local/bin/openverb-engine"
    }

    // ---------------------------------------------------------------------------
    // expandPath — expand ~ in socket path.
    // ---------------------------------------------------------------------------

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + path.dropFirst()
        }
        return path
    }

    // ---------------------------------------------------------------------------
    // ensureRunning — make sure the engine daemon is alive and reachable.
    // ---------------------------------------------------------------------------

    public func ensureRunning() throws {
        let expanded = expandPath(socketPath)

        // Try to connect + ping.
        if tryPing(expanded: expanded) {
            return
        }

        // Remove stale socket file.
        try? FileManager.default.removeItem(atPath: expanded)

        // Launch engine subprocess.
        try launchEngine()

        // Poll until ping succeeds (up to 5 seconds).
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if tryPing(expanded: expanded) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw EngineManagerError.launchTimeout
    }

    // ---------------------------------------------------------------------------
    // tryPing — attempt connect + ping, return true on success.
    // ---------------------------------------------------------------------------

    private func tryPing(expanded: String) -> Bool {
        do {
            client.disconnect()
            try client.connect(path: expanded)
            try client.ping(timeoutMs: 2000)
            return true
        } catch {
            client.disconnect()
            return false
        }
    }

    // ---------------------------------------------------------------------------
    // launchEngine — spawn the engine --listen subprocess.
    //
    // Passes --model and --mmproj if the corresponding paths were provided
    // at init time.  This lets callers (e.g. integration tests) point the
    // engine at a specific model file without relying on autodiscovery.
    // ---------------------------------------------------------------------------

    private func launchEngine() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: enginePath)
        let expanded = expandPath(socketPath)

        var args = ["--listen", "--socket", expanded]
        if let m = modelPath  { args += ["--model",  m] }
        if let p = mmprojPath { args += ["--mmproj", p] }
        proc.arguments = args

        // Redirect engine stderr through a pipe and drain it asynchronously.
        // Without draining, the pipe buffer (~64 KB on macOS) can fill up and
        // block the engine, or cause a SIGPIPE after the client exits.
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            _ = handle.availableData  // drain and discard
        }
        proc.terminationHandler = { _ in
            stderrHandle.readabilityHandler = nil
        }

        try proc.run()
        process = proc
    }

    // ---------------------------------------------------------------------------
    // shutdown — send session.shutdown or SIGTERM to the engine.
    // ---------------------------------------------------------------------------

    public func shutdown() {
        if client.isConnected {
            do {
                try client.sendShutdown()
            } catch {
                sendSIGTERM()
            }
        } else {
            sendSIGTERM()
        }
        client.disconnect()
    }

    private func sendSIGTERM() {
        guard let proc = process, proc.isRunning else { return }
        kill(proc.processIdentifier, SIGTERM)
    }

    // ---------------------------------------------------------------------------
    // Crash recovery
    // ---------------------------------------------------------------------------

    public func handleCrash() throws {
        client.disconnect()
        recordCrash()

        if crashTimestamps.count >= maxCrashes {
            let oldest = crashTimestamps[crashTimestamps.count - maxCrashes]
            if Date().timeIntervalSince(oldest) < crashWindow {
                fputs("Engine keeps crashing — try reducing --ctx-size or closing memory-intensive apps\n",
                      stderr)
                throw EngineManagerError.crashLoop
            }
        }

        // Exponential backoff: 1s, 2s, 4s
        let backoff = min(pow(2.0, Double(crashTimestamps.count - 1)), 4.0)
        Thread.sleep(forTimeInterval: backoff)

        try ensureRunning()
    }

    private func recordCrash() {
        crashTimestamps.append(Date())
        // Prune timestamps older than the crash window.
        let cutoff = Date().addingTimeInterval(-crashWindow)
        crashTimestamps = crashTimestamps.filter { $0 > cutoff }
    }

    public func resetCrashCounter() {
        crashTimestamps.removeAll()
    }

    // ---------------------------------------------------------------------------
    // waitForTermination — wait for the engine process to exit.
    // ---------------------------------------------------------------------------

    public func waitForTermination() {
        process?.waitUntilExit()
    }
}

public enum EngineManagerError: Error, CustomStringConvertible {
    case launchTimeout
    case crashLoop

    public var description: String {
        switch self {
        case .launchTimeout: return "engine did not respond within 5 seconds"
        case .crashLoop:     return "engine crash loop detected"
        }
    }
}
