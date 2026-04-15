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
    // reset — MUST be called on every IDLE→PREPARING transition.
    // -----------------------------------------------------------------------

    func reset() {
        spinnerTask?.cancel()
        spinnerTask = nil
        displayedPercent = 0.0
        showSpinner = false
    }

    // -----------------------------------------------------------------------
    // startSpinnerFallback — called after 2s if no progress message received.
    // -----------------------------------------------------------------------

    func startSpinnerFallback() {
        spinnerTask?.cancel()
        spinnerTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            self?.showSpinner = true
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
            if viewModel.showSpinner {
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
