# FFT Spectrum Waveform Implementation Plan (tero-enriched)

**Goal:** Replace the current 30-bar RMS amplitude waveform with a live 24-bar log-spaced FFT spectrum visualization tuned for speech, so the HUD visually "reads" the voice instead of just pulsing with volume.

**Architecture:**
- [x] New `FFTProcessor` class computes a windowed 2048-point real FFT on each 4096-byte PCM Int16 chunk using `Accelerate/vDSP`, maps 1024 magnitude bins into 24 log-spaced bands over 80 Hz – 7.5 kHz, and returns normalized `[0...1]` Floats.
- [x] `WaveformViewModel` keeps a running smoothed `bins: [CGFloat]` (24 elements) with per-bar asymmetric EMA (attack 0.55, release 0.18); the existing `AudioSession` callback feeds 4096-byte chunks into a new `updateFromChunk(_:)` entry point.
- [x] `WaveformView` renders the 24 bars symmetric-mirrored around the vertical center, with a moss-700 → moss-300 gradient keyed to each bar's frequency band and a gentle SwiftUI spring animation (response 0.25, damping 0.72).

**Tech Stack:** Swift 5.10+, SwiftUI, Accelerate.framework (vDSP), existing `AudioSession` tap (16 kHz Int16 mono PCM, 4096-byte chunks = 2048 samples = 128 ms).

## Review Notes Addressed

Incorporated from two-agent plan review (before tero conversion):
- [x] **BLOCKER — legacy tests:** `BugsMDTDDTests.testBug1_resetShouldClearAmplitudesSynchronously` and `OpenBugsNegativeTests.testBug1_updateAmplitudeDefersAppendToNextRunLoop` directly reference `vm.amplitudes` / `vm.updateAmplitude` / search source text for `func updateAmplitude`. Explicit steps (9, 10) now update both in the same chunk as the API migration so the build never breaks.
- [x] **CONCERN — `nonisolated(unsafe) processor`:** Unnecessary, opts out of Swift 6 checker. Changed to plain `private let processor = FFTProcessor()` inside the `@MainActor` class — isolation is enforced by the class, which is what we want.
- [x] **NIT — sine-test comment:** 1 kHz actually peaks in band 13 (not 15-18). Assertion `10 < maxIdx < 20` still holds; comment updated in step 4.
- [x] **FFT math corrected:** original pipeline `zvmags → /N → sqrt` introduced a sqrt(N)≈45× amplitude error (N=2048, off by ~45×). Correct order is `zvmags → vvsqrtf → /N` (sqrt first, then divide), which yields true amplitude A. The dB floor mapping `[-60, 0] → [0, 1]` is valid given the fixed scale.

## Files Touched

**Created:**
- [x] `app/OpenVerb/Input/FFTProcessor.swift`
- [x] `app/OpenVerbTests/FFTProcessorTests.swift`
- [x] `app/OpenVerbTests/WaveformViewModelTests.swift`

**Modified:**
- [x] `app/OpenVerb/UI/WaveformView.swift` (rewrite VM + rewrite bar rendering)
- [x] `app/OpenVerb/App/OpenVerbApp.swift` (2 call sites: lines 487 and 627)
- [x] `app/OpenVerbTests/BugsMDTDDTests.swift` (update `testBug1_resetShouldClearAmplitudesSynchronously`)
- [x] `app/OpenVerbTests/OpenBugsNegativeTests.swift` (update `testBug1_updateAmplitudeDefersAppendToNextRunLoop`)

**Untouched:**
- [x] `AudioSession.swift` — still emits 4096-byte chunks on main queue. No changes.
- [x] `RecordingWindow.swift` — still embeds `WaveformView(viewModel: waveformVM)`. No changes.

## Phases
- [x] Phase 1: "FFT Core" → steps 1-5
- [x] Phase 2: "ViewModel Migration" → steps 6-12
- [x] Phase 3: "Integration Checks" → steps 13-15  ← UI rendering moved into step 7
- [x] Phase 4: "Human Verification" → steps 16-20

