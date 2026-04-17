import SwiftUI

// ---------------------------------------------------------------------------
// ProcessingView — animated inference progress indicator.
//
// Design:
//   • Circular progress ring — determinate when progress messages arrive,
//     indeterminate spinner after a 2s fallback timer.
//   • displayedPercent is monotonically non-decreasing per session (non-
//     monotonic Path A estimates are clamped).
//   • RESET INVARIANT: reset() must be called on every IDLE→PREPARING so
//     the clamp variable starts at 0 for the new session.
//   • Height matches WaveformView (40 pt) for seamless crossfade.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// ProcessingViewModel
// ---------------------------------------------------------------------------

@MainActor
final class ProcessingViewModel: ObservableObject {

    @Published private(set) var displayedPercent: Double = 0.0
    @Published private(set) var showSpinner: Bool = false
    @Published private(set) var isPolishing: Bool = false

    // -----------------------------------------------------------------------
    // ETA countdown — set by updateEta(), decremented by tick(), cleared by
    // resetEta().  Non-nil only while waiting for streaming inference to finish.
    // -----------------------------------------------------------------------

    @Published private(set) var etaSeconds: Int?

    /// Human-readable countdown string, e.g. "~3 сек".
    /// Nil when no ETA is known (falls back to spinner / ring in the view).
    var etaText: String? {
        guard let s = etaSeconds, s > 0 else { return nil }
        return "~\(s) сек"
    }

    private var spinnerTask: Task<Void, Never>?

    // -----------------------------------------------------------------------
    // updateProgress — monotonic clamp; ignores backtracking estimates.
    // -----------------------------------------------------------------------

    func updateProgress(_ percent: Double) {
        guard percent > displayedPercent else { return }
        displayedPercent = min(percent, 1.0)
        spinnerTask?.cancel()
        spinnerTask = nil
        if showSpinner { showSpinner = false }
    }

    // -----------------------------------------------------------------------
    // updateEta — refresh the ETA from a queue_status heartbeat (ms → seconds).
    // -----------------------------------------------------------------------

    func updateEta(ms: Int) {
        let secs = max(0, (ms + 999) / 1000)  // round up to nearest second
        etaSeconds = secs > 0 ? secs : nil
        // Cancel spinner fallback — we have a real countdown now.
        spinnerTask?.cancel()
        spinnerTask = nil
        showSpinner = false
    }

    // -----------------------------------------------------------------------
    // tick — called every second by a Timer in OpenVerbApp to decrement ETA.
    // -----------------------------------------------------------------------

    func tick() {
        guard let s = etaSeconds else { return }
        etaSeconds = s > 1 ? s - 1 : nil
    }

    // -----------------------------------------------------------------------
    // resetEta — clears the countdown (e.g. when inference finishes or aborts).
    // -----------------------------------------------------------------------

    func resetEta() {
        etaSeconds = nil
    }

    // -----------------------------------------------------------------------
    // enterPolishing / exitPolishing — show "Полирую…" state while the engine
    // runs the LLM cleanup pass on the raw transcript.
    // -----------------------------------------------------------------------

    func enterPolishing() {
        isPolishing = true
    }

    func exitPolishing() {
        isPolishing = false
    }

    // -----------------------------------------------------------------------
    // reset — MUST be called on every IDLE→PREPARING transition.
    // -----------------------------------------------------------------------

    func reset() {
        spinnerTask?.cancel()
        spinnerTask = nil
        displayedPercent = 0.0
        showSpinner = false
        etaSeconds = nil
        isPolishing = false
    }

    // -----------------------------------------------------------------------
    // startSpinnerFallback — called after 2s if no progress message received.
    // -----------------------------------------------------------------------

    func startSpinnerFallback() {
        // If an ETA is already showing, no spinner fallback needed.
        guard etaSeconds == nil else { return }
        spinnerTask?.cancel()
        spinnerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            // Only show spinner if ETA still not known after 2 s.
            if self?.etaSeconds == nil {
                self?.showSpinner = true
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ProcessingView
// ---------------------------------------------------------------------------

struct ProcessingView: View {

    @ObservedObject var viewModel: ProcessingViewModel

    var body: some View {
        ZStack {
            if viewModel.isPolishing {
                // Polish pass in progress — show "Полирую…" label.
                Text("Полирую…")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(height: 40)
                    .transition(.opacity)
            } else if let eta = viewModel.etaText {
                // Countdown label — shows ~N сек while streaming inference drains.
                Text(eta)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(height: 40)
                    .transition(.opacity)
            } else if viewModel.showSpinner {
                // Indeterminate spinner — no progress messages received.
                IndeterminateRing()
                    .frame(width: 36, height: 36)
            } else {
                // Determinate ring — shows inference progress.
                DeterminateRing(progress: viewModel.displayedPercent)
                    .frame(width: 36, height: 36)
            }
        }
        .frame(height: 40)
        .animation(.easeInOut(duration: 0.2), value: viewModel.displayedPercent)
        .animation(.easeInOut(duration: 0.3), value: viewModel.etaText)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isPolishing)
    }
}

// ---------------------------------------------------------------------------
// DeterminateRing — circular progress arc.
// ---------------------------------------------------------------------------

private struct DeterminateRing: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.0, green: 0.78, blue: 0.85),
                                 Color(red: 0.13, green: 0.53, blue: 0.96)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}

// ---------------------------------------------------------------------------
// IndeterminateRing — spinning arc for when no progress data is available.
// ---------------------------------------------------------------------------

private struct IndeterminateRing: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(
                LinearGradient(
                    colors: [Color(red: 0.0, green: 0.78, blue: 0.85),
                             Color(red: 0.13, green: 0.53, blue: 0.96)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
