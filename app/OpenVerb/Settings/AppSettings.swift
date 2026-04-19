import Foundation
import Combine
import ApplicationServices
import os

// ---------------------------------------------------------------------------
// BackendType — inference backend selection.
// ---------------------------------------------------------------------------

enum BackendType: String, Hashable {
    case gemmaAudio   = "gemma_audio"
    case whisperGemma = "whisper_gemma"
}

// ---------------------------------------------------------------------------
// AppSettings — persisted user preferences for OpenVerb.
//
// Backed by UserDefaults so values survive app restarts.
// Conforms to ObservableObject for SwiftUI / Combine integration.
//
// Usage:
//   let settings = AppSettings.shared          // singleton for production
//   let settings = AppSettings(defaults: mock) // inject mock in tests
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "AppSettings")

@MainActor
final class AppSettings: ObservableObject {

    // -----------------------------------------------------------------------
    // Singleton
    // -----------------------------------------------------------------------

    /// Shared instance used throughout the app.
    /// Use `init(defaults:)` in tests to inject a mock UserDefaults.
    static let shared = AppSettings()

    // -----------------------------------------------------------------------
    // Dependencies
    // -----------------------------------------------------------------------

    /// UserDefaults suite used for persistence.
    /// Defaults to `.standard` in production; inject a ephemeral suite in tests.
    private let defaults: UserDefaults

    /// Set to true during reset() to suppress didSet → UserDefaults writes.
    private var isResetting = false

    // -----------------------------------------------------------------------
    // Published settings — Hotkey
    // -----------------------------------------------------------------------

    /// Virtual key code for the global recording hotkey (default: Space = 0x31).
    @Published var hotkeyKeyCode: UInt16 = 0x31 {
        didSet {
            guard !isResetting else { return }
            defaults.set(Int(hotkeyKeyCode), forKey: Key.hotkeyKeyCode)
        }
    }

    /// Modifier flags for the global recording hotkey (default: Option).
    @Published var hotkeyModifiers: CGEventFlags = .maskAlternate {
        didSet {
            guard !isResetting else { return }
            defaults.set(Int(hotkeyModifiers.rawValue), forKey: Key.hotkeyModifiers)
        }
    }

    // -----------------------------------------------------------------------
    // Published settings — Backend
    // -----------------------------------------------------------------------

    /// Inference backend used by the engine.
    @Published var backend: BackendType = .gemmaAudio {
        didSet {
            guard !isResetting else { return }
            defaults.set(backend.rawValue, forKey: Key.backend)
        }
    }

    // -----------------------------------------------------------------------
    // Published settings — Language
    // -----------------------------------------------------------------------

    /// Preferred language code for speech recognition (e.g. "en", "de", "fr").
    /// When nil the setting falls back to the system locale on next init.
    @Published var language: String? {
        didSet {
            guard !isResetting else { return }
            defaults.set(language, forKey: Key.language)
        }
    }

    // -----------------------------------------------------------------------
    // Published settings — Sound & UI
    // -----------------------------------------------------------------------

    /// Whether to play sound effects on recording start / stop.
    @Published var soundEffectsEnabled: Bool {
        didSet {
            guard !isResetting else { return }
            defaults.set(soundEffectsEnabled, forKey: Key.soundEffectsEnabled)
        }
    }

    /// Whether to show the floating waveform during recording.
    @Published var showWaveform: Bool {
        didSet {
            guard !isResetting else { return }
            defaults.set(showWaveform, forKey: Key.showWaveform)
        }
    }

    // -----------------------------------------------------------------------
    // Published settings — Live Transcript
    // -----------------------------------------------------------------------

    /// Whether to show a live partial transcript below the waveform during
    /// recording.  On by default so users see live text out-of-the-box.
    @Published var showLiveTranscript: Bool = true {
        didSet {
            guard !isResetting else { return }
            defaults.set(showLiveTranscript, forKey: Key.showLiveTranscript)
        }
    }

    // -----------------------------------------------------------------------
    // Published settings — Clipboard
    // -----------------------------------------------------------------------

    /// Whether to include clipboard context when building the prompt.
    @Published var includeClipboard: Bool = true {
        didSet {
            guard !isResetting else { return }
            defaults.set(includeClipboard, forKey: Key.includeClipboard)
        }
    }

    // -----------------------------------------------------------------------
    // Published settings — Recording
    // -----------------------------------------------------------------------

    /// Maximum recording duration in seconds before automatic stop.
    /// Values are clamped to 1...300.  Default is 60.
    @Published var maxRecordingDuration: Int {
        didSet {
            guard !isResetting else { return }
            let clamped = maxRecordingDuration.clamped(to: 1...300)
            if clamped != maxRecordingDuration {
                maxRecordingDuration = clamped
                return // didSet re-fires with clamped value; UserDefaults write happens there
            }
            defaults.set(maxRecordingDuration, forKey: Key.maxRecordingDuration)
        }
    }

