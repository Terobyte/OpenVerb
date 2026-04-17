import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// RecordingWindow — center-screen floating overlay panel.
//
// Design:
//   • NSPanel with .nonactivatingPanel so it NEVER steals focus from the
//     target app.  Text injection requires the target to remain active.
//   • Positioned on the screen containing the mouse cursor; centered
//     horizontally, ~30% from the top.
//   • Background: clear + borderless; shadow applied by the SwiftUI content
//     view (not by the window) so it is not clipped by the transparent rect.
//   • Appearance: nil → inherits system appearance; SwiftUI background uses
//     .regularMaterial for vibrancy in both light and dark mode.
//   • Content: hosts RecordingContentView (WaveformView + ProcessingView)
//     wrapped in NSHostingView.
//   • Crossfade: RECORDING→INFERRING fades ProcessingView in over WaveformView
//     (0.15 s easeIn), then removes WaveformView (0.05 s easeOut) — no gap.
// ---------------------------------------------------------------------------

final class RecordingWindow: NSPanel {

    // -----------------------------------------------------------------------
    // Init — build the panel and embed the SwiftUI content.
    // -----------------------------------------------------------------------

    init(appState: AppState,
         waveformVM: WaveformViewModel,
         processingVM: ProcessingViewModel,
         settings: AppSettings) {

        // Window dimensions include padding for the shadow (visual content is
        // ~300×80 pt; shadow padding adds ~20 pt on each side → 340×120 pt).
        let size = NSSize(width: 340, height: 120)
        let rect = NSRect(origin: .zero, size: size)

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.hasShadow = false   // Shadow is applied inside the SwiftUI layer.
        self.isOpaque = false
        self.appearance = nil    // Inherit system appearance.
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Bug 18: pass AppSettings into the SwiftUI content so showWaveform
        // gates the WaveformView and live-updates when the user toggles it.
        let content = RecordingContentView(
            appState: appState,
            waveformVM: waveformVM,
            processingVM: processingVM,
            settings: settings
        )
        self.contentView = NSHostingView(rootView: content)
    }

    // -----------------------------------------------------------------------
    // show — position on the mouse-cursor screen and bring forward.
    // -----------------------------------------------------------------------

    func show() {
        recenterOnMouseScreen()
        orderFrontRegardless()
    }

    // -----------------------------------------------------------------------
    // hide — remove from screen (MUST be called before targetApp.activate()).
    // -----------------------------------------------------------------------

    func hide() {
        orderOut(nil)
    }

    // -----------------------------------------------------------------------
    // Private — multi-display positioning.
    // -----------------------------------------------------------------------

    private func recenterOnMouseScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen = screen else { return }

        let sf = screen.frame
        let wf = frame
        let x = sf.midX - wf.width / 2
        let y = sf.minY + sf.height * 0.70 - wf.height / 2  // ~30% from top
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// ---------------------------------------------------------------------------
// RecordingContentView — SwiftUI root embedded in the panel.
// ---------------------------------------------------------------------------

struct RecordingContentView: View {

    @ObservedObject var appState: AppState
    @ObservedObject var waveformVM: WaveformViewModel
    @ObservedObject var processingVM: ProcessingViewModel
    /// Bug 18: read showWaveform live so toggling the preference takes effect
    /// during the next recording without an app restart.
    @ObservedObject var settings: AppSettings

    @State private var showRecording = false
    @State private var showInferring = false
    @State private var previousState: AppState.State = .idle

    var body: some View {
        ZStack {
            // Background capsule with vibrancy + shadow.
            RoundedRectangle(cornerRadius: 24)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
                .padding(20)  // The shadow must not be clipped by window bounds.

            VStack(spacing: 8) {
                ZStack {
                    if showRecording && settings.showWaveform {
                        WaveformView(viewModel: waveformVM)
                            .transition(.opacity)
                    }
                    if showInferring {
                        ProcessingView(viewModel: processingVM)
                            .transition(.opacity)
                    }
                }

                if let subtitle = appState.preparingSubtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: appState.preparingSubtitle)
                }

                // Live partial transcript — opt-in via showLiveTranscript.
                // Shows accumulated text below the waveform during recording
                // and inference so the user can see what was recognized.
                if settings.showLiveTranscript,
                   !appState.livePartialText.isEmpty,
                   (showRecording || showInferring) {
                    Text(appState.livePartialText)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: 280, alignment: .center)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.1), value: appState.livePartialText)
                }
            }
        }
        .frame(width: 340, height: 120)
        .onAppear {
            syncDisplayState(with: appState.state)
            previousState = appState.state
        }
        .onChange(of: appState.state) { newState in
            if previousState == .recording, newState == .inferring {
                withAnimation(.easeIn(duration: 0.15)) {
                    showInferring = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    withAnimation(.easeOut(duration: 0.05)) {
                        showRecording = false
                    }
                }
            } else {
                syncDisplayState(with: newState)
            }
            previousState = newState
        }
    }

    private func syncDisplayState(with state: AppState.State) {
        let isRec = state == .recording
        let isInf = state == .inferring
        if showRecording != isRec { showRecording = isRec }
        if showInferring != isInf { showInferring = isInf }
    }
}
