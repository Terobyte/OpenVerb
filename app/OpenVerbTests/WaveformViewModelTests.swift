import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// SineGen — lightweight test helper that manufactures Int16 PCM sine-wave
// Data payloads without pulling in any production audio infrastructure.
// ---------------------------------------------------------------------------

enum SineGen {
    /// Returns `samples` frames of Int16 PCM encoding a sine at `freq` Hz,
    /// amplitude 0.8, at `sampleRate` Hz.
    static func pcm(freq: Float, sampleRate: Float, samples: Int) -> Data {
        var buf = [Int16](repeating: 0, count: samples)
        for i in 0..<samples {
            let v: Float = 0.8 * sin(2 * .pi * freq * Float(i) / sampleRate)
            buf[i] = Int16(v * Float(Int16.max))
        }
        return buf.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// ---------------------------------------------------------------------------
// WaveformViewModelTests — unit tests for WaveformViewModel.
//
// testInitialStateIsZeroBins  : bins start as 24 zeros
// testResetClearsBins         : 2 kHz chunk → sum > 0.1, reset() → sum ≈ 0
// testAttackSmoothing         : two consecutive 2 kHz frames, second max > first max
// testUpdateFromChunkSilenceKeepsBinsAtZero : silence keeps all bins near zero
// testUpdateFromChunkSineRaisesPeakBin      : 1 kHz sine raises the peak bin above 0.1
//
// WaveformViewModel is @MainActor; tests run on the main actor via the
// @MainActor class annotation and setUp async throws pattern.
// ---------------------------------------------------------------------------

@MainActor
final class WaveformViewModelTests: XCTestCase {

    private var vm: WaveformViewModel!

    // Convenience: number of Int16 samples per chunk that FFTProcessor accepts.
    private var chunkSamples: Int { Constants.CHUNK_BYTES / MemoryLayout<Int16>.size }
    private let sampleRate: Float = 16_000

    override func setUp() async throws {
        try await super.setUp()
        vm = WaveformViewModel()
    }

    override func tearDown() async throws {
        vm = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    /// Verifies the view-model starts with exactly 24 zero bins.
    func testInitialStateIsZeroBins() {
        XCTAssertEqual(vm.bins.count, 24,
                       "WaveformViewModel must start with exactly 24 bins")
        XCTAssertTrue(vm.bins.allSatisfy { $0 == 0 },
                      "All bins must be zero before any audio is received")
    }

    // MARK: - reset

    /// Feeds a 2 kHz sine chunk (sum must exceed 0.1), then calls reset() and
    /// verifies the total energy drops back to zero.
    func testResetClearsBins() {
        let data = SineGen.pcm(freq: 2_000, sampleRate: sampleRate, samples: chunkSamples)
        vm.updateFromChunk(data)

        let sumBefore = vm.bins.reduce(0, +)
        XCTAssertGreaterThan(sumBefore, 0.1,
                             "2 kHz sine must raise total bin energy above 0.1 before reset")

        vm.reset()

        let sumAfter = vm.bins.reduce(0, +)
        XCTAssertEqual(sumAfter, 0,
                       "reset() must zero all bins (sum ≈ 0)")
    }

    // MARK: - Attack smoothing

    /// Sends the same 2 kHz frame twice and asserts that the EMA attack step
    /// causes the second frame's peak to exceed the first — confirming that
    /// smoothed values converge upward rather than snapping to the instantaneous
    /// FFT output.
    func testAttackSmoothing() {
        let data = SineGen.pcm(freq: 2_000, sampleRate: sampleRate, samples: chunkSamples)

        vm.updateFromChunk(data)
        let firstMax = vm.bins.max() ?? 0

        vm.updateFromChunk(data)
        let secondMax = vm.bins.max() ?? 0

        XCTAssertGreaterThan(secondMax, firstMax,
                             "EMA attack smoothing must make second frame's peak exceed first")
    }

    // MARK: - Additional coverage

    func testUpdateFromChunkSilenceKeepsBinsAtZero() {
        let silence = Data(count: Constants.CHUNK_BYTES)
        vm.updateFromChunk(silence)
        XCTAssertTrue(vm.bins.allSatisfy { $0 < 0.01 },
                      "Silence chunk must keep all bins near zero")
    }

    func testUpdateFromChunkSineRaisesPeakBin() {
        let data = SineGen.pcm(freq: 1_000, sampleRate: sampleRate, samples: chunkSamples)
        vm.updateFromChunk(data)
        let maxBin = vm.bins.max() ?? 0
        XCTAssertGreaterThan(maxBin, 0.1,
                             "1 kHz sine must raise the peak bin above 0.1 after one frame")
    }
}
