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
//   • Crossfade: RECORDING→INFERRING fades WaveformView out and ProcessingView
//     in over 150 ms via SwiftUI .transition(.opacity).
// ---------------------------------------------------------------------------

final class RecordingWindow: NSPanel {

    // -----------------------------------------------------------------------
    // Init — build the panel and embed the SwiftUI content.
    // -----------------------------------------------------------------------

    init(appState: AppState,
         waveformVM: WaveformViewModel,
         processingVM: ProcessingViewModel) {

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

        let content = RecordingContentView(
            appState: appState,
            waveformVM: waveformVM,
            processingVM: processingVM
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

    var body: some View {
        ZStack {
            // Background capsule with vibrancy + shadow.
            RoundedRectangle(cornerRadius: 24)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
                .padding(20)  // The shadow must not be clipped by window bounds.

            VStack(spacing: 8) {
                ZStack {
                    if appState.state == .recording {
                        WaveformView(viewModel: waveformVM)
                            .transition(.opacity)
                    }
                    if appState.state == .inferring {
                        ProcessingView(viewModel: processingVM)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: appState.state == .recording)
                .animation(.easeInOut(duration: 0.15), value: appState.state == .inferring)

                if let subtitle = appState.preparingSubtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: appState.preparingSubtitle)
                }
            }
        }
        .frame(width: 340, height: 120)
    }
}
