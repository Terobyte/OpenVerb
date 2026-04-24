import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// PreferencesView — warm glass preferences panel for OpenVerb.
// ---------------------------------------------------------------------------

struct PreferencesView: View {

    @ObservedObject var settings: AppSettings
    @ObservedObject var engineManager: EngineManager
    /// Bug 25: needed to gate the backend picker on the current session state.
    @ObservedObject var appState: AppState

    @State private var isSwitchingBackend = false
    @State private var selectedSection: PreferenceSection = .general

    private let deepGreen = Color(red: 0.102, green: 0.137, blue: 0.086)
    private let ink = Color(red: 0.090, green: 0.129, blue: 0.075)
    private let inkSoft = Color(red: 0.235, green: 0.318, blue: 0.216)
    private let muted = Color(red: 0.427, green: 0.463, blue: 0.412)
    private let moss = Color(red: 0.345, green: 0.463, blue: 0.259)
    private let mossDark = Color(red: 0.192, green: 0.294, blue: 0.165)
    private let amber = Color(red: 0.784, green: 0.533, blue: 0.239)
    private let signalRed = Color(red: 0.722, green: 0.231, blue: 0.176)

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(deepGreen.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    heading
                    selectedContent
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 680, height: 540)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.94),
                    Color(red: 0.929, green: 0.965, blue: 0.910).opacity(0.82)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(ink)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenVerb")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ink)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            ForEach(PreferenceSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 22)
                        Text(section.title)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(selectedSection == section ? mossDark : inkSoft)
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedSection == section ? moss.opacity(0.14) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selectedSection == section ? moss.opacity(0.20) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            EngineBadge(status: engineManager.status)
        }
        .padding(14)
        .frame(width: 158)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.18))
    }

    private var heading: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selectedSection.heading)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ink)
                Text(selectedSection.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(muted)
            }

            Spacer()

            Button(role: .destructive) {
                settings.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(signalRed)
            .background(signalRed.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Reset preferences")
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .general:
            generalSection
        case .recording:
            recordingSection
        case .text:
            textSection
        case .backend:
            backendSection
        }
    }

    private var generalSection: some View {
        VStack(spacing: 14) {
            PreferenceGroup(title: "General") {
                PreferenceRow(title: "Sound effects", subtitle: "Start, stop, and completion feedback.") {
                    Toggle("", isOn: $settings.soundEffectsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                PreferenceRow(title: "Clipboard context", subtitle: "Use nearby text to shape the final insert.") {
                    Toggle("", isOn: $settings.includeClipboard)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            PreferenceGroup(title: "Shortcut") {
                PreferenceRow(title: "Start or stop recording", subtitle: "Current: \(hotkeyDescription)") {
                    ShortcutRecorderView(
                        keyCode: $settings.hotkeyKeyCode,
                        modifiers: Binding(
                            get: { settings.hotkeyModifiers },
                            set: { settings.hotkeyModifiers = $0 }
                        )
                    )
                    .frame(width: 178, height: 30)
                }

                HStack {
                    Spacer()
                    Button {
                        settings.hotkeyKeyCode = 0x31
                        settings.hotkeyModifiers = .maskAlternate
                    } label: {
                        Label("Reset shortcut", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mossDark)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(moss.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.top, -4)
            }
        }
    }

    private var recordingSection: some View {
        PreferenceGroup(title: "Recording HUD") {
            PreferenceRow(title: "Waveform", subtitle: "Show the compact live waveform in the recorder.") {
                Toggle("", isOn: $settings.showWaveform)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PreferenceRow(title: "Live correction stream", subtitle: "Show draft words and polish changes inside the recorder.") {
                Toggle("", isOn: $settings.showLiveTranscript)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            PreferenceRow(title: "Max duration", subtitle: "Automatic stop for long captures.") {
                Stepper(
                    "\(settings.maxRecordingDuration) s",
                    value: $settings.maxRecordingDuration,
                    in: 1...300
                )
                .frame(width: 136)
            }
        }
    }

    private var textSection: some View {
        PreferenceGroup(title: "Transcription") {
            PreferenceRow(title: "Output language", subtitle: "Language preference sent to the local engine.") {
                Picker("Output language", selection: Binding(
                    get: { settings.language ?? "en" },
                    set: { settings.language = $0 }
                )) {
                    if settings.backend == .whisperGemma {
                        Text("Auto-detect").tag("auto")
                    }
                    Text("English").tag("en")
                    Text("Русский").tag("ru")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Italiano").tag("it")
                    Text("Português").tag("pt")
                    Text("日本語").tag("ja")
                }
                .labelsHidden()
                .frame(width: 180)
            }

            PreferenceRow(title: "Clipboard context", subtitle: "Reuse the target app selection and clipboard when available.") {
                Toggle("", isOn: $settings.includeClipboard)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var backendSection: some View {
        let isNonEnglish = settings.language != "en"
        let sessionActive = appState.state != .idle

        return VStack(spacing: 14) {
            PreferenceGroup(title: "Backend") {
                PreferenceRow(title: "Inference backend", subtitle: sessionActive ? "Stop the current session before changing backend." : "Choose the local inference path.") {
                    Picker("Backend", selection: Binding<BackendType>(
                        get: { settings.backend },
                        set: { newValue in
                            guard newValue != settings.backend else { return }
                            guard appState.state == .idle else { return }
                            isSwitchingBackend = true
                            Task {
                                guard appState.state == .idle else {
                                    isSwitchingBackend = false
                                    return
                                }
                                settings.backend = newValue
                                await engineManager.restartWithBackend(newValue)
                                isSwitchingBackend = false
                            }
                        }
                    )) {
                        Text("Gemma 4 E2B Audio").tag(BackendType.gemmaAudio)
                        Text("Whisper + Gemma Text").tag(BackendType.whisperGemma)
                    }
                    .labelsHidden()
                    .frame(width: 210)
                    .disabled(isSwitchingBackend || sessionActive)
                }

                if isSwitchingBackend {
                    InlineStatus(kind: .working, text: "Switching backend...")
                }

                if isNonEnglish && settings.backend == .gemmaAudio {
                    InlineStatus(kind: .warning, text: "Gemma audio currently expects English input.")

                    HStack {
                        Spacer()
                        Button {
                            guard appState.state == .idle else { return }
                            settings.backend = .whisperGemma
                            isSwitchingBackend = true
                            Task {
                                guard appState.state == .idle else {
                                    isSwitchingBackend = false
                                    return
                                }
                                await engineManager.restartWithBackend(.whisperGemma)
                                isSwitchingBackend = false
                            }
                        } label: {
                            Label("Use multilingual backend", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(mossDark)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(moss.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .disabled(sessionActive)
                    }
                }
            }

            PreferenceGroup(title: "Model") {
                PreferenceRow(title: "Model directory", subtitle: settings.modelDirectory) {
                    Button {
                        browseModelDirectory()
                    } label: {
                        Label("Browse", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mossDark)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(moss.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
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
        panel.title = "Choose Model Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.modelDirectory, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            var path = url.path
            if path.hasSuffix("/") { path = String(path.dropLast()) }
            settings.modelDirectory = path
        }
    }
}

private enum PreferenceSection: String, CaseIterable, Identifiable {
    case general
    case recording
    case text
    case backend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .text: return "Text"
        case .backend: return "Backend"
        }
    }

    var heading: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording HUD"
        case .text: return "Transcription"
        case .backend: return "Backend"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Everyday controls for OpenVerb."
        case .recording: return "The compact recorder and live correction stream."
        case .text: return "Language and context for inserted text."
        case .backend: return "Local engine and model settings."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "leaf"
        case .recording: return "waveform"
        case .text: return "textformat"
        case .backend: return "cpu"
        }
    }
}

private struct PreferenceGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    private let deepGreen = Color(red: 0.102, green: 0.137, blue: 0.086)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 0.192, green: 0.294, blue: 0.165))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            content()
        }
        .background(Color.white.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(deepGreen.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: deepGreen.opacity(0.07), radius: 12, x: 0, y: 5)
    }
}

private struct PreferenceRow<Control: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var control: () -> Control

    private let deepGreen = Color(red: 0.102, green: 0.137, blue: 0.086)
    private let ink = Color(red: 0.090, green: 0.129, blue: 0.075)
    private let muted = Color(red: 0.427, green: 0.463, blue: 0.412)

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 14)

            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(deepGreen.opacity(0.07))
                .frame(height: 1)
                .padding(.leading, 16)
        }
    }
}

private struct EngineBadge: View {
    var status: EngineManager.EngineStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.55), radius: 5, x: 0, y: 0)
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .running: return "Engine ready"
        case .starting: return "Engine warming"
        case .stopped: return "Engine stopped"
        case .error: return "Engine error"
        }
    }

    private var color: Color {
        switch status {
        case .running: return Color(red: 0.192, green: 0.294, blue: 0.165)
        case .starting: return Color(red: 0.784, green: 0.533, blue: 0.239)
        case .stopped: return Color(red: 0.427, green: 0.463, blue: 0.412)
        case .error: return Color(red: 0.722, green: 0.231, blue: 0.176)
        }
    }
}

private struct InlineStatus: View {
    enum Kind {
        case warning
        case working
    }

    var kind: Kind
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            if kind == .working {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(kind == .working ? Color(red: 0.192, green: 0.294, blue: 0.165) : Color(red: 0.784, green: 0.533, blue: 0.239))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

// ---------------------------------------------------------------------------
// PreferencesWindowController — manages the Preferences NSWindow lifetime.
//
// Usage (from StatusBarItem menu action):
//   PreferencesWindowController.shared.open(engineManager: engineManager)
// ---------------------------------------------------------------------------

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private weak var engineManager: EngineManager?
    /// Bug 25: retained weakly so the Preferences view can observe session
    /// state and gate the backend picker accordingly.
    private weak var appState: AppState?

    func open(engineManager: EngineManager? = nil, appState: AppState) {
        if let em = engineManager { self.engineManager = em }
        self.appState = appState
        if window == nil {
            // Bug 24: do NOT fall back to `EngineManager()`. A fresh instance
            // registers duplicate sleep/wake observers and any backend restart
            // it performs targets a phantom subprocess.
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
            win.title = "OpenVerb Preferences"
            win.styleMask = [.titled, .closable, .miniaturizable]
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

    func windowWillClose(_ notification: Notification) {
        // Keep the window in memory so re-opening is instant.
    }
}
