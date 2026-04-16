import Foundation
import AppKit
import os

// ---------------------------------------------------------------------------
// EngineManager — @MainActor ObservableObject that owns the engine subprocess
// lifecycle and crash-recovery logic.
//
// ensureRunning():
//   1. Try connect + ping on existing/running engine.
//   2. On failure: remove stale socket file → spawn openverb-engine --listen.
//   3. Poll socket up to 5 s (100 ms intervals) until ping succeeds.
//
// shutdown():
//   Sends session.shutdown via live socket, then closes fd.
//   Falls back to SIGTERM if socket is unresponsive within 1 s.
//
// Crash recovery:
//   Exponential backoff (1 s, 2 s, 4 s).  Three crashes within 60 s →
//   status = .error("Engine keeps crashing…").
//
// Sleep/wake:
//   willSleepNotification  → stop audio → hide window → idle → shutdown.
//   didWakeNotification    → ensureRunning() in background Task.
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "EngineManager")

@MainActor
final class EngineManager: ObservableObject {

    // -----------------------------------------------------------------------
    // Published status
    // -----------------------------------------------------------------------

    enum EngineStatus: Equatable {
        case stopped
        case starting
        case running
        case error(String)

        static func == (lhs: EngineStatus, rhs: EngineStatus) -> Bool {
            switch (lhs, rhs) {
            case (.stopped, .stopped), (.starting, .starting), (.running, .running):
                return true
            case (.error(let l), .error(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    @Published private(set) var status: EngineStatus = .stopped

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    let engineClient: EngineClient
    private var enginePath: String
    private let socketPath: String
    let modelDirPath: String
    /// Injected for unit testing; production code uses `.default`.
    let fileManager: FileManager

    // -----------------------------------------------------------------------
    // Crash recovery state
    // -----------------------------------------------------------------------

    private var crashCounter: Int = 0
    private var firstCrashTime: Date?
    private let crashWindow: TimeInterval = 60.0
    private let maxCrashes = 3
    private var isRecovering = false

    /// Timestamp of the most recent successful ping.
    private var lastSuccessfulConnect: Date?

    // Retry delays (seconds) indexed by attempt number (1-based, capped at 4 s).
    func backoffDelay(attempt: Int) -> Double {
        min(pow(2.0, Double(attempt - 1)), 4.0)
    }

    // -----------------------------------------------------------------------
    // Subprocess tracking
    // -----------------------------------------------------------------------

    private var process: Process?

    // -----------------------------------------------------------------------
    // Init
    // -----------------------------------------------------------------------

    init(socketPath: String = Constants.DEFAULT_SOCKET_PATH,
         enginePath: String? = nil,
         client: EngineClient = EngineClient(),
         modelDirOverride: String? = nil,
         fileManager: FileManager = .default) {
        self.socketPath = socketPath
        self.engineClient = client
        self.enginePath = enginePath ?? EngineManager.resolveEnginePath()
        // Bug 18 fix: honour the user's AppSettings.modelDirectory preference
        // when no explicit override is passed.  Fall back to the compiled-in
        // default only if both the override and the setting are empty.
        let settingsDir = AppSettings.shared.modelDirectory
        self.modelDirPath = modelDirOverride
            ?? (settingsDir.isEmpty ? Constants.DEFAULT_MODEL_DIR : settingsDir)
        self.fileManager = fileManager
        registerSleepWakeNotifications()
    }

    // -----------------------------------------------------------------------
    // Engine binary resolution
    //
    // (1) Bundled copy inside the .app bundle.
    // (2) /usr/local/bin/openverb-engine (installed).
    // Shows NSAlert + exits if neither found.
    // -----------------------------------------------------------------------

    static func resolveEnginePath() -> String {
        // (0) Runtime override via --engine-path command-line argument.
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--engine-path"), idx + 1 < args.count {
            let overridePath = args[idx + 1]
            if FileManager.default.fileExists(atPath: overridePath) {
                return overridePath
            }
            // Explicit override specified but the file is missing — fail fast.
            let alert = NSAlert()
            alert.messageText = "openverb-engine not found at --engine-path"
            alert.informativeText = "Specified path does not exist: \(overridePath)"
            alert.runModal()
            NSApp.terminate(nil)
            return ""  // unreachable
        }

        // (1) Bundled copy inside the .app bundle.
        let bundled = Bundle.main.bundlePath + "/Contents/MacOS/openverb-engine"
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }

        // (2) System-wide installation.
        let installed = "/usr/local/bin/openverb-engine"
        if FileManager.default.fileExists(atPath: installed) {
            return installed
        }

        // (3) Neither found — show alert and exit.
        let alert = NSAlert()
        alert.messageText = "openverb-engine binary not found"
        alert.informativeText = """
            Please install openverb-engine to /usr/local/bin/ or bundle it inside \
            OpenVerb.app/Contents/MacOS/.
            """
        alert.runModal()
        NSApp.terminate(nil)
        return ""  // unreachable
    }

    // -----------------------------------------------------------------------
    // Model existence check
    //
    // Checks for any .gguf file in modelDirPath.  If none is found, shows an
    // NSAlert with the remediation command and terminates the app.  Returns
    // normally only when a model exists.
    // -----------------------------------------------------------------------

    /// Pure filesystem predicate — exposed for unit-testing.
    /// Returns true when at least one .gguf file exists in modelDirPath.
    func ggufModelExists() -> Bool {
        let contents = (try? fileManager.contentsOfDirectory(atPath: modelDirPath)) ?? []
        return contents.contains { $0.hasSuffix(".gguf") }
    }

    /// Launch-time gate: if no model is found, shows NSAlert and terminates.
    /// Callers must not reach past this call when it returns on the failure path.
    func checkModelExists() {
        guard ggufModelExists() else {
            let alert = NSAlert()
            alert.messageText = "Model not found"
            alert.informativeText = "Run: `cp your-model.gguf \(modelDirPath)/`"
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return  // unreachable — satisfies compiler
        }
    }

    // -----------------------------------------------------------------------
    // disconnect — close the underlying socket connection.
    //
    // Call after shutdown() returns or times out.  Centralises fd teardown so
    // callers never need to reach through to engineClient directly.
    // -----------------------------------------------------------------------

    func disconnect() {
        engineClient.disconnect()
    }

    // -----------------------------------------------------------------------
    // ensureRunning — connect or restart engine
    // -----------------------------------------------------------------------

    func ensureRunning() async throws {
        // Fast path: verify the connection is actually live.
        // status can be .running while the socket is closed — this happens
        // after drainResult() calls disconnect() to signal EOF to the engine.
        // A blind return here would let startSession() write to a dead fd.
        if status == .running {
            if await tryPing() { return }
            // Socket closed but engine process still alive — fall through to reconnect.
        }
        // Dedup: another ensureRunning() is already in flight — wait for it
        // rather than racing to spawn a second engine process.
        // All checks and the status = .starting assignment below are synchronous
        // on @MainActor, so no interleave is possible between them.
        guard status != .starting else {
            // #43 (app): add a 10 s timeout so that if the first caller's Task
            // is cancelled without updating status, this loop does not spin forever.
            let spinDeadline = Date().addingTimeInterval(10.0)
            while status == .starting && Date() < spinDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if status != .running { throw EngineManagerError.launchTimeout }
            return
        }
        status = .starting

        // Try existing socket first.
        if await tryPing() {
            status = .running
            lastSuccessfulConnect = Date()
            return
        }

        // #64: terminate the old process before launching a new one.  If the
        // engine is alive but unresponsive (ping failed), replacing self.process
        // without SIGTERM leaks an orphan process consuming memory/GPU.
        sendSIGTERM()
        Self.waitForProcessExit(process, timeout: 0.5)

        // Remove stale socket.
        try? FileManager.default.removeItem(atPath: socketPath)

        // Launch engine subprocess.
        try await launchEngine()

        // Poll up to 5 s.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if await tryPing() {
                status = .running
                lastSuccessfulConnect = Date()
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        status = .error("Engine did not respond within 5 seconds")
        throw EngineManagerError.launchTimeout
    }

    private func tryPing() async -> Bool {
        do {
            try await engineClient.connect(path: socketPath)
            try await engineClient.sendPing()
            return true
        } catch {
            engineClient.disconnect()
            return false
        }
    }

    // -----------------------------------------------------------------------
    // launchEngine — spawn openverb-engine --listen
    // -----------------------------------------------------------------------

    /// Backend override set by restartWithBackend(_:). Passed as --backend arg
    /// to the engine subprocess on the next launchEngine() call.
    private var backendOverride: String?

    private func launchEngine() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: enginePath)
        var args = ["--listen", "--socket", socketPath]
        if let backend = backendOverride {
            args += ["--backend", backend]
        }
        proc.arguments = args

        // Drain stderr asynchronously to prevent pipe-buffer deadlock.
        let pipe = Pipe()
        proc.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in _ = h.availableData }
        proc.terminationHandler = { _ in handle.readabilityHandler = nil }

