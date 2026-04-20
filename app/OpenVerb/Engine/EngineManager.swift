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
    private let modelDirOverride: String?
    var modelDirPath: String {
        let dir = AppSettings.shared.modelDirectory
        return modelDirOverride ?? (dir.isEmpty ? Constants.DEFAULT_MODEL_DIR : dir)
    }
    /// Injected for unit testing; production code uses `.default`.
    let fileManager: FileManager

    /// Bug 25: defense-in-depth guard for `restartWithBackend`. Returns true
    /// when the caller is allowed to proceed. Injected by AppDelegate to bind
    /// `appState.state == .idle`. nil closure ≡ "always allow" for tests.
    var canRestartBackend: (() -> Bool)?

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
        self.modelDirOverride = modelDirOverride
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
            // Bug 45 fix: cap at 2 s (was 10 s) so that if the first caller's
            // Task stalls (engine launched but never responds to ping), the
            // MainActor is frozen for at most 2 s instead of 10 s.
            let spinDeadline = Date().addingTimeInterval(2.0)
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
        // Bug 96 fix: move the wait off the main actor so the RunLoop spin in
        // waitForProcessExit does not block MainActor for up to 500 ms on every
        // cold-start or crash-recovery.
        let procToWait = process
        await Task.detached { Self.waitForProcessExit(procToWait, timeout: 0.5) }.value

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

    func shutdown() async {
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
        // Bug 74/80 fix: await process exit directly so restartWithBackend() can
        // await shutdown() and be certain the old process is gone before calling
        // ensureRunning(). This prevents tryPing() from succeeding against the
        // still-alive old engine and silently skipping the backend switch.
        let procRef = process
        await Task.detached {
            Self.waitForProcessExit(procRef, timeout: 0.5)
        }.value
        status = .stopped
    }

    private func sendSIGTERM() {
        guard let proc = process, proc.isRunning else { return }
        kill(proc.processIdentifier, SIGTERM)
    }

    nonisolated private static func waitForProcessExit(_ proc: Process?, timeout: TimeInterval) {
        guard let proc = proc else { return }
        let deadline = Date().addingTimeInterval(timeout)
        // Bug 114 fix: use Thread.sleep instead of RunLoop spin.
        // A cooperative thread has no run-loop sources so the old RunLoop-based
        // approach was a pure busy-wait that burned the pool slot for 500 ms.
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // -----------------------------------------------------------------------
    // Crash recovery
    // -----------------------------------------------------------------------

    func handleCrash() async throws {
        // Guard against multiple callers racing to start recovery for the same crash
        // (e.g. Phase 2 onError + drainResult() both detecting the same engine death).
        // Bug 97 fix: throw instead of silently returning so callers can distinguish
        // "already recovering" from "recovery was initiated by me" and can check
        // engine status themselves rather than assuming recovery is progressing.
        guard !isRecovering else {
            logger.info("handleCrash: recovery already in progress — skipping duplicate")
            throw EngineManagerError.recoveryInProgress
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
        // Bug 51: skip pre-warm if a new session started during the sleep.
        // Pinging an active session's socket injects JSON into the binary
        // PCM stream, corrupting the protocol (engine reads 4 bytes of the
        // ping JSON as a frame length ≈ 2 GB and blocks indefinitely).
        guard canRestartBackend?() ?? true else {
            logger.info("handleCrash: session active — skipping pre-warm ping")
            return
        }
        try await ensureRunning()
    }

    /// Restarts the engine with a new backend selection.
    /// Sets backendOverride so launchEngine() passes --backend to the subprocess,
    /// then shuts down and restarts via ensureRunning().
    func restartWithBackend(_ backend: BackendType) async {
        // Bug 25: refuse restart while a session is active. UI should have
        // disabled the Preferences picker, but programmatic callers (tests,
        // future MCP hooks, auto-switch suggestions) are guarded here.
        guard canRestartBackend?() ?? true else {
            logger.warning("restartWithBackend skipped: session active")
            return
        }
        AppSettings.shared.backend = backend
        backendOverride = backend.rawValue
        status = .starting
        await shutdown()
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
        // Bug 111 fix: set .stopped only after disconnect completes, via an
        // awaited Task, so handleWake() cannot observe fd as half-open while
        // status is already .stopped and incorrectly skip reconnect verification.
        Task { [weak self] in
            guard let self else { return }
            self.engineClient.disconnect()
            await Task.yield()  // ensure disconnect's ioQueue.async has been dispatched
            self.status = .stopped
            logger.info("System sleep — disconnected from engine (process kept alive)")
        }
    }

    @objc func handleWake() {
        logger.info("System wake — reconnecting to engine")
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
    /// Bug 97 fix: thrown by handleCrash() when a recovery is already in progress,
    /// so duplicate callers can detect they did not trigger recovery and act accordingly.
    case recoveryInProgress

    var description: String {
        switch self {
        case .launchTimeout:      return "engine did not respond within 5 seconds"
        case .crashLoop:          return "engine crash loop detected"
        case .recoveryInProgress: return "crash recovery already in progress"
        }
    }
}