## Steps
- [x] [tdd-guide] Create `app/OpenVerbTests/FFTProcessorTests.swift` with `testSilenceProducesZeroBins` — feeds `Data(count: 4096)` into a fresh `FFTProcessor`, asserts exactly 24 zero bins. Run and confirm it fails with "FFTProcessor type not found".
- [x] [architect] Create `app/OpenVerb/Input/FFTProcessor.swift`: final class, `import Accelerate`, constants `binCount=24 / fftSize=2048 / sampleRate=16_000`, stores `FFTSetup` + Hann window + log-band ranges in init, calls `vDSP_destroy_fftsetup` in deinit. `process(_ data: Data) -> [Float]` returns zeros for wrong-size input, otherwise: `vDSP_vflt16` → scale by `1/Int16.max` → multiply by Hann → split-complex pack with `vDSP_ctoz` stride 2 → `vDSP_fft_zrip` forward → `vDSP_zvmags` → `vvsqrtf` → `vDSP_vsdiv` by N → per-band mean via `vDSP_meanv` → `20*log10(max(mean, 1e-7))` → map `[-60, 0] dB` → `[0, 1]` clamped. `logBands` helper uses natural log over 80 Hz – 7.5 kHz, rounds to fftBin indices.
- [x] [tdd-guide] Run `cd app && swift test --filter FFTProcessorTests/testSilenceProducesZeroBins` — confirm PASS.
- [x] [tdd-guide] Add `testSineAt1kHzPeaksInMidBand` to FFTProcessorTests: synth a full-amplitude 1 kHz sine (2048 samples @ 16 kHz, amplitude 0.8×Int16.max), feed into processor, assert: `let peak = bins.firstIndex(of: bins.max()!)!; XCTAssertTrue(peak >= 12 && peak <= 14)` (peak lands at band ~13; tight ±1 window catches off-by-many errors the original 9-band window would miss), peak magnitude > 0.3, low band < 30 % of peak, high band < 50 % of peak. Run and confirm PASS.
- [x] [tdd-guide] Add `testWrongSizeReturnsZeros` — feeds `Data(count: 1024)` and `Data(count: 8192)`, confirms both return 24-element all-zero arrays (no crash, no partial FFT).
- [x] [tdd-guide] Create `app/OpenVerbTests/WaveformViewModelTests.swift`: `@MainActor` test class with `SineGen.pcm(freq, sampleRate, samples) -> Data` helper (Int16 sine, `withUnsafeBufferPointer { Data(buffer: $0) }`). Three tests: `testInitialStateIsZeroBins` (24 zero bins), `testResetClearsBins` (feeds 2 kHz → sum > 0.1, calls `reset()` → sum ≈ 0), `testAttackSmoothing` (two consecutive 2 kHz frames, asserts second max > first max).
- [x] [refactor+frontend-dev] Rewrite **entire** `app/OpenVerb/UI/WaveformView.swift` in one atomic pass — no line-range addressing, rewrite top-to-bottom. Splitting ViewModel and View into separate steps breaks the build between them because the old `WaveformView` struct references `viewModel.amplitudes`, which no longer exists after the ViewModel is updated. Write both sections together:

   **ViewModel** — `WaveformViewModel`: `@MainActor final class`, `@Published private(set) var bins: [CGFloat]` initialized to 24 zeros, `private var smoothed: [Float]` same, `private let attack: Float = 0.55` / `private let release: Float = 0.18`, `private let processor = FFTProcessor()` (no `nonisolated(unsafe)` — `@MainActor` isolation covers it). `updateFromChunk(_ data: Data)` runs `processor.process(data)` then asymmetric EMA per bar (`target > smoothed[i] ? attack : release`), assigns `bins = smoothed.map { CGFloat($0) }`. `reset()` zeroes `smoothed` and re-assigns 24-zero `bins`.

   **View** — `WaveformView` struct: `HStack(alignment: .center, spacing: 2)` of 24 `Capsule()` bars 9 pt wide with heights mapped `6 + clamped * 38` pt; `barGradient(for: i)` interpolates moss-700 (`#3C4F2B`, rgb 0.235/0.310/0.169) → moss-300 (`#9FB788`, rgb 0.623/0.714/0.533) by `t = i / 23`, top color full brightness, bottom = top × 0.7; frame height 44; `.animation(.spring(response: 0.25, dampingFraction: 0.72), value: viewModel.bins)`. Delete `paddedAmplitudes` helper and `.animation(.linear(duration: 0.05))`.