        try proc.run()
        process = proc
        logger.info("Launched engine PID \(proc.processIdentifier)")
    }

    // -----------------------------------------------------------------------
    // shutdown — STRICT ORDER per spec:
    //   (1) Send session.shutdown on live connection.
    //   (2) Wait up to 1 s for response.
    //   (3) If unresponsive → SIGTERM.
    //   Caller must invoke disconnect() separately after this returns.
    // -----------------------------------------------------------------------

    func shutdown() {
        engineClient.sendShutdown()
        // Do NOT block the MainActor waiting for an ack — the engine is always
        // terminated via SIGTERM below regardless.  The shutdown JSON is a
        // courtesy to let the engine close the client session cleanly; we do
        // not need to read the response.
        //
        // ALWAYS SIGTERM the engine subprocess.  The shutdown JSON only destroys
        // the client session — the listening server process (engine/src/ipc/server.cpp)
        // keeps running.  Without SIGTERM the engine survives app quit / sleep and
        // breaks the lifecycle contract (wake restart, socket reuse, etc.).
        sendSIGTERM()
        // Bug 8 fix: don't block the MainActor spinning RunLoop for up to 500ms.
        // SIGTERM already went out; the actual reap can happen off the main thread.
        let procRef = process
        Task.detached {
            Self.waitForProcessExit(procRef, timeout: 0.5)
        }
        status = .stopped
    }

