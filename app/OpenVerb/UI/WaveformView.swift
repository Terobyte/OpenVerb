import SwiftUI
import Foundation

// ---------------------------------------------------------------------------
// WaveformView — real-time audio amplitude bar chart.
//
// Design:
//   • WaveformViewModel is an ObservableObject; @Published amplitudes drives
//     the bar chart.
//   • updateAmplitude(_:) is called from AudioSession's tap callback on a
//     background audio thread — it dispatches to main before mutating @Published.
//   • 30-bar ring buffer; bars animate smoothly with .linear(duration: 0.05).
//   • Height must match ProcessingView for seamless crossfade.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// WaveformViewModel
// ---------------------------------------------------------------------------

// #34: @MainActor ensures @Published mutations are always on the main actor,
// satisfying Swift 6 strict concurrency.  updateAmplitude and computeRMS are
// nonisolated so they can be called from the background audio tap thread.
@MainActor
final class WaveformViewModel: ObservableObject {

    @Published private(set) var amplitudes: [CGFloat] = []

    private let maxBars = 30

    /// Computes RMS amplitude from a PCM Int16 mono chunk and appends it to
    /// the ring buffer.  May be called from any thread; dispatches to main.
    nonisolated func updateAmplitude(_ data: Data) {
        let rms = WaveformViewModel.computeRMS(data)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.amplitudes.append(rms)
            if self.amplitudes.count > self.maxBars {
                self.amplitudes.removeFirst()
            }
        }
    }

    /// Resets the amplitude ring buffer (call on IDLE→PREPARING).
    func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.amplitudes.removeAll()
        }
    }

    // -----------------------------------------------------------------------
    // Private — RMS computation from raw PCM Int16 samples.
    // -----------------------------------------------------------------------

    nonisolated private static func computeRMS(_ data: Data) -> CGFloat {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }

        var sumSquares: Double = 0
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let samples = ptr.bindMemory(to: Int16.self)
            for sample in samples {
                let s = Double(sample) / Double(Int16.max)
                sumSquares += s * s
            }
        }
        return CGFloat(sqrt(sumSquares / Double(sampleCount)))
    }
}

// ---------------------------------------------------------------------------
// WaveformView
// ---------------------------------------------------------------------------

struct WaveformView: View {

    @ObservedObject var viewModel: WaveformViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(paddedAmplitudes.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barGradient)
                    .frame(width: 4, height: barHeight(paddedAmplitudes[i]))
            }
        }
        .frame(height: 40)
        .animation(.linear(duration: 0.05), value: viewModel.amplitudes)
    }

    // -----------------------------------------------------------------------
    // Private
    // -----------------------------------------------------------------------

    private var paddedAmplitudes: [CGFloat] {
        let bars = 30
        let amps = viewModel.amplitudes
        if amps.count >= bars { return Array(amps.suffix(bars)) }
        // Pad with zeros on the left so bars grow from left edge.
        let padding = [CGFloat](repeating: 0, count: bars - amps.count)
        return padding + amps
    }

    private func barHeight(_ amplitude: CGFloat) -> CGFloat {
        // Map 0.0–1.0 amplitude to 4–36 pt bar height.
        let clamped = min(max(amplitude, 0), 1)
        return 4 + clamped * 32
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.0, green: 0.78, blue: 0.85),
                     Color(red: 0.13, green: 0.53, blue: 0.96)],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}