- [x] [refactor] Update `app/OpenVerb/App/OpenVerbApp.swift` lines 487 and 627: change `self?.waveformVM.updateAmplitude(chunk)` → `self?.waveformVM.updateFromChunk(chunk)`.
- [x] [refactor] Update `app/OpenVerbTests/BugsMDTDDTests.swift` `testBug1_resetShouldClearAmplitudesSynchronously` (lines 48-57): replace `vm.updateAmplitude(Data(...))` calls with `vm.updateFromChunk(Data(count: 4096))` (valid size now matters), replace `XCTAssertTrue(vm.amplitudes.isEmpty, ...)` with `XCTAssertEqual(vm.bins.reduce(0, +), 0, accuracy: 0.001, "reset() should clear bins synchronously")`. Preserve the Bug 1 invariant being tested.
- [x] [refactor] Update `app/OpenVerbTests/OpenBugsNegativeTests.swift` `testBug1_updateAmplitudeDefersAppendToNextRunLoop` (line 1243): rename to `testBug1_updateFromChunkIsMainActorSync`, change `content.range(of: "func updateAmplitude")` to `content.range(of: "func updateFromChunk")`, update XCTFail message. Invariant stays the same: the update method must be on MainActor and NOT wrap mutations in `DispatchQueue.main.async`.
- [x] [devops] Run `cd app && swift build 2>&1 | tail -30` — expect clean build, zero errors. Any warning about deprecated `vDSP_create_fftsetup` on macOS 14+ is acceptable and out of scope.
- [x] [tdd-guide] Run `cd app && swift test 2>&1 | tail -50` — expect all tests green: new FFTProcessorTests (3), new WaveformViewModelTests (3), plus pre-existing suites (OpenBugsNegativeTests, BugsMDTDDTests, RecordingHUDBugsTests, NegativeTests_Bugs_127_128, NegativeTests_Bugs_137_138).
- [x] [verify] Review `WaveformView.swift` written in step 7 — confirm both the ViewModel and View struct sections are present and correctly reference `viewModel.bins` (not `viewModel.amplitudes`). No coding required; the full rewrite was done atomically in step 7 to prevent a mid-plan build break.
- [x] [devops] Run `cd app && swift build 2>&1 | tail -20` — expect clean build.
- [x] [tdd-guide] Run `cd app && swift test 2>&1 | tail -30` — expect all suites still green; no regression from the visual-only change.
- [x] [general] HUMAN: **before running `ov`**, manually add `FFTProcessor.swift` to the Xcode app target — Xcode never auto-discovers files added outside its GUI. Open the project in Xcode, choose `File > Add Files to OpenVerb`, select `app/OpenVerb/Input/FFTProcessor.swift`, confirm target membership for "OpenVerb" (app target, not tests). Then run `ov` — expect **BUILD SUCCEEDED**. Do NOT edit `project.pbxproj` by hand — see CLAUDE.md.
- [x] [general] HUMAN: press ⌥Space, speak a short sentence for 3-5 seconds, release. Verify: (a) the 24-bar spectrum visibly differentiates — plosives wake the low-left bands, sibilants (`s`, `sh`, `f`) wake the high-right bands; (b) bars rise quickly and decay slowly (visual "breathing"), no stroby flicker; (c) on release the RECORDING → INFERRING crossfade still works (no waveform artifacts behind the loading bar).
- [x] [general] HUMAN: open Preferences, toggle `showWaveform` off, start a recording — confirm bars stay hidden and the HUD still records/infers normally. Re-enable `showWaveform` and confirm bars return.
- [x] [general] HUMAN: trigger a second recording immediately after the first — confirm bars reset to zero before the new session and do not flash stale bins from the previous recording (this verifies `reset()` is synchronous).
- [x] [general] HUMAN: `git log --oneline -6` — verify clean commit history (expected 2 commits from this plan: one for Phase 1+2, one for Phase 3; optionally a 3rd if the UI-rendering chunk landed as its own commit).