    private func sendSIGTERM() {
        guard let proc = process, proc.isRunning else { return }
        kill(proc.processIdentifier, SIGTERM)
    }

    nonisolated private static func waitForProcessExit(_ proc: Process?, timeout: TimeInterval) {
        guard let proc = proc else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // -----------------------------------------------------------------------
    // Crash recovery
    // -----------------------------------------------------------------------

    func handleCrash() async throws {
        // Guard against multiple callers racing to start recovery for the same crash
        // (e.g. Phase 2 onError + drainResult() both detecting the same engine death).
        guard !isRecovering else {
            logger.info("handleCrash: recovery already in progress — skipping duplicate")
            return
        }
        isRecovering = true
        defer { isRecovering = false }

        engineClient.disconnect()

        let now = Date()

        // If the engine was stable since the last crash burst, reset entirely.
        if let t = lastSuccessfulConnect, now.timeIntervalSince(t) > crashWindow {
            crashCounter = 0
            firstCrashTime = nil
        }

        if crashCounter == 0 {
            // First crash in a new burst.
            crashCounter = 1
            firstCrashTime = now
        } else if let first = firstCrashTime, now.timeIntervalSince(first) < crashWindow {
            // Within the 60 s window from the first crash.
            crashCounter += 1
            if crashCounter >= maxCrashes {
                let msg = "Engine keeps crashing — try reducing --ctx-size or closing memory-intensive apps"
                status = .error(msg)
                logger.error("\(msg)")
                throw EngineManagerError.crashLoop
            }
        } else {
            // Window expired — start a new burst from this crash.
            crashCounter = 1
            firstCrashTime = now
        }

        let delay = backoffDelay(attempt: crashCounter)
        logger.info("Engine crashed; retrying in \(delay, format: .fixed(precision: 0)) s")
        try await Task.sleep(for: .seconds(delay))
        try await ensureRunning()
    }

    /// Restarts the engine with a new backend selection.
    /// Sets backendOverride so launchEngine() passes --backend to the subprocess,
    /// then shuts down and restarts via ensureRunning().
    func restartWithBackend(_ backend: BackendType) async {
        AppSettings.shared.backend = backend
        backendOverride = backend.rawValue
        status = .starting
        shutdown()
        try? await ensureRunning()
    }

    func resetCrashCounter() {
        crashCounter = 0
        firstCrashTime = nil
    }

    /// Testing helper: simulates recording a crash at a given time.
    /// Mirrors the counter/window logic in handleCrash() without engine restart.
    func simulateCrash(at time: Date) {
        if crashCounter == 0 {
            crashCounter = 1
            firstCrashTime = time
        } else if let first = firstCrashTime, time.timeIntervalSince(first) < crashWindow {
            crashCounter += 1
        } else {
            crashCounter = 1
            firstCrashTime = time
        }
    }

    /// Returns true when 3 or more crashes have been recorded within 60 s of
    /// the first crash in the current burst.
    var isCrashLoopActive: Bool {
        guard crashCounter >= maxCrashes else { return false }
        guard let first = firstCrashTime else { return false }
        return Date().timeIntervalSince(first) < crashWindow
    }

    // -----------------------------------------------------------------------
    // Sleep / wake — UI coordination closures
    //
    // EngineManager owns the NSWorkspace notification registration and the
    // strict-order sleep/wake sequence.  The closures below are set by the
    // app delegate to bridge the UI-layer steps that EngineManager does not
    // own (audio session, recording window, app state).
    // -----------------------------------------------------------------------

    /// Called *before* the engine shutdown sequence begins on sleep.
    /// Must stop audio, hide the recording window, transition to .idle, and
    /// remove Escape monitors — the sleep notification budget is only ~1–3 s.
    var onPreSleep: (() -> Void)?

    /// Called when the engine starts restarting after wake (before
    /// ensureRunning).  Use to show a transient status like "Loading model…".
    var onWakeStarted: (() -> Void)?

    /// Called after ensureRunning() completes (success or failure).
    var onWakeCompleted: (() -> Void)?

    // -----------------------------------------------------------------------
    // Sleep / wake — notification registration & handlers
    //
    // EngineManager registers for NSWorkspace sleep/wake notifications at
    // init time.  The full strict-order sequence is:
    //
    //   Sleep: onPreSleep → sendShutdown → wait/SIGTERM → disconnect
    //   Wake:  status=.starting → onWakeStarted → ensureRunning → onWakeCompleted
    // -----------------------------------------------------------------------

    private var sleepWakeObservers: [NSObjectProtocol] = []

    private func registerSleepWakeNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        let obs1 = nc.addObserver(forName: NSWorkspace.willSleepNotification,
                                  object: nil, queue: .main) { [weak self] _ in
            self?.handleSleep()
        }
        let obs2 = nc.addObserver(forName: NSWorkspace.didWakeNotification,
                                  object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        }
        sleepWakeObservers = [obs1, obs2]
    }