    // -----------------------------------------------------------------------
    // Published settings — Model path
    // -----------------------------------------------------------------------

    /// Directory where GGUF models are stored.
    @Published var modelDirectory: String = "" {
        didSet {
            guard !isResetting else { return }
            defaults.set(modelDirectory, forKey: Key.modelDirectory)
        }
    }

    // -----------------------------------------------------------------------
    // Keys
    // -----------------------------------------------------------------------

    private enum Key {
        static let hotkeyKeyCode         = "hotkeyKeyCode"
        static let hotkeyModifiers       = "hotkeyModifiers"
        static let backend               = "backend"
        static let language              = "app.settings.language"
        static let soundEffectsEnabled   = "app.settings.soundEffectsEnabled"
        static let showWaveform          = "app.settings.showWaveform"
        static let showLiveTranscript    = "showLiveTranscript"
        static let includeClipboard      = "includeClipboard"
        static let maxRecordingDuration  = "app.settings.maxRecordingDuration"
        static let modelDirectory        = "modelDirectory"
    }

    // -----------------------------------------------------------------------
    // Defaults
    // -----------------------------------------------------------------------

    private enum Default {
        static let soundEffectsEnabled  = true
        static let showWaveform         = true
        static let includeClipboard     = true
        static let maxRecordingDuration = 60
    }

    // -----------------------------------------------------------------------
    // Init
    // -----------------------------------------------------------------------

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load persisted values (or fall back to defaults).

        // Hotkey
        let storedKeyCode = defaults.integer(forKey: Key.hotkeyKeyCode)
        if storedKeyCode != 0 { hotkeyKeyCode = UInt16(storedKeyCode) }

        let storedMods = defaults.integer(forKey: Key.hotkeyModifiers)
        if storedMods != 0 { hotkeyModifiers = CGEventFlags(rawValue: UInt64(storedMods)) }

        // Backend
        if let raw = defaults.string(forKey: Key.backend) {
            backend = BackendType(rawValue: raw) ?? .gemmaAudio
        }

        // Language — fall back to system locale when no override is stored.
        self.language = defaults.string(forKey: Key.language)
            ?? Locale.current.language.languageCode?.identifier

        // Sound effects
        self.soundEffectsEnabled = defaults.object(forKey: Key.soundEffectsEnabled) as? Bool
            ?? Default.soundEffectsEnabled

        // Waveform
        self.showWaveform = defaults.object(forKey: Key.showWaveform) as? Bool
            ?? Default.showWaveform

        // Live transcript
        if defaults.object(forKey: Key.showLiveTranscript) != nil {
            showLiveTranscript = defaults.bool(forKey: Key.showLiveTranscript)
        }

        // Clipboard
        if defaults.object(forKey: Key.includeClipboard) != nil {
            includeClipboard = defaults.bool(forKey: Key.includeClipboard)
        }

        // Max recording duration
        let storedDuration = defaults.object(forKey: Key.maxRecordingDuration) as? Int
            ?? Default.maxRecordingDuration
        self.maxRecordingDuration = storedDuration.clamped(to: 1...300)

        // Model directory — normalise trailing slash for consistent path comparisons.
        let rawDir = defaults.string(forKey: Key.modelDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openverb/models").path
        modelDirectory = rawDir.hasSuffix("/") ? String(rawDir.dropLast()) : rawDir

        logger.debug("AppSettings initialised")
    }

    // -----------------------------------------------------------------------
    // Reset — clears all persisted values back to defaults.
    // -----------------------------------------------------------------------

    func reset() {
        isResetting = true
        defer { isResetting = false }
        // Set in-memory properties to defaults first (didSet writes skipped while resetting).
        hotkeyKeyCode = 0x31
        hotkeyModifiers = .maskAlternate
        backend = .gemmaAudio
        language = Locale.current.language.languageCode?.identifier
        soundEffectsEnabled = Default.soundEffectsEnabled
        showWaveform = Default.showWaveform
        showLiveTranscript = true
        includeClipboard = Default.includeClipboard
        maxRecordingDuration = Default.maxRecordingDuration
        modelDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openverb/models").path

        // Now remove persisted keys so UserDefaults is truly clean.
        defaults.removeObject(forKey: Key.hotkeyKeyCode)
        defaults.removeObject(forKey: Key.hotkeyModifiers)
        defaults.removeObject(forKey: Key.backend)
        defaults.removeObject(forKey: Key.language)
        defaults.removeObject(forKey: Key.soundEffectsEnabled)
        defaults.removeObject(forKey: Key.showWaveform)
        defaults.removeObject(forKey: Key.showLiveTranscript)
        defaults.removeObject(forKey: Key.includeClipboard)
        defaults.removeObject(forKey: Key.maxRecordingDuration)
        defaults.removeObject(forKey: Key.modelDirectory)

        logger.debug("AppSettings reset to defaults")
    }
}

// ---------------------------------------------------------------------------
// Int clamping helper
// ---------------------------------------------------------------------------

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
