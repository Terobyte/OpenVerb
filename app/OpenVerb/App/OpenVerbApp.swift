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

    // -----------------------------------------------------------------------
    // AudioPipeline — replaces drainGeneration/isDraining/livePartialTask
    // -----------------------------------------------------------------------

    private lazy var ringBuffer  = AudioRingBuffer()
    private lazy var audioPipeline: AudioPipeline = {
        AudioPipeline(
            engineClient: engineManager.engineClient,
            engineManager: engineManager,
            ringBuffer: ringBuffer
        )
    }()

    /// Handle for the current recording session; nil when idle.
    private var activePipelineHandle: AudioRingBuffer.Handle?

    /// Bug 22: auto-stop timer scheduled when .recording begins (via onStreaming).
    /// Cancelled on every transition out of .recording so a stale timer cannot
    /// fire into a later session. MainActor-isolated — no lock needed.
    private var maxDurationTimer: Task<Void, Never>?

    /// Bug 110: last chunk ID received via onPartialResult. Used to deduplicate
    /// engine retransmits so doubled text is never appended to livePartialText.
    private var lastSeenPartialChunkId: Int = -1

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

        // ---- Step 26: Wire AudioPipeline callbacks ----

        // onStreaming fires when the engine sends .ready — transition to
        // .recording and arm the max-duration auto-stop timer.
        audioPipeline.onStreaming = { [weak self] in
            guard let self else { return }
            self.appState.transition(to: .recording)
            logger.info("Engine ready; pipeline streaming")
            let limit = self.appSettings.maxRecordingDuration
            self.maxDurationTimer?.cancel()
            self.maxDurationTimer = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(limit)) }
                catch { return }
                guard !Task.isCancelled, self.appState.state == .recording else { return }
                logger.info("Max recording duration (\(limit)s) — auto-stopping")
                self.stopRecording()
            }
        }

        // onResult fires when a final transcript/command arrives.
        audioPipeline.onResult = { [weak self] text, command in
            guard let self else { return }
            self.maxDurationTimer?.cancel()
            self.maxDurationTimer = nil
            self.etaTickTimer?.invalidate()
            self.etaTickTimer = nil
            self.processingVM.resetEta()
            self.activePipelineHandle = nil
            Task { [weak self] in
                guard let self else { return }
                await self.handleResult(text: text, command: command)
            }
        }

        // onError fires on unrecoverable engine error mid-session.
        audioPipeline.onError = { [weak self] message in
            guard let self else { return }
            self.maxDurationTimer?.cancel()
            self.maxDurationTimer = nil
            self.etaTickTimer?.invalidate()
            self.etaTickTimer = nil
            self.processingVM.resetEta()
            self.activePipelineHandle = nil
            self.audioSession.stop()
            self.audioSession.setRingBuffer(nil, handle: nil)
            self.recordingWindow.hide()
            self.hotkeyManager.removeEscapeMonitors()
            self.appState.transition(to: .error(message))
            self.playSound("Basso")
            logger.error("AudioPipeline error: \(message)")
        }

        // ---- Step 26b: Wire queue_status ETA into AppState ----
        engineManager.engineClient.onQueueStatus = { [weak self] _, _, etaMs in
            Task { @MainActor [weak self] in
                guard let self, self.appState.state == .inferring else { return }
                self.appState.remainingInferenceMs = etaMs
                self.processingVM.updateEta(ms: etaMs)
            }
        }

        // partial_result, polish_started, polished_result handlers intentionally
        // omitted: per-chunk streaming and the polish-started indicator created
        // multiple post-stop "arrivals" in the HUD that the user perceives as
        // fake-streaming.  The engine still emits these messages (kept for wire
        // protocol stability and for debug logs in AudioPipeline), but the UI
        // only reacts to the final `result` message — see audioPipeline.onResult
        // / handleResult — which carries the polished text.
        engineManager.engineClient.onPartialResult = { _, chunkId, _ in
            logger.debug("onPartialResult ignored (chunk=\(chunkId))")
        }
        engineManager.engineClient.onPolishStarted = {
            logger.debug("onPolishStarted ignored")
        }
        engineManager.engineClient.onPolishedResult = { _ in
            logger.debug("onPolishedResult ignored")
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
    // startRecording — Phase 8 entry point. Captures clipboard at press time
    // then delegates to startRecordingSession to avoid the Bug 54 race during
    // abortAndRestart (clipboard changes after TextInjector pastes).
    // -----------------------------------------------------------------------

    private func startRecording() {
        let clip = appSettings.includeClipboard
            ? NSPasteboard.general.string(forType: .string)
            : nil
        startRecordingSession(clipboardSnapshot: clip)
    }

    // -----------------------------------------------------------------------
    // startRecordingSession — Phase 8 implementation.
    //
    // (a) Mic permission check.
    // (b) beginRecording on AudioPipeline (idle → capturing).
    // (c) Wire contextProvider with clipboard snapshot captured at call time.
    // (d) Start AudioSession; wire ring buffer handle.
    // (e) Show UI.
    //
    // AudioPipeline.streamLive handles ensureRunning + connect + session start
    // asynchronously; audio captured before the engine is ready is preserved
    // in the ring buffer.  AppState transitions .preparing → .recording via
    // the onStreaming callback when the engine sends .ready.
    // -----------------------------------------------------------------------

    private func startRecordingSession(clipboardSnapshot: String?) {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .denied, .restricted:
            showMicPermissionDeniedAlert()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        guard let handle = audioPipeline.beginRecording(context: [:]) else {
            logger.warning("startRecordingSession: pipeline not idle — ignoring")
            return
        }
        activePipelineHandle = handle

        // Wire context provider; closures capture the snapshot at ⌥Space time.
        audioPipeline.contextProvider = { [weak self, clipboardSnapshot] in
            guard let self else { return [:] }
            let targetApp = await MainActor.run { self.appState.targetApp }
            let (incClip, lang) = await MainActor.run {
                (self.appSettings.includeClipboard, self.appSettings.language)
            }
            return await ContextBuilder.build(
                targetApp: targetApp,
                accessibilityApp: targetApp,
                clipboardSnapshot: clipboardSnapshot,
                includeClipboard: incClip,
                languageOverride: lang
            )
        }

        appState.transition(to: .preparing)
        processingVM.reset()
        waveformVM.reset()
        lastSeenPartialChunkId = -1
        appState.livePartialText = ""

        do {
            try audioSession.start(waveformCallback: { [weak self] chunk in
                self?.waveformVM.updateFromChunk(chunk)
            })
        } catch AudioSessionError.permissionDenied {
            audioPipeline.cancel(handle: handle)
            activePipelineHandle = nil
            appState.transition(to: .error("Microphone access denied — check System Settings"))
            return
        } catch {
            audioPipeline.cancel(handle: handle)
            activePipelineHandle = nil
            appState.transition(to: .error("Microphone unavailable"))
            return
        }

        audioSession.setRingBuffer(ringBuffer, handle: handle)
        playSound("Tink")
        recordingWindow.show()
        hotkeyManager.registerEscapeMonitors()
    }

    // -----------------------------------------------------------------------
    // stopRecording — second ⌥Space while RECORDING.
    //
    // Signals endRecording to the pipeline (streaming → finalizing).
    // AudioPipeline.streamLive drains the ring buffer tail, sends the EOF
    // sentinel, then calls onResult when the engine responds.
    // The ETA tick timer and spinner are started here so they are active
    // during the inferring/finalizing window.
    // -----------------------------------------------------------------------

    private func stopRecording() {
        guard let handle = activePipelineHandle else { return }
        guard appState.state == .recording else { return }

        maxDurationTimer?.cancel()
        maxDurationTimer = nil
        audioSession.stop()
        audioSession.setRingBuffer(nil, handle: nil)
        audioPipeline.endRecording(handle: handle)
        appState.transition(to: .inferring)
        playSound("Pop")

        Task { [weak self] in
            if self?.appState.state == .inferring {
                self?.processingVM.startSpinnerFallback()
            }
        }

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
    }

    // -----------------------------------------------------------------------
    // abortAndRestart — ⌥Space while INFERRING.
    //
    // Cancels the active pipeline session (sends EOF to the engine), waits
    // 1.5 s for the engine to finish aborting, then starts a new session.
    // Bug 54: clipboard is captured at ⌥Space press time so the 1.5 s wait
    // never picks up the text that TextInjector just pasted.
    // -----------------------------------------------------------------------

    private func abortAndRestart() {
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
        etaTickTimer?.invalidate()
        etaTickTimer = nil
        processingVM.resetEta()
        audioSession.stop()
        audioSession.setRingBuffer(nil, handle: nil)
        if let handle = activePipelineHandle {
            audioPipeline.cancel(handle: handle)  // disconnects socket
        }
        activePipelineHandle = nil
        appState.transition(to: .preparing)

        // Bug 54: capture clipboard before the async wait.
        let clipboardSnapshot = appSettings.includeClipboard
            ? NSPasteboard.general.string(forType: .string)
            : nil

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            guard appState.state == .preparing else { return }
            processingVM.reset()
            waveformVM.reset()
            startRecordingSession(clipboardSnapshot: clipboardSnapshot)
        }
    }

    // -----------------------------------------------------------------------
    // handleCancel — Escape key pressed.
    // -----------------------------------------------------------------------

    private func handleCancel() {
        guard appState.state != .inferring else {
            logger.debug("Escape ignored during INFERRING")
            return
        }
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
        audioSession.stop()
        audioSession.setRingBuffer(nil, handle: nil)
        if let handle = activePipelineHandle {
            audioPipeline.cancel(handle: handle)  // disconnects socket
        }
        activePipelineHandle = nil
        recordingWindow.hide()
        if appState.state != .idle {
            appState.transition(to: .idle)
        }
        hotkeyManager.removeEscapeMonitors()
        logger.debug("Recording cancelled")
    }

    // -----------------------------------------------------------------------
    // handleResult — called by audioPipeline.onResult when a final transcript
    // or command arrives. Async because TextInjector and CommandExecutor need
    // to await focus-restoration before pasting.
    // -----------------------------------------------------------------------

    private func handleResult(text: String?, command: Command?) async {
        let textLen = text?.count ?? 0
        let targetName = appState.targetApp?.localizedName ?? "<nil>"
        logger.info("handleResult: text=\(textLen)ch cmd=\(command?.action ?? "<nil>") target=\(targetName)")
        if let cmd = command, !cmd.action.isEmpty {
            if let target = appState.targetApp {
                await CommandExecutor.execute(
                    command: cmd, targetApp: target, window: recordingWindow)
            } else {
                logger.warning("handleResult: command=\(cmd.action) but targetApp=nil — hiding window, nothing executed")
                recordingWindow.hide()
            }
        } else if let t = text, !t.isEmpty {
            if let target = appState.targetApp {
                logger.info("handleResult: injecting \(t.count)ch into \(target.localizedName ?? "<?>")")
                if appState.polishedText == nil {
                    appState.setPolishedText(t)
                }
                processingVM.exitPolishing()
                processingVM.resetEta()
                await TextInjector.inject(
                    text: t, targetApp: target, window: recordingWindow)
            } else {
                logger.warning("handleResult: text=\(t.count)ch but targetApp=nil — hiding window, nothing injected")
                if appState.polishedText == nil {
                    appState.setPolishedText(t)
                }
                processingVM.exitPolishing()
                recordingWindow.hide()
            }
        } else {
            logger.info("handleResult: empty text and empty command — hiding window")
            recordingWindow.hide()
        }
        hotkeyManager.removeEscapeMonitors()
        appState.transition(to: .idle)
    }


}
