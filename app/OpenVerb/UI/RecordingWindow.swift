import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// RecordingWindow — floating expanding recorder pod.
//
// The panel stays compact while the engine warms and while recording is silent.
// As soon as live partial text arrives, the visual pod expands downward and
// keeps the target app focused. The panel itself is resized with the top edge
// anchored so growth feels like the pod is unfolding below the waveform.
// ---------------------------------------------------------------------------

final class RecordingWindow: NSPanel {

    /// Set after init by AppDelegate to wire the Stop button to stopRecording().
    var onStop: (() -> Void)?

    init(appState: AppState,
         waveformVM: WaveformViewModel,
         processingVM: ProcessingViewModel,
         settings: AppSettings) {

        let size = NSSize(width: 392, height: 152)
        let rect = NSRect(origin: .zero, size: size)

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isMovableByWindowBackground = false
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        appearance = nil
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        let content = RecordingContentView(
            appState: appState,
            waveformVM: waveformVM,
            processingVM: processingVM,
            settings: settings,
            onStop: { [weak self] in self?.onStop?() },
            onHeightChange: { [weak self] height in
                self?.resizeKeepingTop(contentHeight: height)
            }
        )

        let hosting = NSHostingView(rootView: content)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        contentView = hosting
    }

    func show() {
        setFrame(NSRect(origin: frame.origin, size: NSSize(width: 392, height: 152)), display: false)
        recenterOnMouseScreen()
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    private func recenterOnMouseScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first

        guard let screen else { return }

        let sf = screen.frame
        let wf = frame
        let x = sf.midX - wf.width / 2
        let y = sf.minY + sf.height * 0.70 - wf.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func resizeKeepingTop(contentHeight: CGFloat) {
        let width: CGFloat = 392
        let height = max(152, min(340, contentHeight))
        guard abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 else { return }

        let top = frame.maxY
        var newFrame = frame
        newFrame.size = NSSize(width: width, height: height)
        newFrame.origin.y = top - height
        setFrame(newFrame, display: true, animate: true)
    }
}

// ---------------------------------------------------------------------------
// RecordingContentView
// ---------------------------------------------------------------------------

struct RecordingContentView: View {

    @ObservedObject var appState: AppState
    @ObservedObject var waveformVM: WaveformViewModel
    @ObservedObject var processingVM: ProcessingViewModel
    @ObservedObject var settings: AppSettings
    var onStop: (() -> Void)?
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @State private var previousState: AppState.State = .idle
    @State private var elapsedSeconds = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var settleTask: Task<Void, Never>?
    @State private var polishSettled = false
    @State private var tokens: [LiveTranscriptToken] = []

    private let contentWidth: CGFloat = 392
    private let visualWidth: CGFloat = 352
    private let shadowPadding: CGFloat = 20

    private let deepGreen = Color(red: 0.102, green: 0.137, blue: 0.086)
    private let ink = Color(red: 0.090, green: 0.129, blue: 0.075)
    private let inkSoft = Color(red: 0.235, green: 0.318, blue: 0.216)
    private let muted = Color(red: 0.427, green: 0.463, blue: 0.412)
    private let moss = Color(red: 0.345, green: 0.463, blue: 0.259)
    private let mossDark = Color(red: 0.192, green: 0.294, blue: 0.165)
    private let signalRed = Color(red: 0.937, green: 0.353, blue: 0.275)
    private let signalRedDark = Color(red: 0.722, green: 0.231, blue: 0.176)
    private let amber = Color(red: 0.784, green: 0.533, blue: 0.239)

    var body: some View {
        let visualHeight = podVisualHeight
        let contentHeight = visualHeight + shadowPadding * 2

        ZStack(alignment: .top) {
            pod
                .frame(width: visualWidth, height: visualHeight, alignment: .top)
                .padding(shadowPadding)
        }
        .background(Color.clear)
        .frame(width: contentWidth, height: contentHeight, alignment: .top)
        .onAppear {
            previousState = appState.state
            syncForState(appState.state)
            refreshTokens(animatedPolish: false)
            publishHeight(contentHeight)
        }
        .onDisappear {
            timerTask?.cancel()
            settleTask?.cancel()
        }
        .onChange(of: appState.state) { newState in
            syncForState(newState)
            refreshTokens(animatedPolish: false)
            previousState = newState
            publishHeight(contentHeight)
        }
        .onChange(of: appState.livePartialText) { _ in
            refreshTokens(animatedPolish: false)
            publishHeight(contentHeight)
        }
        .onChange(of: appState.polishedText) { _ in
            refreshTokens(animatedPolish: true)
            publishHeight(contentHeight)
        }
        .onChange(of: podVisualHeight) { height in
            publishHeight(height + shadowPadding * 2)
        }
        .onChange(of: processingVM.isPolishing) { _ in
            publishHeight(contentHeight)
        }
        .animation(.easeInOut(duration: 0.26), value: hasLiveStream)
        .animation(.easeInOut(duration: 0.24), value: liveViewportHeight)
    }

