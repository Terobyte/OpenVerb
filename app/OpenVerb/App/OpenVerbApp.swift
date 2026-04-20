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
    //
    // Bug 43 fix: use lazy var instead of IUO (!) so that any accidental
    // pre-launch access produces a safely-initialized default object rather
    // than a nil-dereference crash.  applicationDidFinishLaunching still
    // assigns concrete instances (overriding the lazy defaults for the ones
    // that need cross-object wiring), preserving the existing init order.
    // -----------------------------------------------------------------------

    private lazy var appState      = AppState()
    private lazy var engineManager = EngineManager()
    private lazy var hotkeyManager = HotkeyManager()
    private lazy var audioSession  = AudioSession()
    private lazy var waveformVM    = WaveformViewModel()
    private lazy var processingVM  = ProcessingViewModel()
    private lazy var appSettings   = AppSettings.shared
    private lazy var recordingWindow = RecordingWindow(
        appState:    appState,
        waveformVM:  waveformVM,
        processingVM: processingVM,
        settings:    appSettings
    )
    private lazy var statusBar = StatusBarItem(appState: appState, engineManager: engineManager)
    private var onboardingWindow: NSWindow?

    // -----------------------------------------------------------------------
    // Combine subscribers
    // -----------------------------------------------------------------------

    private var cancellables = Set<AnyCancellable>()

    /// Bug 16: bumped on every stopRecording() and abortAndRestart(). Captured
    /// by each drainResult Task at spawn time; a stale drain whose captured
    /// generation no longer matches self.drainGeneration returns silently
    /// instead of tearing down the (new) session. MainActor-isolated — no lock.
    private var drainGeneration: UInt64 = 0

    /// Bug 81: re-entrancy guard for stopRecording(). Set to true before
    /// launching the drainResult Task; reset to false when the drain completes
    /// or on the next recording session start. Prevents two concurrent callers
    /// (Stop button + maxDurationTimer) from each spawning a drainResult Task.
    private var isDraining: Bool = false

    /// Bug 22: auto-stop timer scheduled when entering .recording. Cancelled
    /// on every transition out of .recording (stopRecording / handleCancel /
    /// abortAndRestart / engine error) so a stale timer cannot fire into a
    /// later session. MainActor-isolated — no lock needed.
    private var maxDurationTimer: Task<Void, Never>?

    /// 1-second countdown tick timer, active only while in .inferring with a live ETA.
    /// Fires processingVM.tick() each second to decrement the countdown label.
    private var etaTickTimer: Timer?

    // -----------------------------------------------------------------------
    // applicationDidFinishLaunching — initialise objects then branch:
    //   first launch (no model) → showOnboarding()
    //   normal launch           → normalStartup()
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
        // Bug 25: bind defense-in-depth guard so EngineManager refuses any
        // programmatic restartWithBackend() while a session is active.
        engineManager.canRestartBackend = { [weak appState] in
            appState?.state == .idle
        }
        hotkeyManager = HotkeyManager()
        audioSession  = AudioSession()
        waveformVM    = WaveformViewModel()
        processingVM  = ProcessingViewModel()
        appSettings   = AppSettings.shared

        // RecordingWindow needs the view-model references — created first
        // so it's ready before the first ⌥Space press.
        // Bug 18: pass appSettings so the panel can gate WaveformView on
        // AppSettings.showWaveform live (no app restart required).
        recordingWindow = RecordingWindow(
            appState:    appState,
            waveformVM:  waveformVM,
            processingVM: processingVM,
            settings:    appSettings
        )
        // Wire the HUD's Stop button to the same stopRecording() path as ⌥Space.
        recordingWindow.onStop = { [weak self] in self?.stopRecording() }

        // First-launch detection: if no .gguf model exists, run onboarding
        // wizard instead of the normal startup path. Onboarding calls
        // normalStartup() via its onComplete closure when the user finishes.
        if !engineManager.ggufModelExists() {
            showOnboarding()
            return
        }

        normalStartup()
    }

    // -----------------------------------------------------------------------
    // normalStartup — steps 22–28, extracted so it can be called after
    // onboarding completes on a fresh install.
    // -----------------------------------------------------------------------

    private func normalStartup() {
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

        // ---- Step 25: Register global hotkey ----
        // Load persisted hotkey from AppSettings before register() so the
        // user's custom key survives an app restart.
        hotkeyManager.configure(
            keyCode: appSettings.hotkeyKeyCode,
            modifiers: appSettings.hotkeyModifiers
        )
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

        // Live-reload the hotkey tap whenever the user changes it in Preferences.
        // combineLatest ensures both keyCode and modifiers are applied atomically.
        appSettings.$hotkeyKeyCode
            .combineLatest(appSettings.$hotkeyModifiers)
            .dropFirst()  // skip the initial emit (already applied above)
            .receive(on: RunLoop.main)
            .sink { [weak self] keyCode, modifiers in
                self?.hotkeyManager.configure(keyCode: keyCode, modifiers: modifiers)
            }
            .store(in: &cancellables)

        // ---- Step 26: Bridge engine errors to AppState ----
        // onError fires from the Phase 2 monitor for errors detected mid-recording
        // (e.g. engine crash, dropped connection).  We must both update UI and trigger
        // crash recovery so the engine is restarted before the next session — the
        // normal drainResult path only runs after stopRecording(), so Phase 2 errors
        // that arrive before that would otherwise leave the engine in a dead state.
        engineManager.engineClient.onError = { [weak self] msg in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Bug 17 receive-side guard: if abort+restart moved us to .preparing,
                // or handleCancel moved us to .idle, a stale onError from the
                // Phase 2 monitor must not tear down the (new) session. Only
                // .recording / .inferring indicate a live session that should react.
                switch self.appState.state {
                case .recording, .inferring:
                    break
                default:
                    return
                }
                // Tear down the live recording session before transitioning to
                // the error state — mirrors handleCancel() and drainResult() error
                // paths for consistent cleanup regardless of how the error arrived.
                // Bug 22: cancel the duration timer if it was still pending.
                self.maxDurationTimer?.cancel()
                self.maxDurationTimer = nil
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

        // ---- Step 26b: Wire queue_status ETA into AppState ----
        // onQueueStatus fires from drainResult() during .inferring so we can
        // show a live countdown of remaining inference time.
        engineManager.engineClient.onQueueStatus = { [weak self] _, _, etaMs in
            Task { @MainActor [weak self] in
                guard let self, self.appState.state == .inferring else { return }
                self.appState.remainingInferenceMs = etaMs
                self.processingVM.updateEta(ms: etaMs)
            }
        }

        // ---- Step 26c: Wire partial_result forwarding ----
        // onPartialResult fires from drainResult() during .inferring.  Updates
        // livePartialText for opt-in live subtitle rendering in RecordingWindow.
        engineManager.engineClient.onPartialResult = { [weak self] text, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState.livePartialText += text
            }
        }

        // ---- Step 26d: Wire polished_result forwarding ----
        // onPolishedResult fires when the engine's LLM polish pass completes.
        // Stores the polished text on AppState for potential re-injection.
        engineManager.engineClient.onPolishedResult = { [weak self] text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appState.polishedText = text
            }
        }

        // ---- Step 27: Create status bar item ----
        statusBar = StatusBarItem(appState: appState, engineManager: engineManager)

        // Observe AppState and EngineManager via Combine to keep the
        // status bar icon in sync.
        appState.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.statusBar.updateState(state)
            }
            .store(in: &cancellables)

        engineManager.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.statusBar.updateEngineStatus(status)
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
            self?.statusBar.showStatus("Loading model...")
        }
        engineManager.onWakeCompleted = { [weak self] in
            self?.statusBar.clearStatus()
        }

        logger.info("OpenVerb launched")
    }

    // -----------------------------------------------------------------------
    // showOnboarding — presents first-launch wizard.
    // Called when no .gguf model is found on startup.
    // -----------------------------------------------------------------------

    private func showOnboarding() {
        let customDir = appSettings.modelDirectory
        let modelURL = customDir.isEmpty ? nil : URL(fileURLWithPath: customDir)
        let downloader = ModelDownloader(modelDirectory: modelURL)
        let onboardingView = OnboardingView(downloader: downloader) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.normalStartup()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenVerb Setup"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        onboardingWindow = window
    }

    // -----------------------------------------------------------------------
    // applicationWillTerminate — clean shutdown.
    // -----------------------------------------------------------------------

    func applicationWillTerminate(_ notification: Notification) {
        // shutdown() is async; fire-and-forget is acceptable at app termination
        // because the process is about to exit regardless.
        Task { await engineManager.shutdown() }
        engineManager.disconnect()
    }

    // -----------------------------------------------------------------------
    // playSound — Bug 18: gate every NSSound call on AppSettings.soundEffectsEnabled.
    // The user-facing preference was previously read but never consulted by any
    // playback site, so toggling it had no effect.
    // -----------------------------------------------------------------------

    private func playSound(_ name: String) {
        guard appSettings.soundEffectsEnabled else { return }
        NSSound(named: name)?.play()
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
    // showMicPermissionDeniedAlert — shown when .denied or .restricted.
    // -----------------------------------------------------------------------

    private func showMicPermissionDeniedAlert() {
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
        // Bug 54: capture clipboard at ⌥Space press time so TextInjector's
        // 300 ms paste window never contaminates the session context.
        let clipboardSnapshot = appSettings.includeClipboard
            ? NSPasteboard.general.string(forType: .string)
            : nil

        // ---- Step 29: Microphone permission check ----
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .denied, .restricted:
            showMicPermissionDeniedAlert()
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
        playSound("Tink")

        // ---- Step 33: Show recording window ----
        recordingWindow.show()

        // Register Escape monitors so the user can cancel during the
        // cold-start window (PREPARING state).
        hotkeyManager.registerEscapeMonitors()

        // ---- Step 35: Engine connect + session start ----
        Task { [weak self] in
            guard let self else { return }
            await connectAndRecord(clipboardSnapshot: clipboardSnapshot)
        }
    }

    // -----------------------------------------------------------------------
    // stopRecording — second ⌥Space while RECORDING.
    // -----------------------------------------------------------------------

    private func stopRecording() {
        // Bug 81: re-entrancy guard — two concurrent callers (Stop button +
        // maxDurationTimer) must not each spawn a drainResult Task, as both
        // would call receiveMessage() on the same socket fd.
        guard !isDraining else { return }
        isDraining = true

        // Bug 22: leaving .recording — cancel the auto-stop timer so it does
        // not fire during INFERRING or carry into the next session.
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
        audioSession.stop()
        engineManager.engineClient.stopPhase2Monitor()
        engineManager.engineClient.sendEndOfAudio()
        appState.transition(to: .inferring)
        playSound("Pop")
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

        // ---- ETA tick timer: decrement countdown each second during inferring ----
        etaTickTimer?.invalidate()
        etaTickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.appState.state == .inferring else {
                    self?.etaTickTimer?.invalidate()
                    self?.etaTickTimer = nil
                    return
                }
                self.processingVM.tick()
            }
        }

        // ---- Step 49: Drain progress / result in background Task ----
        // Bug 16: capture generation so a stale drain from a previous session
        // (e.g. abort+restart path) cannot tear down this session's UI when
        // its receiveMessage() continuation finally resumes with an error.
        drainGeneration &+= 1
        let gen = drainGeneration
        Task { [weak self] in
            guard let self else { return }
            await drainResult(generation: gen)
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
        // Bug 22: leaving the active recording — kill the duration timer.
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
        etaTickTimer?.invalidate()
        etaTickTimer = nil
        processingVM.resetEta()
        audioSession.stop()
        // #30: stop Phase 2 monitor before disconnect() so the monitor does not
        // detect the fd close as POLLHUP and trigger spurious crash recovery.
        engineManager.engineClient.stopPhase2Monitor()
        // Bug 16: invalidate any in-flight drainResult from the aborted session
        // BEFORE disconnect() closes fd — the stale drain's receiveMessage will
        // throw momentarily, and its catch block must see the bumped generation.
        drainGeneration &+= 1
        engineManager.disconnect()
        // INFERRING→PREPARING: AppState sets preparingSubtitle = "Reconnecting..."
        // immediately inside applyEntryEffects — no external mutation needed here.
        appState.transition(to: .preparing)

        // Bug 54: capture clipboard at ⌥Space press time so a rapid re-press
        // during the 1.5 s abort wait never sees TextInjector's paste.
        let clipboardSnapshot = appSettings.includeClipboard
            ? NSPasteboard.general.string(forType: .string)
            : nil

        Task { [weak self] in
            guard let self else { return }

            // (52) Wait for engine to abort inference.
            try? await Task.sleep(for: .milliseconds(1500))

            // Guard: user may have pressed Escape during the wait.
            guard appState.state == .preparing else { return }

            // (53) Re-run session-start flow from audioSession.start() onward;
            //      state is already PREPARING and targetApp is preserved.
            processingVM.reset()
            waveformVM.reset()

            do {
                try audioSession.start(waveformCallback: { [weak self] chunk in
                    self?.waveformVM.updateAmplitude(chunk)
                })
            } catch {
                logger.error("AudioSession restart failed after abort: \(error)")
                appState.transition(to: .error("Microphone unavailable"))
                return
            }

            playSound("Tink")
            recordingWindow.show()

            // Re-arm Escape monitors for the new PREPARING→RECORDING cycle.
            // registerEscapeMonitors() is idempotent (guards on nil), so this is
            // safe whether or not monitors were already active.
            hotkeyManager.registerEscapeMonitors()

            await connectAndRecord(clipboardSnapshot: clipboardSnapshot)
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
        // Bug 22: cancel the auto-stop timer if Escape interrupts recording.
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
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
        playSound("Basso")
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

    private func connectAndRecord(clipboardSnapshot: String? = nil) async {
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
                clipboardSnapshot: clipboardSnapshot,
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

            // Bug 32 fix: flush pre-buffer BEFORE activating the live callback
            // so all buffered frames reach ioQueue before any live frame can be
            // dispatched by the audio thread (sendAudioFrame → ioQueue.async).
            let buffered = audioSession.flushPreBuffer()
            for chunk in buffered {
                engineManager.engineClient.sendAudioFrame(chunk)
            }
            // Atomically activate live streaming and drain any frames that
            // arrived in the nanosecond gap since flushPreBuffer() returned.
            let liveCallback: (Data) -> Void = { [weak self] chunk in
                self?.engineManager.engineClient.sendAudioFrame(chunk)
            }
            let interim = audioSession.commitSendCallback(liveCallback)
            for chunk in interim {
                engineManager.engineClient.sendAudioFrame(chunk)
            }
            // Bug 32 fix: drain all pre-buffered+interim frame writes from ioQueue
            // before activating the live streaming monitor.
            engineManager.engineClient.syncOnIOQueue()
            engineManager.engineClient.startPhase2Monitor()

            appState.transition(to: .recording)
            // Bug 55 (livePartialReader): partial_result messages are forwarded
            // live via onPartialResult in runPhase2Monitor's default: case.
            logger.info("Engine ready; streamed \(buffered.count) pre-buffered chunk(s)")

            // Bug 22: enforce AppSettings.maxRecordingDuration. The user-facing
            // "Max Recording Duration" preference was previously persisted but
            // never consulted, so recordings ran until manual stop. Schedule a
            // single-shot Task that triggers the normal stopRecording() flow
            // when the duration elapses while still in .recording.
            let limit = appSettings.maxRecordingDuration
            maxDurationTimer?.cancel()
            maxDurationTimer = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(limit))
                } catch {
                    return  // Cancelled — session ended before the limit fired.
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if self.appState.state == .recording {
                    logger.info("Max recording duration (\(limit)s) reached — auto-stopping")
                    self.stopRecording()
                }
            }

        } catch {
            audioSession.stop()
            hotkeyManager.removeEscapeMonitors()
            // Bug 52: close the stale fd immediately so the next connectAndRecord()
            // does not reuse it.  handleCrash() also disconnects, but there is a
            // narrow window between appState.transition(to: .error) below and the
            // Task executing where a rapid ⌥Space could call connectSync() and
            // silently reuse the open fd.
            engineManager.disconnect()
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
                // Bug 61: only invoke crash recovery for genuine engine errors,
                // not user-initiated cancellations (Escape → handleCancel() →
                // .idle before this catch fires). Calling handleCrash() on a
                // healthy engine after every Escape press exhausts the crash
                // budget (maxCrashes = 3 / 60 s) and locks the app into a
                // permanent error state despite no actual crash.
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
    }

    // -----------------------------------------------------------------------
    // drainResult — poll engine for progress / result during .inferring state.
    //
    // Loop until a terminal message (.result / .error) arrives or the state
    // leaves .inferring (e.g. handleCancel called concurrently).
    // -----------------------------------------------------------------------

    private func drainResult(generation: UInt64) async {
        while appState.state == .inferring && generation == drainGeneration {
            let msg: ServerMessage
            do {
                msg = try await engineManager.engineClient.receiveMessage(timeoutMs: 180_000)
            } catch {
                logger.error("drainResult: receive error: \(error)")
                // Bug 16: stale drain from a previous session — return without touching UI.
                guard generation == drainGeneration else { return }
                // Only tear down if still .inferring — abort+restart moves to .preparing.
                if appState.state == .inferring {
                    etaTickTimer?.invalidate()
                    etaTickTimer = nil
                    processingVM.resetEta()
                    recordingWindow.hide()
                    audioSession.stop()
                    // #33: remove Escape monitors on error path — monitors were left
                    // registered, staying active indefinitely after the session failed.
                    hotkeyManager.removeEscapeMonitors()
                    appState.transition(to: .error("Connection lost"))
                    playSound("Basso")
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

            case .partialResult(let text, let chunkId, let isFinal):
                // Forward to the registered callback (live text / livePartialText).
                engineManager.engineClient.onPartialResult?(text, chunkId, isFinal)

            case .queueStatus(let pending, let inFlight, let etaMs):
                // Forward to the ETA callback (sets remainingInferenceMs on AppState).
                engineManager.engineClient.onQueueStatus?(pending, inFlight > 0, etaMs)

            case .polishStarted:
                processingVM.enterPolishing()

            case .polishedResult(let text):
                processingVM.exitPolishing()
                engineManager.engineClient.onPolishedResult?(text)

            case .result(let text, let command):
                // Bug 78: stale-drain guard — abortAndRestart() bumps drainGeneration.
                guard generation == drainGeneration else { return }
                // Disconnect so the engine detects EOF and returns to IDLE,
                // freeing the socket slot before any async injection work begins.
                engineManager.disconnect()
                maxDurationTimer?.cancel()
                maxDurationTimer = nil
                etaTickTimer?.invalidate()
                etaTickTimer = nil
                processingVM.resetEta()
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
                // Bug 79: stale-drain guard — same drainGeneration check as .result.
                guard generation == drainGeneration else { return }
                Task { [weak self] in try? await self?.engineManager.handleCrash() }
                // Error ends the session.
                recordingWindow.hide()
                engineManager.disconnect()
                audioSession.stop()
                hotkeyManager.removeEscapeMonitors()
                maxDurationTimer?.cancel()
                maxDurationTimer = nil
                etaTickTimer?.invalidate()
                etaTickTimer = nil
                processingVM.resetEta()
                handleEngineError(.error(code: code, message: message))
                return

            default:
                logger.warning("Unexpected message during result drain — ignoring")
            }
        }
    }

}
