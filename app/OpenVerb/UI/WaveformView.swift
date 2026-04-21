import SwiftUI
import Foundation

// ---------------------------------------------------------------------------
// WaveformView — real-time FFT-based spectral bar chart.
//
// Design:
//   • updateFromChunk(_:) is the primary entry point: receives a 4096-byte
//     PCM chunk, runs a windowed 2048-point real FFT via FFTProcessor, maps
//     1024 magnitude bins to 24 log-spaced bands (80 Hz – 7.5 kHz), and
//     applies per-bar asymmetric EMA (attack 0.55, release 0.18).
//   • bins: [CGFloat] — 24 smoothed, normalized [0…1] spectral magnitudes.
//   • WaveformView renders bars with Capsule shapes, moss-700 → moss-300
//     gradient keyed to each bar's frequency band, and a spring animation
//     (response 0.25, damping 0.72).
//   • Height matches ProcessingView for seamless crossfade.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// WaveformViewModel
// ---------------------------------------------------------------------------

@MainActor
final class WaveformViewModel: ObservableObject {

    @Published private(set) var bins: [CGFloat] = Array(repeating: 0, count: FFTProcessor.bandCount)

    private var smoothed = [Float](repeating: 0, count: FFTProcessor.bandCount)
    private let attack: Float = 0.55
    private let release: Float = 0.18
    private let processor = FFTProcessor()

    // -----------------------------------------------------------------------
    // Primary entry point — AudioSession waveform callback.
    // -----------------------------------------------------------------------

    func updateFromChunk(_ data: Data) {
        let raw = processor.process(chunk: data)
        for i in 0..<FFTProcessor.bandCount {
            let target = raw[i]
            let old = smoothed[i]
            smoothed[i] = target > old
                ? attack * target + (1 - attack) * old
                : release * target + (1 - release) * old
        }
        bins = smoothed.map { CGFloat($0) }
    }

    // -----------------------------------------------------------------------
    // Reset — clears spectral bins (call on IDLE→PREPARING).
    // -----------------------------------------------------------------------

    func reset() {
        smoothed = [Float](repeating: 0, count: FFTProcessor.bandCount)
        bins = Array(repeating: 0, count: FFTProcessor.bandCount)
    }
}

// ---------------------------------------------------------------------------
// WaveformView
// ---------------------------------------------------------------------------

struct WaveformView: View {

    @ObservedObject var viewModel: WaveformViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(viewModel.bins.indices, id: \.self) { i in
                Capsule()
                    .fill(barGradient(for: i))
                    .frame(width: 9, height: barHeight(viewModel.bins[i]))
            }
        }
        .frame(height: 44)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: viewModel.bins)
    }

    // -----------------------------------------------------------------------
    // Private
    // -----------------------------------------------------------------------

    private func barHeight(_ amplitude: CGFloat) -> CGFloat {
        let clamped = min(max(amplitude, 0), 1)
        return 6 + clamped * 38
    }

    private func barGradient(for index: Int) -> LinearGradient {
        let t = CGFloat(index) / CGFloat(FFTProcessor.bandCount - 1)
        let topColor = Color(
            red:   0.235 + t * (0.623 - 0.235),
            green: 0.310 + t * (0.714 - 0.310),
            blue:  0.169 + t * (0.533 - 0.169)
        )
        let bottomColor = Color(
            red:   (0.235 + t * (0.623 - 0.235)) * 0.7,
            green: (0.310 + t * (0.714 - 0.310)) * 0.7,
            blue:  (0.169 + t * (0.533 - 0.169)) * 0.7
        )
        return LinearGradient(
            colors: [bottomColor, topColor],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}