    private var pod: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if settings.showWaveform {
                ZStack(alignment: .bottom) {
                    WaveformView(viewModel: waveformVM)
                        .frame(maxWidth: .infinity)
                        .opacity(phase == .warming || phase == .processing || phase == .polishing ? 0.42 : 1)

                    if phase == .warming || phase == .processing || phase == .polishing {
                        HUDLoadingBar(
                            progress: processingVM.displayedPercent,
                            indeterminate: phase == .warming || processingVM.showSpinner || processingVM.displayedPercent == 0
                        )
                        .offset(y: 3)
                    }
                }
            } else if phase == .warming || phase == .processing || phase == .polishing {
                HUDLoadingBar(
                    progress: processingVM.displayedPercent,
                    indeterminate: phase == .warming || processingVM.showSpinner || processingVM.displayedPercent == 0
                )
            }

            if hasLiveStream {
                Divider()
                    .background(deepGreen.opacity(0.10))

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        phasePill
                        Spacer()
                        Text(liveMetaLabel)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(muted)
                    }

                    LiveStreamText(tokens: tokens)
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: liveViewportHeight, alignment: .topLeading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.36))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(deepGreen.opacity(0.08), lineWidth: 1)
                        )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color.white.opacity(0.90),
                        Color(red: 0.929, green: 0.965, blue: 0.910).opacity(0.76)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: deepGreen.opacity(0.22), radius: 28, x: 0, y: 10)
        .shadow(color: deepGreen.opacity(0.10), radius: 6, x: 0, y: 2)
    }

    private var header: some View {
        HStack(spacing: 9) {
            HUDStatusDot(phase: phase)
                .id("dot-\(phase)")

            Text(statusLabel)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(inkSoft)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(timeLabel)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(muted)

            Button(action: { onStop?() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 34, height: 30)
                    .foregroundStyle(.white)
                    .background(phase == .recording ? signalRed : deepGreen.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(phase != .recording)
            .opacity(phase == .recording ? 1 : 0.55)
            .accessibilityLabel("Stop recording")
        }
    }

    private var phasePill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(pillColor)
                .frame(width: 7, height: 7)
                .shadow(color: pillColor.opacity(0.55), radius: 5, x: 0, y: 0)

            Text(pillLabel)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(pillColor)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(pillColor.opacity(0.10))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(pillColor.opacity(0.16), lineWidth: 1))
    }

    private var phase: HUDPhase {
        switch appState.state {
        case .preparing:
            return .warming
        case .recording:
            return .recording
        case .inferring:
            if appState.polishedText != nil {
                return polishSettled ? .inserted : .polishing
            }
            return processingVM.isPolishing ? .polishing : .processing
        case .error:
            return .error
        case .idle:
            return .inserted
        }
    }

    private var hasLiveStream: Bool {
        settings.showLiveTranscript && !tokens.isEmpty && phase != .warming
    }

    private var podVisualHeight: CGFloat {
        let compact: CGFloat = phase == .warming ? 104 : 112
        guard hasLiveStream else { return compact }
        return compact + 11 + 1 + 9 + 24 + 9 + liveViewportHeight + 20
    }

    private var liveViewportHeight: CGFloat {
        let count = max(tokens.count, 1)
        let estimatedLines = max(1, min(5, Int(ceil(Double(count) / 7.0))))
        return max(52, min(136, CGFloat(estimatedLines) * 23 + 18))
    }

    private var statusLabel: String {
        switch phase {
        case .warming:
            return "Warming engine"
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .polishing:
            return "Polishing"
        case .inserted:
            return appState.state == .idle ? "Ready" : "Inserted"
        case .error:
            return "Needs attention"
        }
    }

    private var timeLabel: String {
        switch phase {
        case .warming:
            return "..."
        case .recording:
            return String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
        case .processing, .polishing:
            return processingVM.etaText ?? "..."
        case .inserted:
            return String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
        case .error:
            return "--:--"
        }
    }

    private var pillLabel: String {
        switch phase {
        case .recording:  return "LIVE DRAFT"
        case .processing: return "PROCESSING"
        case .polishing:  return "POLISHING"
        case .inserted:   return "INSERTED"
        case .error:      return "ERROR"
        case .warming:    return "ENGINE"
        }
    }

    private var liveMetaLabel: String {
        switch phase {
        case .recording:  return "TYPING"
        case .processing: return "CHECKING"
        case .polishing:  return "REWRITING"
        case .inserted:   return "DONE"
        case .error:      return "MICROPHONE"
        case .warming:    return "LOADING MODEL"
        }
    }

    private var pillColor: Color {
        switch phase {
        case .recording:  return signalRedDark
        case .processing, .polishing, .warming: return amber
        case .inserted:   return mossDark
        case .error:      return signalRedDark
        }
    }

    private func publishHeight(_ height: CGFloat) {
        DispatchQueue.main.async {
            onHeightChange(height)
        }
    }

    private func syncForState(_ state: AppState.State) {
        if state == .recording {
            startElapsedTimer()
        } else if previousState == .recording {
            stopElapsedTimer()
        }
        if state == .preparing || state == .idle {
            settleTask?.cancel()
            polishSettled = false
        }
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

    private func refreshTokens(animatedPolish: Bool) {
        settleTask?.cancel()

        if case .error(let message) = appState.state {
            tokens = LiveTranscriptRenderer.tokens(from: message, status: .pending)
            return
        }

        guard settings.showLiveTranscript else {
            tokens = []
            return
        }

        let raw = appState.livePartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let polished = appState.polishedText?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let polished, !polished.isEmpty, appState.state == .inferring {
            if polishSettled {
                tokens = LiveTranscriptRenderer.tokens(from: polished, status: .polished)
                return
            }

            tokens = LiveTranscriptRenderer.revisionTokens(raw: raw, polished: polished)
            guard animatedPolish else { return }

            settleTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(760))
                guard !Task.isCancelled else { return }
                polishSettled = true
                tokens = LiveTranscriptRenderer.tokens(from: polished, status: .polished)
                publishHeight(podVisualHeight + shadowPadding * 2)
            }
            return
        }

        polishSettled = false
        tokens = LiveTranscriptRenderer.tokens(from: raw, status: .confirmed)
    }
}

