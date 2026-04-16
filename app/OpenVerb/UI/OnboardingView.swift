import SwiftUI
import AVFoundation
import ApplicationServices
import AppKit

// ---------------------------------------------------------------------------
// OnboardingView — first-launch wizard.
//
// Steps:
//   welcome         — intro screen
//   microphone      — request AVCaptureDevice audio access
//   accessibility   — prompt for AX permission (optional, opens System Settings)
//   inputMonitoring — inform user about Input Monitoring (cannot request programmatically)
//   modelDownload   — download + verify GGUF model via ModelDownloader
//   done            — success; calls onComplete() to trigger normalStartup()
// ---------------------------------------------------------------------------

struct OnboardingView: View {

    @ObservedObject var downloader: ModelDownloader
    @State private var step: OnboardingStep = .welcome
    @State private var micGranted = false

    enum OnboardingStep: Int, CaseIterable {
        case welcome, microphone, accessibility, inputMonitoring, modelDownload, done
    }

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .welcome:        welcomeStep
            case .microphone:     microphoneStep
            case .accessibility:  accessibilityStep
            case .inputMonitoring: inputMonitoringStep
            case .modelDownload:  modelDownloadStep
            case .done:           doneStep
            }
        }
        .frame(width: 480, height: 360)
        .padding(32)
    }

    // -- Steps --

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Welcome to OpenVerb")
                .font(.title)
            Text("100% local voice-to-text. No cloud, no data leaves your device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Get Started") { step = .microphone }
                .buttonStyle(.borderedProminent)
        }
    }

    private var microphoneStep: some View {
        permissionStep(
            icon: "mic.fill",
            title: "Microphone",
            description: "OpenVerb needs microphone access to record your voice.",
            action: {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        micGranted = granted
                        step = .accessibility
                    }
                }
            },
            buttonTitle: "Allow Microphone"
        )
    }

    private var accessibilityStep: some View {
        permissionStep(
            icon: "hand.raised.fill",
            title: "Accessibility",
            description: "Optional but recommended. Enables context-aware text (window title, selected text).",
            action: {
                // #44: takeUnretainedValue() — kAXTrustedCheckOptionPrompt has +0 refcount.
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
                step = .inputMonitoring
            },
            buttonTitle: "Open Accessibility Settings",
            isOptional: true,
            skipAction: { step = .inputMonitoring }
        )
    }

    private var inputMonitoringStep: some View {
        // Input Monitoring cannot be requested programmatically — macOS shows
        // the system prompt only when a CGEvent tap is first created (on first
        // ⌥Space press). This step informs the user and provides a direct link.
        permissionStep(
            icon: "keyboard.fill",
            title: "Input Monitoring",
            description: "Required for the ⌥Space global hotkey.\n\nmacOS will ask for this permission the first time you press ⌥Space. You can also grant it now in System Settings.",
            action: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring") {
                    NSWorkspace.shared.open(url)
                }
                step = .modelDownload
            },
            buttonTitle: "Open Settings & Continue",
            isOptional: true,
            skipAction: { step = .modelDownload }
        )
    }

    private var modelDownloadStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Download Model")
                .font(.title2)
            Text("Gemma 4 E2B (~1.5 GB). One-time download.")
                .foregroundStyle(.secondary)

            if downloader.isDownloading {
                ProgressView(value: downloader.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(downloader.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { downloader.cancel() }
            } else if let err = downloader.error {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                Button("Retry") { Task { try? await downloader.download() } }
            } else if downloader.progress >= 1.0 {
                Label("Download complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Continue") { step = .done }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Download") { Task { try? await downloader.download() } }
                    .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
    }

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're all set!")
                .font(.title)
            Text("Press ⌥Space anywhere to start dictating.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Start Using OpenVerb") { onComplete() }
                .buttonStyle(.borderedProminent)
        }
    }

    // -- Reusable permission step template --

    private func permissionStep(
        icon: String,
        title: String,
        description: String,
        action: @escaping () -> Void,
        buttonTitle: String,
        isOptional: Bool = false,
        skipAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text(title).font(.title2)
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                if isOptional, let skip = skipAction {
                    Button("Skip") { skip() }
                }
                Button(buttonTitle) { action() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