    @objc func handleSleep() {
        // (1) UI teardown (audio stop, window hide, state transition).
        onPreSleep?()
        // (2) Stop the Phase 2 monitor before closing the socket.
        engineClient.stopPhase2Monitor()
        // (3) Disconnect — close the socket fd.
        //     The engine process is intentionally kept alive so the model
        //     stays loaded in memory.  On wake we reconnect without reloading.
        engineClient.disconnect()
        status = .stopped
        logger.info("System sleep — disconnected from engine (process kept alive)")
    }

    @objc func handleWake() {
        logger.info("System wake — reconnecting to engine")
        status = .starting
        onWakeStarted?()
        Task { [weak self] in
            guard let self else { return }
            // Fast path: engine survived sleep, model is still hot.
            if await tryPing() {
                status = .running
                lastSuccessfulConnect = Date()
                logger.info("Engine reconnected after wake — model hot")
            } else {
                // Engine died during sleep (jetsam, etc.) — full restart.
                logger.info("Engine did not survive sleep — restarting")
                do {
                    try await ensureRunning()
                } catch {
                    logger.error("Engine restart after wake failed: \(error)")
                    self.status = .error("Engine failed to restart after wake")
                }
            }
            self.onWakeCompleted?()
        }
    }
}

// ---------------------------------------------------------------------------
// EngineManagerError
// ---------------------------------------------------------------------------

enum EngineManagerError: Error, CustomStringConvertible {
    case launchTimeout
    case crashLoop

    var description: String {
        switch self {
        case .launchTimeout: return "engine did not respond within 5 seconds"
        case .crashLoop:     return "engine crash loop detected"
        }
    }
}
