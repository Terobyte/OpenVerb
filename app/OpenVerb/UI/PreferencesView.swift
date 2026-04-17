import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// PreferencesView — SwiftUI preferences panel for OpenVerb.
//
// Layout (TabView):
//   General tab  — Hotkey (Change… + Reset to Default), Context, Language,
//                  Sound & UI, Recording
//   Backend tab  — Backend picker (calls restartWithBackend), Model directory,
//                  Reset to Defaults
//
// Dependencies are injected:
//   @ObservedObject var settings: AppSettings
//   @ObservedObject var engineManager: EngineManager
//
// Window management:
//   PreferencesWindowController.shared.open(engineManager:)
//   — creates a standard, activatable NSWindow hosting this view.
//   — should be called from the StatusBarItem "Preferences…" menu item.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// PreferencesView
// ---------------------------------------------------------------------------

struct PreferencesView: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var engineManager: EngineManager
    /// Bug 25: needed to gate the backend picker on the current session state.
    @ObservedObject var appState: AppState

    @State private var isSwitchingBackend = false

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            backendTab.tabItem { Label("Backend", systemImage: "cpu") }
        }
        .frame(width: 450, height: 300)
        .padding()
    }

    // -- General tab --

    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Current:")
                    Text(hotkeyDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") {
                        settings.hotkeyKeyCode = 0x31
                        settings.hotkeyModifiers = .maskAlternate
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
                ShortcutRecorderView(
                    keyCode: $settings.hotkeyKeyCode,
                    modifiers: Binding(
                        get: { settings.hotkeyModifiers },
                        set: { settings.hotkeyModifiers = $0 }
                    )
                )
                .frame(height: 28)
            }

            Section("Context") {
                Toggle("Include clipboard in context", isOn: $settings.includeClipboard)
            }

            Section("Language") {
                Picker("Output language", selection: Binding(
                    get: { settings.language ?? "en" },
                    set: { settings.language = $0 }
                )) {
                    if settings.backend == .whisperGemma {
                        Text("Auto-detect (Whisper)").tag("auto")
                    }
                    Text("English").tag("en")
                    Text("Русский").tag("ru")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("日本語").tag("ja")
                }
            }

            Section("Sound & UI") {
                Toggle("Sound Effects", isOn: $settings.soundEffectsEnabled)
                Toggle("Show Waveform", isOn: $settings.showWaveform)
            }

            Section("Recording") {
                LabeledContent("Max Duration") {
                    Stepper(
                        "\(settings.maxRecordingDuration) s",
                        value: $settings.maxRecordingDuration,
                        in: 1...300
                    )
                }
            }
        }
    }

    // -- Backend tab --

    private var backendTab: some View {
        Form {
            Section("Inference Backend") {
                let isNonEnglish = settings.language != "en"

                // Bug 25: switching backend kills the engine subprocess, so it
                // must be blocked while a session is live.
                let sessionActive = appState.state != .idle

                Picker("Backend", selection: Binding<BackendType>(
                    get: { settings.backend },
                    set: { newValue in
                        guard newValue != settings.backend else { return }
                        guard appState.state == .idle else { return }
                        isSwitchingBackend = true
                        Task {
                            settings.backend = newValue
                            await engineManager.restartWithBackend(newValue)
                            isSwitchingBackend = false
                        }
                    }
                )) {
                    Text("Gemma 4 E2B Audio (recommended)")
                        .tag(BackendType.gemmaAudio)
                    Text("Whisper + Gemma Text (multilingual)")
                        .tag(BackendType.whisperGemma)
                }
                .disabled(isSwitchingBackend || sessionActive)

                if sessionActive {
                    Text("Stop the current session to change the backend.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if isSwitchingBackend {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Switching backend...")
                            .foregroundStyle(.secondary)
                    }
                }

                if isNonEnglish && settings.backend == .gemmaAudio {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Path A supports English audio only.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Button("Switch to Whisper (multilingual)") {
                            guard appState.state == .idle else { return }
                            settings.backend = .whisperGemma
                            isSwitchingBackend = true
                            Task {
                                await engineManager.restartWithBackend(.whisperGemma)
                                isSwitchingBackend = false
                            }
                        }
                        .font(.caption)
                        .disabled(sessionActive)
                    }
                }
            }

            Section("Model") {
                LabeledContent("Model directory") {
                    HStack(spacing: 8) {
                        Text(settings.modelDirectory)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 210, alignment: .leading)
                        Button("Browse...") { browseModelDirectory() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    settings.reset()
                } label: {
                    Text("Reset to Defaults")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Private — hotkey label
    // -----------------------------------------------------------------------

    private var hotkeyDescription: String {
        var parts: [String] = []
        let flags = settings.hotkeyModifiers
        if flags.contains(.maskControl)   { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift)     { parts.append("⇧") }
        if flags.contains(.maskCommand)   { parts.append("⌘") }

        let keyNames: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
            0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
            0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
            0x10: "Y", 0x11: "T", 0x1F: "O", 0x20: "U", 0x22: "I",
            0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K", 0x2D: "N",
            0x2E: "M",
            0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[", 0x27: "'",
            0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2F: ".",
            0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6",
            0x17: "5", 0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",
            0x31: "Space", 0x32: "`", 0x24: "Return", 0x30: "Tab",
            0x33: "Delete", 0x35: "Escape",
        ]
        parts.append(keyNames[settings.hotkeyKeyCode] ?? "Key(\(settings.hotkeyKeyCode))")
        return parts.joined()
    }

    // -----------------------------------------------------------------------
    // Private — model directory browser
    // -----------------------------------------------------------------------

    private func browseModelDirectory() {
        let panel = NSOpenPanel()
        panel.title            = "Choose Model Directory"
        panel.canChooseFiles        = false
        panel.canChooseDirectories  = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.modelDirectory,
                                  isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            var path = url.path
            if path.hasSuffix("/") { path = String(path.dropLast()) }
            settings.modelDirectory = path
        }
    }
}

// ---------------------------------------------------------------------------
// PreferencesWindowController — manages the Preferences NSWindow lifetime.
//
// Usage (from StatusBarItem menu action):
//   PreferencesWindowController.shared.open(engineManager: engineManager)
//
// Design:
//   • Regular activating NSWindow (not nonactivatingPanel) so the user can
//     type in text fields.
//   • .titled + .closable + .miniaturizable matches standard macOS prefs style.
//   • Window is kept in memory after close and re-shown on repeated open()
//     calls (standard macOS behaviour).
// ---------------------------------------------------------------------------

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {

    // -----------------------------------------------------------------------
    // Singleton
    // -----------------------------------------------------------------------

    static let shared = PreferencesWindowController()

    // -----------------------------------------------------------------------
    // Private — window reference
    // -----------------------------------------------------------------------

    private var window: NSWindow?
    private weak var engineManager: EngineManager?
    /// Bug 25: retained weakly so the Preferences view can observe session
    /// state and gate the backend picker accordingly.
    private weak var appState: AppState?

    // -----------------------------------------------------------------------
    // open — bring the preferences window to front, creating it if needed.
    // -----------------------------------------------------------------------

    func open(engineManager: EngineManager? = nil, appState: AppState) {
        if let em = engineManager { self.engineManager = em }
        self.appState = appState
        if window == nil {
            // Bug 24: do NOT fall back to `EngineManager()`. A fresh instance
            // registers duplicate sleep/wake observers and any backend restart
            // it performs targets a phantom subprocess — the real engine
            // managed by AppDelegate never sees the call. In DEBUG, crash
            // loudly so the regression is caught; in RELEASE, refuse to open
            // the window rather than silently corrupting engine state.
            guard let em = self.engineManager else {
                assertionFailure("PreferencesWindowController.open() called without a live EngineManager")
                return
            }
            let hosting = NSHostingController(
                rootView: PreferencesView(
                    settings: .shared,
                    engineManager: em,
                    appState: appState))
            let win = NSWindow(contentViewController: hosting)
            win.title           = "OpenVerb Preferences"
            win.styleMask       = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.center()
            win.delegate = self
            window = win
        }

        guard let win = window else { return }
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        win.makeKeyAndOrderFront(nil)
    }

    // -----------------------------------------------------------------------
    // NSWindowDelegate — remove reference when window is closed via the × button.
    // -----------------------------------------------------------------------

    func windowWillClose(_ notification: Notification) {
        // Keep the window in memory so re-opening is instant (no re-create).
        // Nothing to do; isReleasedWhenClosed = false handles lifetime.
    }
}