private enum HUDPhase: String, Equatable {
    case warming
    case recording
    case processing
    case polishing
    case inserted
    case error
}

private struct LiveStreamText: View {
    var tokens: [LiveTranscriptToken]

    private let inkSoft = Color(red: 0.235, green: 0.318, blue: 0.216)
    private let muted = Color(red: 0.427, green: 0.463, blue: 0.412)
    private let mossDark = Color(red: 0.192, green: 0.294, blue: 0.165)
    private let signalRed = Color(red: 0.937, green: 0.353, blue: 0.275)
    private let signalRedDark = Color(red: 0.722, green: 0.231, blue: 0.176)

    var body: some View {
        tokenText
            .font(.system(size: 15, weight: .semibold))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.18), value: tokens)
    }

    private var tokenText: Text {
        tokens.reduce(Text("")) { partial, token in
            partial + styledText(for: token) + Text(" ")
        }
    }

    private func styledText(for token: LiveTranscriptToken) -> Text {
        let text = Text(token.display)
        switch token.status {
        case .confirmed:
            return text.foregroundColor(inkSoft)
        case .pending:
            return text.foregroundColor(signalRed.opacity(0.72))
        case .wrong:
            return text
                .foregroundColor(signalRedDark)
                .strikethrough(true, color: signalRed)
        case .correction:
            return text
                .foregroundColor(mossDark)
                .fontWeight(.bold)
        case .polished:
            return text
                .foregroundColor(inkSoft)
                .fontWeight(.semibold)
        }
    }
}

private struct HUDStatusDot: View {
    var phase: HUDPhase
    @State private var pulsing = false
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            if phase == .warming {
                Circle()
                    .trim(from: 0.15, to: 0.82)
                    .stroke(dotColor.opacity(0.80), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 0.82).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            }

            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .opacity(pulsing ? 0.46 : 1.0)
                .scaleEffect(pulsing ? 0.88 : 1.0)
                .shadow(color: dotColor.opacity(0.65), radius: 8, x: 0, y: 0)
                .onAppear {
                    if phase != .inserted {
                        withAnimation(.easeInOut(duration: 0.86).repeatForever(autoreverses: true)) {
                            pulsing = true
                        }
                    }
                }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dotColor: Color {
        switch phase {
        case .recording:
            return Color(red: 0.937, green: 0.353, blue: 0.275)
        case .warming, .processing, .polishing:
            return Color(red: 0.784, green: 0.533, blue: 0.239)
        case .inserted:
            return Color(red: 0.345, green: 0.463, blue: 0.259)
        case .error:
            return Color(red: 0.722, green: 0.231, blue: 0.176)
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .warming:    return "Engine warming"
        case .recording:  return "Recording"
        case .processing: return "Processing"
        case .polishing:  return "Polishing"
        case .inserted:   return "Inserted"
        case .error:      return "Error"
        }
    }
}

private struct HUDLoadingBar: View {
    var progress: Double
    var indeterminate: Bool
    @State private var shimmerOffset: CGFloat = -0.5

    private let moss = Color(red: 0.337, green: 0.455, blue: 0.251)
    private let amber = Color(red: 0.784, green: 0.533, blue: 0.239)
    private let track = Color(red: 0.102, green: 0.137, blue: 0.086).opacity(0.08)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(track)

                if indeterminate {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [.clear, amber.opacity(0.80), moss.opacity(0.72), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
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
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [moss, amber.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, progress))))
                        .animation(.easeInOut(duration: 0.2), value: progress)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .frame(height: 3)
    }
}
