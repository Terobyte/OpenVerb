import SwiftUI
import AppKit
import AVFoundation
import Combine
import os

// ---------------------------------------------------------------------------
// OpenVerbApp — SwiftUI @main entry point.
//
// Delegates all real work to AppDelegate so that the full AppKit/async
// lifecycle (CGEvent taps, sockets, Combine observers) is handled imperatively.
//
// SwiftUI provides no window scene — OpenVerb is a pure menu-bar agent
// (LSUIElement = true).  All UI surfaces are StatusBarItem + RecordingWindow.
// ---------------------------------------------------------------------------

@main
struct OpenVerbApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Menu-bar agents have no main window; Settings scene is the
        // minimum required by the SwiftUI App protocol on macOS.
        Settings {
            EmptyView()
        }
    }
}

// ---------------------------------------------------------------------------
// AppDelegate — owns all long-lived objects and orchestrates startup.
//
// Property ownership:
//   appState, waveformVM, processingVM  — pure value-tracking ObservableObjects
//   engineManager                        — owns engine subprocess lifecycle
//   hotkeyManager                        — owns CGEvent tap + Escape monitors
//   audioSession                         — owns AVAudioEngine tap
//   recordingWindow                      — floating NSPanel (created after launch)
//   statusBar                            — NSStatusBar item (created after launch)
//
// All closures assigned to engineClient.onError, hotkeyManager callbacks, etc.
// MUST capture [weak self] to prevent retain cycles.
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // -----------------------------------------------------------------------
    // Long-lived state objects (all @MainActor)
    // -----------------------------------------------------------------------

    private var appState:       AppState!
    private var engineManager:  EngineManager!
    private var hotkeyManager:  HotkeyManager!
    private var audioSession:   AudioSession!
    private var waveformVM:     WaveformViewModel!
    private var processingVM:   ProcessingViewModel!
    private var recordingWindow: RecordingWindow!
    private var statusBar:      StatusBarItem!
    private var appSettings:    AppSettings!

    // -----------------------------------------------------------------------
    // Combine subscribers
    // -----------------------------------------------------------------------

    private var cancellables = Set<AnyCancellable>()

    // -----------------------------------------------------------------------
    // applicationDidFinishLaunching — startup orchestration (steps 22–28).
    // -----------------------------------------------------------------------

    func applicationDidFinishLaunching(_ notification: Notification) {

        // Suppress SIGPIPE process-wide.  Without this, any write() to a
        // broken socket (engine crashed, sleep disconnect) kills the app
        // silently — the kernel delivers SIGPIPE before write() returns
        // EPIPE, so our error-handling code never executes.
        signal(SIGPIPE, SIG_IGN)

        // Initialise state objects here (not at class scope) so they are
        // always created on the main thread / MainActor.
        appState      = AppState()
        engineManager = EngineManager()
        hotkeyManager = HotkeyManager()
        audioSession  = AudioSession()
        waveformVM    = WaveformViewModel()
        processingVM  = ProcessingViewModel()
        appSettings   = AppSettings.shared

        // RecordingWindow needs the view-model references — created first
        // so it's ready before the first ⌥Space press.
        recordingWindow = RecordingWindow(
            appState:    appState,
            waveformVM:  waveformVM,
            processingVM: processingVM
        )

        // ---- Step 22: Accessibility permission check ----
        // Required for CGEvent ⌘V posting in TextInjector and for CGEvent tap.
        // AXIsProcessTrustedWithOptions with prompt:true registers the *current*
        // binary's signing identity with TCC (unlike AXIsProcessTrusted which only
        // checks). This prevents stale-entry problems after rebuilds/resignings.
        // #44: use takeUnretainedValue() — kAXTrustedCheckOptionPrompt is a CF
        // constant with +0 reference count; takeRetainedValue() over-releases it.
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOptions)

        // ---- Step 23: Model existence check ----
        // EngineManager shows NSAlert + terminates if no .gguf model is found.
        engineManager.checkModelExists()

        // ---- Step 24: Start engine in background ----
        Task { [weak self] in
            guard let self else { return }
            do {
                try await engineManager.ensureRunning()
                logger.info("Engine running")
            } catch {
                logger.error("Engine startup failed: \(error)")
            }
        }

        // ---- Step 25: Register global ⌥Space hotkey ----
        // HotkeyManager shows its own alerts for permission failures
        // and hotkey conflicts.
        hotkeyManager.onToggleRecording = { [weak self] in
            self?.handleHotkeyToggle()
        }
        hotkeyManager.onCancelRecording = { [weak self] in
            self?.handleCancel()
        }
        hotkeyManager.onAbortAndRestart = { [weak self] in
            self?.abortAndRestart()
        }
        hotkeyManager.register()

        // ---- Step 26: Bridge engine errors to AppState ----
        // onError fires from the Phase 2 monitor for errors detected mid-recording
        // (e.g. engine crash, dropped connection).  We must both update UI and trigger
        // crash recovery so the engine is restarted before the next session — the
        // normal drainResult path only runs after stopRecording(), so Phase 2 errors
        // that arrive before that would otherwise leave the engine in a dead state.
        engineManager.engineClient.onError = { [weak self] msg in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Tear down the live recording session before transitioning to
                // the error state — mirrors handleCancel() and drainResult() error
                // paths for consistent cleanup regardless of how the error arrived.
                self.audioSession.stop()
                self.recordingWindow.hide()
                self.hotkeyManager.removeEscapeMonitors()
                self.handleEngineError(msg)
                // Trigger exponential-backoff restart so the engine is ready for
                // the next session without requiring a manual app relaunch.
                do {
                    try await self.engineManager.handleCrash()
                } catch {
                    logger.error("Crash recovery failed after Phase 2 error: \(error)")
                }
            }
        }

        // ---- Step 27: Create status bar item ----
        statusBar = StatusBarItem(appState: appState, engineManager: engineManager)

        // Observe AppState and EngineManager via Combine to keep the
        // status bar icon in sync.
        appState.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.statusBar?.updateState(state)
            }
            .store(in: &cancellables)

        engineManager.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.statusBar?.updateEngineStatus(status)
            }
            .store(in: &cancellables)

        // ---- Step 28: Bridge sleep/wake UI steps to EngineManager ----
        // EngineManager owns notification registration and the strict-order
        // sleep/wake sequence.  These closures provide the UI-layer steps
        // that EngineManager cannot reach directly.
        engineManager.onPreSleep = { [weak self] in
            self?.audioSession.stop()
            self?.recordingWindow.hide()
            if self?.appState.state != .idle {
                self?.appState.transition(to: .idle)
            }
            self?.hotkeyManager.removeEscapeMonitors()
        }
        engineManager.onWakeStarted = { [weak self] in
            self?.statusBar?.showStatus("Loading model...")
        }
        engineManager.onWakeCompleted = { [weak self] in
            self?.statusBar?.clearStatus()
        }

        logger.info("OpenVerb launched")
    }

    // -----------------------------------------------------------------------
    // applicationWillTerminate — clean shutdown.
    // -----------------------------------------------------------------------

    func applicationWillTerminate(_ notification: Notification) {
        engineManager.shutdown()
        engineManager.disconnect()
    }

    // -----------------------------------------------------------------------
    // handleHotkeyToggle — dispatches on current state.
    // -----------------------------------------------------------------------

    private func handleHotkeyToggle() {
        switch appState.state {
        case .idle, .error:
            startRecording()
        case .recording:
            stopRecording()
        case .inferring:
            abortAndRestart()
        case .preparing:
            // Ignore rapid re-press during cold-start window.
            break
        }
    }

    // -----------------------------------------------------------------------
    // startRecording — steps 29–33 (Phase 7).
    //
    // (29) Check mic permission.
    // (30) Transition to PREPARING; reset processingVM.
    // (31) Start audio session (pre-buffer begins immediately).
    // (32) Play start sound.
    // (33) Show recording window.
    // Steps 34+ (500 ms subtitle timer, engine connect) are deferred to the
    // next implementation phase.
    // -----------------------------------------------------------------------

    private func startRecording() {

        // ---- Step 29: Microphone permission check ----
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .denied, .restricted:
            let alert = NSAlert()
            alert.messageText = "Microphone Permission Needed"
            alert.informativeText = """
                OpenVerb needs microphone access to record your voice.

                Please grant permission in:
                System Settings › Privacy & Security › Microphone
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            return

        case .notDetermined:
            // Request permission; the closure fires on a background thread.
            // The user will need to press ⌥Space again after granting.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return

        case .authorized:
            break  // Proceed.

        @unknown default:
            break
        }

        // ---- Step 30: IDLE / ERROR → PREPARING; reset processing VM ----
        appState.transition(to: .preparing)
        processingVM.reset()
        waveformVM.reset()  // #42: reset waveform bars between recording sessions

        // ---- Step 31: Start audio session (pre-buffering begins now) ----
        do {
            try audioSession.start(waveformCallback: { [weak self] chunk in
                self?.waveformVM.updateAmplitude(chunk)
            })
        } catch AudioSessionError.permissionDenied {
            logger.error("AudioSession: microphone permission denied")
            appState.transition(to: .error("Microphone access denied — check System Settings"))
            return
        } catch {
            logger.error("AudioSession start failed: \(error)")
            appState.transition(to: .error("Microphone unavailable"))
            return
        }

        // ---- Step 32: Recording start sound ----
        NSSound(named: "Tink")?.play()

        // ---- Step 33: Show recording window ----
        recordingWindow.show()

        // Register Escape monitors so the user can cancel during the
        // cold-start window (PREPARING state).
        hotkeyManager.registerEscapeMonitors()

        // ---- Step 35: Engine connect + session start ----
        // NOTE: The 500 ms "Preparing..." subtitle timer is managed entirely
        // inside AppState.transition(to: .preparing) via preparingSubtitleTimer.
        // Do NOT spawn an external Task here — it cannot be cancelled when
        // PREPARING → IDLE fires and would write stale state into the next session.
        Task { [weak self] in
            guard let self else { return }
            await connectAndRecord()
        }
    }

    // -----------------------------------------------------------------------
    // stopRecording — second ⌥Space while RECORDING.
    // -----------------------------------------------------------------------

    private func stopRecording() {
        audioSession.stop()
        engineManager.engineClient.stopPhase2Monitor()
        engineManager.engineClient.sendEndOfAudio()
        appState.transition(to: .inferring)
        NSSound(named: "Pop")?.play()
        // Escape monitors remain active during INFERRING so the user can still
        // press Escape (ignored during INFERRING) and they carry forward into
        // the next PREPARING/RECORDING cycle after abort-and-restart.
        // Monitors are only removed on transition to IDLE (see handleCancel / drainResult).

        // ---- Step 48: 2 s spinner fallback timer ----
        // startSpinnerFallback() owns its own 2-second internal timer; call it
        // immediately so only one sleep occurs (not two).
        Task { [weak self] in
            if self?.appState.state == .inferring {
                self?.processingVM.startSpinnerFallback()
            }
        }

        // ---- Step 49: Drain progress / result in background Task ----
        Task { [weak self] in
            guard let self else { return }
            await drainResult()
        }
    }

    // -----------------------------------------------------------------------
    // abortAndRestart — ⌥Space while INFERRING.
    //
    // (50) disconnect — EOF signals the engine to abort inference.
    // (51) INFERRING → PREPARING; subtitle = "Reconnecting..."
    // (52) Wait 1.5 s for the engine to finish aborting (32-token check).
    // (53) Re-run the session-start flow; targetApp is preserved.
    // -----------------------------------------------------------------------

    private func abortAndRestart() {
        audioSession.stop()
        // #30: stop Phase 2 monitor before disconnect() so the monitor does not
        // detect the fd close as POLLHUP and trigger spurious crash recovery.
        engineManager.engineClient.stopPhase2Monitor()
        engineManager.disconnect()
        // INFERRING→PREPARING: AppState sets preparingSubtitle = "Reconnecting..."
        // immediately inside applyEntryEffects — no external mutation needed here.
        appState.transition(to: .preparing)

        Task { [weak self] in
            guard let self else { return }

            // (52) Wait for engine to abort inference.
            try? await Task.sleep(for: .milliseconds(1500))

            // Guard: user may have pressed Escape during the wait.
            guard appState.state == .preparing else { return }

            // (53) Re-run session-start flow from audioSession.start() onward;
            //      state is already PREPARING and targetApp is preserved.
            processingVM.reset()

            do {
                try audioSession.start(waveformCallback: { [weak self] chunk in
                    self?.waveformVM.updateAmplitude(chunk)
                })
            } catch {
                logger.error("AudioSession restart failed after abort: \(error)")
                appState.transition(to: .error("Microphone unavailable"))
                return
            }

            NSSound(named: "Tink")?.play()
            recordingWindow.show()

            // Re-arm Escape monitors for the new PREPARING→RECORDING cycle.
            // registerEscapeMonitors() is idempotent (guards on nil), so this is
            // safe whether or not monitors were already active.
            hotkeyManager.registerEscapeMonitors()

            await connectAndRecord()
        }
    }

    // -----------------------------------------------------------------------
    // handleCancel — Escape key pressed.
    // -----------------------------------------------------------------------

    private func handleCancel() {
        // Escape is ignored during INFERRING — only ⌥Space (abortAndRestart) is
        // actionable in that state.  Monitors stay registered so they carry over
        // into the next PREPARING/RECORDING cycle.
        guard appState.state != .inferring else {
            logger.debug("Escape ignored during INFERRING")
            return
        }
        audioSession.stop()
        // #31: stop Phase 2 monitor before disconnect() so the monitor does not
        // detect the fd close as POLLHUP and trigger spurious crash recovery.
        engineManager.engineClient.stopPhase2Monitor()
        engineManager.disconnect()
        recordingWindow.hide()
        if appState.state != .idle {
            appState.transition(to: .idle)
        }
        hotkeyManager.removeEscapeMonitors()
        logger.debug("Recording cancelled")
    }

    // -----------------------------------------------------------------------
    // handleEngineError — bridge ServerMessage.error to AppState.
    // -----------------------------------------------------------------------

    private func handleEngineError(_ msg: ServerMessage) {
        guard case .error(let code, let message) = msg else { return }

        let userMessage: String
        switch code {
        case "inference_failed":  userMessage = "Could not process — try again"
        case "model_load_failed": userMessage = "Model error — check ~/.openverb/models/"
        case "timeout":           userMessage = "Inference timed out"
        case "duration_exceeded": userMessage = "Recording too long"
        default:                  userMessage = message
        }

        appState.transition(to: .error(userMessage))
        NSSound(named: "Basso")?.play()
        logger.error("Engine error \(code): \(message)")
    }

    // -----------------------------------------------------------------------
    // connectAndRecord — async helper shared by startRecording and abortAndRestart.
    //
    // (a) ensureRunning  — reconnects if engine crashed since last session.
    // (b) build context  — app bundle ID + clipboard + locale language.
    // (c) startSession   — sends session.start JSON to engine.
    // (d) wait .ready    — engine signals model loaded; times out after 15 s.
    // (e) flushAndSet    — atomically drains pre-buffer and activates live send.
    // (f) phase2Monitor  — start concurrent error watchdog during streaming.
    // (g) .recording     — transition UI to recording state.
    //
    // On any error: stop audio, transition to .error.
    // -----------------------------------------------------------------------

    private func connectAndRecord() async {
        do {
            try await engineManager.ensureRunning()

            // #32: user may have pressed Escape during ensureRunning() (up to 5 s).
            // handleCancel() transitions to .idle; proceeding would call startSession()
            // on a dead/disconnected socket and trigger spurious crash recovery.
            guard appState.state == .preparing else {
                engineManager.disconnect()
                return
            }

            let context = await ContextBuilder.build(
                targetApp: appState.targetApp,
                accessibilityApp: appState.targetApp,
                includeClipboard: appSettings.includeClipboard,
                languageOverride: appSettings.language
            )
            try await engineManager.engineClient.startSession(context: context)

            // Wait for session.ready — engine signals model is loaded and
            // the first audio frame can now be sent.
            let readyMsg = try await engineManager.engineClient.receiveMessage(timeoutMs: 120_000)
            guard case .ready = readyMsg else {
                throw EngineClientError.unexpectedMessage(readyMsg)
            }

            // Guard: user may have pressed Escape while waiting for session.ready.
            // handleCancel() transitions to .idle; IDLE→RECORDING is an invalid
            // transition that crashes via assertionFailure in DEBUG builds.
            guard appState.state == .preparing else {
                engineManager.disconnect()
                return
            }

            // Atomically flush pre-buffer and begin live streaming.
            let buffered = audioSession.flushAndSetSendCallback { [weak self] chunk in
                self?.engineManager.engineClient.sendAudioFrame(chunk)
            }
            for chunk in buffered {
                engineManager.engineClient.sendAudioFrame(chunk)
            }
            engineManager.engineClient.startPhase2Monitor()

            appState.transition(to: .recording)
            logger.info("Engine ready; streamed \(buffered.count) pre-buffered chunk(s)")

        } catch {
            audioSession.stop()
            hotkeyManager.removeEscapeMonitors()
            logger.error("Engine connect failed: \(error)")
            if appState.state != .idle {
                // Surface structured server error info when the engine rejected
                // the session with a typed error message (e.g. "session_limit").
                if case EngineClientError.unexpectedMessage(let msg) = error,
                   case .error(let code, let message) = msg {
                    handleEngineError(.error(code: code, message: message))
                } else {
                    appState.transition(to: .error("Connection failed"))
                }
            }
            // Invoke crash recovery so the engine is ready for the next session.
            // handleCrash() manages exponential backoff and crash-loop detection.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await engineManager.handleCrash()
                } catch {
                    logger.error("Crash recovery failed after connect error: \(error)")
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // drainResult — poll engine for progress / result during .inferring state.
    //
    // Loop until a terminal message (.result / .error) arrives or the state
    // leaves .inferring (e.g. handleCancel called concurrently).
    // -----------------------------------------------------------------------

    private func drainResult() async {
        while appState.state == .inferring {
            let msg: ServerMessage
            do {
                msg = try await engineManager.engineClient.receiveMessage(timeoutMs: 180_000)
            } catch {
                logger.error("drainResult: receive error: \(error)")
                // Bug 16: only tear down if this session is still active — abort+restart
                // moves to .preparing before this catch fires, so we must not clobber it.
                if appState.state == .inferring {
                    recordingWindow.hide()
                    audioSession.stop()
                    // #33: remove Escape monitors on error path — monitors were left
                    // registered, staying active indefinitely after the session failed.
                    hotkeyManager.removeEscapeMonitors()
                    appState.transition(to: .error("Connection lost"))
                    NSSound(named: "Basso")?.play()
                    // Invoke crash recovery (exponential backoff) so the engine is
                    // ready for the next session without a manual restart.
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.engineManager.handleCrash()
                        } catch {
                            logger.error("Crash recovery failed after drainResult error: \(error)")
                        }
                    }
                }
                return
            }

            switch msg {
            case .progress(let percent):
                processingVM.updateProgress(percent)

            case .result(let text, let command):
                // Disconnect so the engine detects EOF and returns to IDLE,
                // freeing the socket slot before any async injection work begins.
                engineManager.disconnect()
                // Command takes priority over text.
                if let cmd = command, !cmd.action.isEmpty {
                    if let target = appState.targetApp {
                        await CommandExecutor.execute(
                            command: cmd, targetApp: target, window: recordingWindow)
                    } else {
                        recordingWindow.hide()
                    }
                } else if let t = text, !t.isEmpty {
                    if let target = appState.targetApp {
                        await TextInjector.inject(
                            text: t, targetApp: target, window: recordingWindow)
                    } else {
                        recordingWindow.hide()
                    }
                } else {
                    // Empty result — VAD-filtered or ultra-short audio.
                    recordingWindow.hide()
                }
                hotkeyManager.removeEscapeMonitors()
                appState.transition(to: .idle)
                return

            case .warning(let code, let message):
                // Warnings do not end the session; log and continue.
                logger.warning("Engine warning \(code): \(message)")

            case .error(let code, let message):
                // Error ends the session.
                recordingWindow.hide()
                audioSession.stop()
                hotkeyManager.removeEscapeMonitors()
                handleEngineError(.error(code: code, message: message))
                return

            default:
                logger.warning("Unexpected message during result drain — ignoring")
            }
        }
    }

}
