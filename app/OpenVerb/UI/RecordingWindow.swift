import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// RecordingWindow — center-screen floating overlay panel.
//
// Design (recording-hud kit):
//   • NSPanel with .nonactivatingPanel so it NEVER steals focus from the
//     target app.  Text injection requires the target to remain active.
//   • Positioned on the screen containing the mouse cursor; centered
//     horizontally, ~30% from the top.
//   • Background: clear + borderless; shadow applied by the SwiftUI content
//     view (not by the window) so it is not clipped by the transparent rect.
//   • Appearance: nil → inherits system appearance; SwiftUI background uses
//     .regularMaterial + warm moss/dolomite tint overlay.
//   • Content: hosts RecordingContentView (waveform + status row + loading bar)
//     wrapped in NSHostingView.
//   • Crossfade: RECORDING→INFERRING fades loading bar in over waveform
//     (0.15 s easeIn), then removes waveform (0.05 s easeOut) — no gap.
//   • onStop: settable callback, wired by AppDelegate to stopRecording().
// ---------------------------------------------------------------------------

final class RecordingWindow: NSPanel {

    /// Set after init by AppDelegate to wire the Stop button to stopRecording().
    var onStop: (() -> Void)?

    // -----------------------------------------------------------------------
    // Init — build the panel and embed the SwiftUI content.
    // -----------------------------------------------------------------------

