import Accelerate
import Foundation

final class FFTProcessor {

    static let bandCount = 24

    private let fftSize = 2048
    private let log2n: vDSP_Length = 11
    private let sampleRate: Float = 16_000
    private let fftSetup: FFTSetup
    private let hannWindow: [Float]
    private let bandEdges: [Int]

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        hannWindow = window

        let binsPerHz = Float(fftSize) / sampleRate
        let logMin = log2f(80)
        let logMax = log2f(7500)
        var edges = [Int]()
        for i in 0...Self.bandCount {
            let freq = exp2f(logMin + (logMax - logMin) * Float(i) / Float(Self.bandCount))
            let bin = max(1, Int(freq * binsPerHz + 0.5))
            edges.append(bin)
        }
        for i in 1...Self.bandCount {
            if edges[i] <= edges[i - 1] { edges[i] = edges[i - 1] + 1 }
        }
        bandEdges = edges
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func process(chunk: Data) -> [Float] {
        guard chunk.count == Constants.CHUNK_BYTES else {
            return [Float](repeating: 0, count: Self.bandCount)
        }

        // Unpack Int16 PCM → normalized Float, apply Hann window.
        var samples = [Float](repeating: 0, count: fftSize)
        chunk.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16s = ptr.bindMemory(to: Int16.self)
            for i in 0..<fftSize {
                samples[i] = Float(int16s[i]) / 32768
            }
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        // hannWindow is a `let` constant — pass directly (no `&`) for UnsafePointer.
        vDSP_vmul(&samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack windowed samples into split-complex layout required by vDSP_fft_zrip:
        // even-indexed samples → realp, odd-indexed → imagp.
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<fftSize / 2 {
            realp[i] = windowed[i * 2]
            imagp[i] = windowed[i * 2 + 1]
        }

        // Run the in-place real FFT.
        // Correct pipeline: zvmags → vvsqrtf → /N → true amplitude A.
        // Reversed order (zvmags → /N → sqrt) would scale output low by √N ≈ 45×.
        // Use withUnsafeMutableBufferPointer so DSPSplitComplex pointers stay valid.
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        realp.withUnsafeMutableBufferPointer { rPtr in
            imagp.withUnsafeMutableBufferPointer { iPtr in
                var sc = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                vDSP_fft_zrip(fftSetup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                // Step 1: squared magnitudes (real² + imag²).
                vDSP_zvmags(&sc, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
                // Step 2: sqrt → amplitude.  Must precede /N; √(power/N) ≠ √power/N.
                var halfN = Int32(fftSize / 2)
                magnitudes.withUnsafeMutableBufferPointer { buf in
                    vvsqrtf(buf.baseAddress!, buf.baseAddress!, &halfN)
                }
            }
        }
        // Step 3: divide by N → normalised amplitude A = magnitude / N.
        var invN: Float = 1.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &invN, &magnitudes, 1, vDSP_Length(fftSize / 2))

        // Average amplitudes within each log-spaced band.
        var bands = [Float](repeating: 0, count: Self.bandCount)
        magnitudes.withUnsafeBufferPointer { magPtr in
            for i in 0..<Self.bandCount {
                let lo = bandEdges[i]
                let hi = min(bandEdges[i + 1], fftSize / 2)
                guard lo < hi else { continue }
                var sum: Float = 0
                vDSP_sve(magPtr.baseAddress!.advanced(by: lo), 1, &sum, vDSP_Length(hi - lo))
                bands[i] = sum / Float(hi - lo)
            }
        }

        // Map amplitude → dB, then scale floor [−60, 0] dB to [0, 1].
        // Fixed scale gives stable bars; quiet signals show genuinely low bars.
        for i in 0..<Self.bandCount {
            let dB = 20 * log10f(max(bands[i], 1e-9))
            bands[i] = max(0, min(1, (dB + 60) / 60))
        }

        return bands
    }
}
