import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// FFTProcessorTests — unit tests for FFTProcessor.
//
// testSilenceProducesZeroBins     : all-zero input → all-zero output
// testSineAt1kHzPeaksInMidBand   : 1 kHz sine peaks in band 13 (±1)
// testSubThresholdSineClampsToZero: amplitude below −60 dB floor → all zeros
// testWrongSizeReturnsZeros       : off-size chunks return zeros, no crash
//
// Normalisation: pipeline is zvmags → vvsqrtf → /N → dB → [0,1].
// Fixed scale: [−60, 0] dB maps to [0, 1].  Signals below −60 dB → 0.
// ---------------------------------------------------------------------------

final class FFTProcessorTests: XCTestCase {

    private var processor: FFTProcessor!

    override func setUp() {
        super.setUp()
        processor = FFTProcessor()
    }

    // MARK: - Silence

    func testSilenceProducesZeroBins() {
        let silence = Data(count: Constants.CHUNK_BYTES)
        let bins = processor.process(chunk: silence)
        XCTAssertEqual(bins.count, FFTProcessor.bandCount,
                       "Should return exactly \(FFTProcessor.bandCount) bins")
        XCTAssertTrue(bins.allSatisfy { $0 == 0 },
                      "All bins must be zero for all-zero (silence) input")
    }

    // MARK: - 1 kHz sine

    // 1 kHz at 16 kHz SR occupies FFT bin 128, which maps to log-spaced band 13
    // (0-indexed) in the 24-band 80 Hz – 7.5 kHz layout.
    // With dB-floor normalisation (−60…0 dB → 0…1), amplitude 0.8 at 1 kHz
    // maps to ~−8 dB → 0.87 in [0, 1].  The ±1 window catches off-by-many.
    func testSineAt1kHzPeaksInMidBand() {
        let sineData = makeSine(frequency: 1000, amplitude: 0.8)
        let bins = processor.process(chunk: sineData)

        guard let maxVal = bins.max(), let peakIdx = bins.firstIndex(of: maxVal) else {
            XCTFail("Expected non-empty bins for sine input")
            return
        }

        // 1 kHz peaks in band 13 (not 15-18); tight ±1 window catches off-by-many.
        XCTAssertTrue(peakIdx >= 12 && peakIdx <= 14,
                      "1 kHz sine should peak in band 12–14 (~13), got band \(peakIdx)")
        XCTAssertGreaterThan(maxVal, Float(0.3),
                             "Peak band should have significant magnitude")
        XCTAssertLessThan(bins[0], maxVal * Float(0.3),
                          "Low-frequency band 0 should be much weaker than peak")
        XCTAssertLessThan(bins[FFTProcessor.bandCount - 1], maxVal * Float(0.5),
                          "High-frequency band 23 should be weaker than peak")
    }

    // MARK: - dB floor

    // amplitude 0.001 → ~−72 dB after /N, which is below the −60 dB floor → 0.
    func testSubThresholdSineClampsToZero() {
        let quietData = makeSine(frequency: 1000, amplitude: 0.001)
        let bins = processor.process(chunk: quietData)
        XCTAssertEqual(bins.count, FFTProcessor.bandCount)
        XCTAssertTrue(bins.allSatisfy { $0 == 0 },
                      "Sine below −60 dB floor should clamp all bins to zero")
    }

    // MARK: - Wrong-size input

    func testWrongSizeReturnsZeros() {
        let short = Data(count: 1024)
        let long  = Data(count: 8192)

        let shortBins = processor.process(chunk: short)
        XCTAssertEqual(shortBins.count, FFTProcessor.bandCount)
        XCTAssertTrue(shortBins.allSatisfy { $0 == 0 },
                      "Short chunk (1024 bytes) should return all zeros, no crash")

        let longBins = processor.process(chunk: long)
        XCTAssertEqual(longBins.count, FFTProcessor.bandCount)
        XCTAssertTrue(longBins.allSatisfy { $0 == 0 },
                      "Long chunk (8192 bytes) should return all zeros, no crash")
    }

    // MARK: - Helpers

    /// Returns a 4096-byte Data buffer containing one CHUNK_BYTES block of a pure
    /// sine wave at `frequency` Hz sampled at 16 kHz, with amplitude scaled to
    /// `amplitude × Int16.max`.
    private func makeSine(frequency: Float, amplitude: Float) -> Data {
        let sampleRate: Float = 16_000
        let sampleCount = Constants.CHUNK_BYTES / MemoryLayout<Int16>.size  // 2048
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let value = amplitude * sin(2 * .pi * frequency * Float(i) / sampleRate)
            samples[i] = Int16(value * Float(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