    init(appState: AppState,
         waveformVM: WaveformViewModel,
         processingVM: ProcessingViewModel,
         settings: AppSettings) {

        // Window is larger than the visual panel to give the drop-shadow room.
        // Visual panel: 360 × 120 pt.  Shadow padding: 20 pt each side → 400 × 160.
        let size = NSSize(width: 400, height: 160)
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

        // The closure captures self weakly so onStop can be set after init.
        let content = RecordingContentView(
            appState: appState,
            waveformVM: waveformVM,
            processingVM: processingVM,
            settings: settings,
            onStop: { [weak self] in self?.onStop?() }
        )
        let hosting = NSHostingView(rootView: content)
        // NSHostingView gets an opaque CALayer by default which makes the
        // transparent window corners render grey.  Force the layer transparent
        // so only the SwiftUI-drawn content (rounded panel + shadow) is visible.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        self.contentView = hosting
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
//
// Layout (inside 360 × 120 pt visual panel, 20 pt shadow padding each side):
//   RECORDING  → WaveformView (44 pt) + status row (dot · label · timer · [Stop])
//   INFERRING  → HUDLoadingBar (4 pt) + status row (dot · label · ETA)
//                + hint text ("Transcribing..." / "Полирую…")
//   PREPARING  → status row only (dot · preparingSubtitle)
// ---------------------------------------------------------------------------

struct RecordingContentView: View {

    @ObservedObject var appState: AppState
    @ObservedObject var waveformVM: WaveformViewModel
    @ObservedObject var processingVM: ProcessingViewModel
    @ObservedObject var settings: AppSettings
    var onStop: (() -> Void)?

    @State private var showRecording = false
    @State private var showInferring = false
    @State private var previousState: AppState.State = .idle
    @State private var elapsedSeconds = 0
    // Task-based timer: more reliable than Timer.publish inside a non-activating
    // NSPanel where the run loop mode may not deliver timer events consistently.
    @State private var timerTask: Task<Void, Never>?

    // Design-system colors (from recording-hud kit)
    private let deepGreen  = Color(red: 0.102, green: 0.137, blue: 0.086) // #1A2316
    private let fg2        = Color(red: 0.204, green: 0.278, blue: 0.161) // #344729
    private let fg3        = Color(red: 0.369, green: 0.322, blue: 0.267) // #5E5244
    private let signalRed  = Color(red: 0.784, green: 0.322, blue: 0.227) // #C8523A

    var body: some View {
        ZStack {
            // ---- Background: warm glass (NO .regularMaterial — NSVisualEffectView
            //      bleeds outside the rounded rect and makes the window corners grey).
            //      Use a semi-opaque gradient so the transparent corners are truly clear.
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(
                    colors: [
                        Color.white.opacity(0.88),
                        Color(red: 0.941, green: 0.910, blue: 0.843).opacity(0.82)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.white.opacity(0.65), lineWidth: 1)
                )
                .shadow(color: deepGreen.opacity(0.22), radius: 28, x: 0, y: 10)
                .shadow(color: deepGreen.opacity(0.10), radius:  6, x: 0, y:  2)
                .padding(20)

            // ---- Content stack ----
            VStack(alignment: .leading, spacing: 6) {

                // Waveform (recording)
                if showRecording && settings.showWaveform {
                    WaveformView(viewModel: waveformVM)
                        .transition(.opacity)
                }

                // Loading bar (inferring)
                if showInferring {
                    HUDLoadingBar(
                        progress: processingVM.displayedPercent,
                        indeterminate: processingVM.showSpinner || processingVM.displayedPercent == 0
                    )
                    .padding(.bottom, 2)
                    .transition(.opacity)
                }

                // Status row: dot · label · timer/ETA · [Stop]
                HStack(spacing: 8) {
                    HUDStatusDot(isRecording: showRecording, isProcessing: showInferring)
                        .id("dot-\(showRecording)-\(showInferring)")

                    Text(statusLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(fg2)

                    if showRecording {
                        Text(timerString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(fg2)
                    }

                    if showInferring, let eta = processingVM.etaText {
                        Text(eta)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(fg2)
                    }

                    Spacer()

                    if showRecording {
                        Button(action: { onStop?() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Stop")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(signalRed)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }

                // Processing hint text
                if showInferring {
                    Text(processingVM.isPolishing ? "Полирую…" : "Transcribing...")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(fg3)
                        .transition(.opacity)
                }

                // Live partial transcript — opt-in via showLiveTranscript.
                if settings.showLiveTranscript,
                   !appState.livePartialText.isEmpty,
                   showRecording || showInferring {
                    Text(appState.livePartialText)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.1), value: appState.livePartialText)
                }
            }
            .padding(.horizontal, 36)    // 20 pt shadow + 16 pt inner
        }
        .background(Color.clear)         // prevent NSHostingView from painting behind the ZStack
        .frame(width: 400, height: 160)
        .onAppear {
            syncDisplayState(with: appState.state)
            previousState = appState.state
        }
        .onChange(of: appState.state) { newState in
            if newState == .recording {
                startElapsedTimer()
            } else if previousState == .recording {
                stopElapsedTimer()
            }
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

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    private var statusLabel: String {
        if processingVM.isPolishing      { return "Полирую…" }
        if showInferring                 { return "Processing" }
        if showRecording                 { return "Recording" }
        return appState.preparingSubtitle ?? ""
    }

    private var timerString: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    private func startElapsedTimer() {
        timerTask?.cancel()
        elapsedSeconds = 0
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                elapsedSeconds += 1
            }
        }
    }

    private func stopElapsedTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func syncDisplayState(with state: AppState.State) {
        let isRec = state == .recording
        let isInf = state == .inferring
        if showRecording != isRec { showRecording = isRec }
        if showInferring != isInf { showInferring = isInf }
    }
}

// ---------------------------------------------------------------------------
// HUDStatusDot — pulsing 8 pt colored circle.
// Color: signal-record (#C8523A) while recording, signal-process (#C88A3A)
// while processing, dolomite-500 (#7A6C58) otherwise.
// Uses the .id() trick in the parent so onAppear fires cleanly on state change.
// ---------------------------------------------------------------------------

private struct HUDStatusDot: View {
    var isRecording: Bool
    var isProcessing: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .opacity(pulsing ? 0.42 : 1.0)
            .scaleEffect(pulsing ? 0.88 : 1.0)
            .onAppear {
                if isRecording || isProcessing {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                }
            }
    }

    private var dotColor: Color {
        if isRecording  { return Color(red: 0.784, green: 0.322, blue: 0.227) }  // #C8523A
        if isProcessing { return Color(red: 0.784, green: 0.541, blue: 0.227) }  // #C88A3A
        return Color(red: 0.478, green: 0.424, blue: 0.345)                      // #7A6C58
    }
}

// ---------------------------------------------------------------------------
// HUDLoadingBar — 4 pt horizontal bar.
//
//   indeterminate = true  → sweeping shimmer (no progress data yet / spinner)
//   indeterminate = false → deterministic green fill proportional to `progress`
// ---------------------------------------------------------------------------

private struct HUDLoadingBar: View {
    var progress: Double
    var indeterminate: Bool
    @State private var shimmerOffset: CGFloat = -0.5

    private let moss  = Color(red: 0.337, green: 0.455, blue: 0.251) // #567540
    private let track = Color(red: 0.102, green: 0.137, blue: 0.086).opacity(0.08)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(track)

                if indeterminate {
                    // Shimmer: a 45%-wide gradient that sweeps left → right.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [.clear, moss.opacity(0.75), .clear],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: shimmerOffset * geo.size.width)
                        .onAppear {
                            shimmerOffset = -0.5
                            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                                shimmerOffset = 1.1
                            }
                        }
                } else {
                    // Determinate fill.
                    RoundedRectangle(cornerRadius: 2)
                        .fill(moss)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, progress))))
                        .animation(.easeInOut(duration: 0.2), value: progress)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .frame(height: 4)
    }
}
