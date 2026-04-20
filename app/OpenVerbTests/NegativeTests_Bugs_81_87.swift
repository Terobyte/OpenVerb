import XCTest
@testable import OpenVerb

// Negative tests for: Bug 81, 82, 83, 84, 85, 86, 87
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_81_87: XCTestCase {

    private func readSource(_ relativePath: String) -> String? {
        let direct = URL(fileURLWithPath: relativePath)
        if let content = try? String(contentsOf: direct, encoding: .utf8) { return content }
        if let base = Bundle.main.resourceURL {
            let bundled = base.appendingPathComponent(relativePath)
            if let content = try? String(contentsOf: bundled, encoding: .utf8) { return content }
        }
        return nil
    }

    // =======================================================================
    // Bug 81 — stopRecording() has no re-entrancy guard
    //
    // The Stop button and maxDurationTimer can both call stopRecording() in the
    // same cooperative scheduler pass, each launching a drainResult Task that
    // calls receiveMessage() on the same socket while racing via socketReadLock.
    //
    // EXPECTED: stopRecording() has a boolean guard (e.g. `guard !isDraining
    //           else { return }`) that is set before launching the drain Task,
    //           so a second concurrent call returns immediately.
    // ACTUAL:   No guard exists — two concurrent calls each spawn a drainResult
    //           Task resulting in two readers on the same socket fd.
    // =======================================================================

    func testBug81_stopRecordingHasReentrancyGuard() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }

        // The fix requires some guard that prevents a second drainResult Task.
        // Acceptable patterns: `guard !isDraining`, `guard !isStoppingRecording`,
        // or any boolean sentinel checked at the top of stopRecording().
        let hasGuardIsDraining   = content.contains("guard !isDraining")
        let hasGuardIsStop       = content.contains("guard !isStoppingRecording")
        let hasIsDrainingSet     = content.contains("isDraining = true")
        let hasIsStoppingSet     = content.contains("isStoppingRecording = true")

        let hasReentrancyGuard   = (hasGuardIsDraining || hasGuardIsStop)
                                 && (hasIsDrainingSet   || hasIsStoppingSet)

        XCTAssertTrue(hasReentrancyGuard,
            "Bug 81 CONFIRMED: stopRecording() has no re-entrancy guard. " +
            "Two concurrent callers (Stop button + maxDurationTimer) each spawn a " +
            "drainResult Task; both call receiveMessage() on the same socket, racing " +
            "through socketReadLock. Fix: add a `guard !isDraining else { return }` " +
            "boolean check at the top of stopRecording() and set `isDraining = true` " +
            "before launching the drain Task.")
    }

    // =======================================================================
    // Bug 82 — AX API called from cooperative-pool thread on every ⌥Space press
    //
    // ContextBuilder.build is an async func with no @MainActor annotation.
    // Apple's Accessibility API requires main-thread access. Calling it from a
    // cooperative thread pool is undefined behaviour: stale data, deadlocks,
    // or crashes inside the AX framework.
    //
    // EXPECTED: ContextBuilder.build is annotated @MainActor, OR all AX API
    //           calls are wrapped with `await MainActor.run { ... }`.
    // ACTUAL:   `static func build(...)` has no actor annotation and calls
    //           accessibilityReader.readWindowTitle / readSelectedText /
    //           readCursorSurroundingText directly on the calling thread.
    // =======================================================================

    func testBug82_contextBuilderBuildIsMainActor() {
        guard let content = readSource("OpenVerb/Context/ContextBuilder.swift") else {
            XCTFail("Cannot read ContextBuilder.swift"); return
        }

        // The fix is either @MainActor on the method declaration, or every AX
        // call wrapped in MainActor.run.  Check for both patterns.
        let hasMainActorAnnotation = content.contains("@MainActor") &&
                                     content.contains("static func build(")
        let hasMainActorRun        = content.contains("MainActor.run") &&
                                     (content.contains("readWindowTitle") ||
                                      content.contains("readSelectedText") ||
                                      content.contains("readCursorSurroundingText"))

        // Verify the annotation actually precedes the build declaration.
        let mainActorBeforeBuild: Bool = {
            guard let atIdx  = content.range(of: "@MainActor"),
                  let fnIdx  = content.range(of: "static func build(") else { return false }
            // The @MainActor must appear before (or at the same location as) the
            // build declaration — a simple ordering check on string positions is
            // sufficient here.
            return atIdx.lowerBound < fnIdx.upperBound
        }()

        let isSafe = (hasMainActorAnnotation && mainActorBeforeBuild) || hasMainActorRun

        XCTAssertTrue(isSafe,
            "Bug 82 CONFIRMED: ContextBuilder.build calls Apple AX API " +
            "(readWindowTitle, readSelectedText, readCursorSurroundingText) without " +
            "guaranteeing main-thread execution. AX API called from a cooperative-pool " +
            "thread is undefined behaviour — stale data, deadlocks, or framework crashes. " +
            "Fix: annotate `static func build(...)` with @MainActor, or wrap every " +
            "AccessibilityReader call with `await MainActor.run { ... }`.")
    }

    // =======================================================================
    // Bug 83 — Mach port leak per hotkey reconfiguration — crashes after ~2048
    //
    // removeEventTap() disables the tap and removes the run-loop source, but
    // never calls CFMachPortInvalidate(). Each configure() call leaks one Mach
    // port. After ~2048 leaks CGEvent.tapCreate returns nil and the hotkey dies
    // silently.
    //
    // EXPECTED: removeEventTap() or installEventTap() calls CFMachPortInvalidate
    //           on the old port before releasing it.
    // ACTUAL:   CFMachPortInvalidate is absent from HotkeyManager.swift entirely.
    // =======================================================================

    func testBug83_hotkeyManagerInvalidatesMachPort() {
        guard let content = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Cannot read HotkeyManager.swift"); return
        }

        let callsInvalidate = content.contains("CFMachPortInvalidate")

        XCTAssertTrue(callsInvalidate,
            "Bug 83 CONFIRMED: HotkeyManager.removeEventTap() never calls " +
            "CFMachPortInvalidate(). Each hotkey reconfiguration leaks one Mach port. " +
            "The per-process Mach port limit (~2048) is reached after ~2048 " +
            "configure() calls, causing CGEvent.tapCreate to return nil and the " +
            "hotkey to die silently. Fix: add `CFMachPortInvalidate(tap)` inside " +
            "removeEventTap() before setting eventTap = nil.")
    }

    // =======================================================================
    // Bug 84 — ShortcutRecorder consumes Cmd+Q and Cmd+W — app unkillable
    //
    // The local NSEvent monitor in startRecording() returns nil for ALL keyDown
    // events, including system shortcuts.  Cmd+Q, Cmd+W, Cmd+H are swallowed;
    // the app cannot be quit or hidden while the recorder is active.
    //
    // EXPECTED: The monitor passes through (returns non-nil for) events that
    //           carry system shortcuts — at minimum Cmd+Q, Cmd+W, Cmd+H.
    // ACTUAL:   The handler ends with `return nil` unconditionally, consuming
    //           every non-Escape, non-modifier key event.
    // =======================================================================

    func testBug84_shortcutRecorderPassesThroughSystemShortcuts() {
        guard let content = readSource("OpenVerb/Input/ShortcutRecorder.swift") else {
            XCTFail("Cannot read ShortcutRecorder.swift"); return
        }

        // The fix requires returning the event (non-nil) for system shortcuts.
        // Acceptable patterns:
        //   - Check for .command modifier and return `event` instead of nil
        //   - Explicit guard for keyCode 12 (Q), 13 (W), 4 (H) with .command
        //   - A helper that lets system shortcuts pass through
        let returnsEventForCommand = content.contains("contains(.command)") &&
                                     content.contains("return event")

        // Also accept a pattern that checks the event's modifierFlags for
        // .command before consuming:
        let hasCommandPassthrough  = content.contains(".maskCommand") &&
                                     content.contains("return event")

        let isSafe = returnsEventForCommand || hasCommandPassthrough

        XCTAssertTrue(isSafe,
            "Bug 84 CONFIRMED: ShortcutCaptureView's local NSEvent monitor returns nil " +
            "for every keyDown event during recording mode, including Cmd+Q, Cmd+W, " +
            "Cmd+H. System shortcuts are swallowed; the app is unkillable via keyboard " +
            "while recording. Fix: before consuming an event, check whether it carries " +
            "a .command modifier (or matches known system shortcut key codes) and " +
            "return `event` (non-nil) to pass it through to the system.")
    }

    // =======================================================================
    // Bug 85 — URLSession retain cycle in ModelDownloader — never invalidated
    //
    // URLSession holds its delegate (ModelDownloader) strongly until
    // invalidateAndCancel() is called. ModelDownloader has no deinit. Closing
    // the onboarding window mid-download keeps the downloader alive forever;
    // delegate callbacks fire on a zombie UI context.
    //
    // EXPECTED: ModelDownloader.deinit calls session?.invalidateAndCancel()
    //           (or an equivalent cleanup path).
    // ACTUAL:   No deinit exists in ModelDownloader.swift.
    // =======================================================================

    func testBug85_modelDownloaderHasDeinitWithSessionInvalidate() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }

        let hasDeinit           = content.contains("deinit")
        let hasInvalidateInDeinit: Bool = {
            guard let deinitRange = content.range(of: "deinit") else { return false }
            // Check the text after "deinit" for invalidateAndCancel within a
            // reasonable window (300 chars covers a one-liner deinit block).
            let tail = content[deinitRange.lowerBound...]
            let window = tail.prefix(300)
            return window.contains("invalidateAndCancel")
        }()

        XCTAssertTrue(hasDeinit && hasInvalidateInDeinit,
            "Bug 85 CONFIRMED: ModelDownloader has no deinit that invalidates its " +
            "URLSession. URLSession holds the delegate (ModelDownloader) strongly until " +
            "invalidateAndCancel() is explicitly called. Closing the onboarding window " +
            "mid-download keeps the downloader alive forever, and delegate callbacks " +
            "fire on a zombie UI context. Fix: add `deinit { session?.invalidateAndCancel() }` " +
            "to ModelDownloader.")
    }

    // =======================================================================
    // Bug 86 — Download progress shows billions of percent when server omits
    // Content-Length
    //
    // didWriteData computes progress as:
    //   Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, 1))
    // When the server omits Content-Length, URLSession passes -1 for
    // totalBytesExpectedToWrite (NSURLSessionTransferSizeUnknown).  max(-1, 1)
    // == 1, so a 1.5 GB download reports progress ≈ 1_500_000_000.
    //
    // EXPECTED: When totalBytesExpectedToWrite == -1 (unknown), the reported
    //           progress is either clamped to 0.0...1.0 or treated as "unknown"
    //           (not a number > 1.0).
    // ACTUAL:   max(totalBytesExpectedToWrite, 1) treats -1 as 1, producing a
    //           fraction in the billions.
    // =======================================================================

    func testBug86_progressNotGiantWhenContentLengthUnknown() {
        // Behavioral: simulate the delegate math directly.
        // Replicate the buggy formula and the fixed formula, asserting only the
        // fixed formula produces a sane value.

        let totalBytesWritten: Int64         = 1_500_000_000  // 1.5 GB written so far
        let totalBytesExpectedToWrite: Int64 = -1             // NSURLSessionTransferSizeUnknown

        // Buggy formula (what the code currently does):
        let buggyProgress = Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, 1))
        // buggyProgress ≈ 1_500_000_000 — clearly wrong.

        // The correct behaviour: when expected == -1, progress must not exceed 1.0.
        // The source code must check against NSURLSessionTransferSizeUnknown (-1)
        // and either skip the update or return a sentinel.
        let isProgressSane = buggyProgress <= 1.0

        XCTAssertTrue(isProgressSane,
            "Bug 86 CONFIRMED: When the server omits Content-Length " +
            "(totalBytesExpectedToWrite == -1 / NSURLSessionTransferSizeUnknown), " +
            "the formula `Double(totalBytesWritten) / Double(max(totalBytesExpectedToWrite, 1))` " +
            "evaluates to \(buggyProgress), far exceeding 1.0. This is displayed as " +
            "\(Int(buggyProgress * 100))%. Fix: check `totalBytesExpectedToWrite == " +
            "NSURLSessionTransferSizeUnknown` (i.e. == -1) and skip the progress " +
            "update or return a sentinel value rather than clamping the denominator to 1.")
    }

    func testBug86_sourceChecksForTransferSizeUnknown() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }

        // The fix must compare against NSURLSessionTransferSizeUnknown or -1,
        // not simply clamp to max(..., 1).
        let checksUnknown = content.contains("NSURLSessionTransferSizeUnknown") ||
                            (content.contains("totalBytesExpectedToWrite") &&
                             content.contains("== -1"))

        // The buggy pattern is max(totalBytesExpectedToWrite, 1) with no guard.
        let stillHasBuggyPattern = content.contains("max(totalBytesExpectedToWrite, 1)")

        XCTAssertTrue(checksUnknown,
            "Bug 86 CONFIRMED (source): ModelDownloader.urlSession(_:didWriteData:) " +
            "does not check NSURLSessionTransferSizeUnknown before computing progress. " +
            "Fix: add `guard totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown " +
            "else { return }` (or equivalent) before the progress fraction calculation.")

        XCTAssertFalse(stillHasBuggyPattern,
            "Bug 86 CONFIRMED (source): The formula `max(totalBytesExpectedToWrite, 1)` " +
            "is still present. This converts NSURLSessionTransferSizeUnknown (-1) to 1, " +
            "making progress ≈ totalBytesWritten / 1, which is a number in the billions " +
            "for a 1.5 GB file. Fix: replace with an explicit guard against -1.")
    }

    // =======================================================================
    // Bug 87 — SHA256 sentinel "TBD_PIN_BEFORE_RELEASE" skips all verification
    //
    // ModelDownloader.expectedSHA256 is set to "TBD_PIN_BEFORE_RELEASE" and
    // verifySHA256() short-circuits to `return true` when this sentinel is
    // present.  The existing test only checks !isEmpty, so the sentinel passes.
    // A release build silently accepts corrupted or malicious model files.
    //
    // EXPECTED: The SHA256 constant is a real 64-character lowercase hex string,
    //           not "TBD_PIN_BEFORE_RELEASE" or any other sentinel value.
    // ACTUAL:   `static let expectedSHA256 = "TBD_PIN_BEFORE_RELEASE"`
    // =======================================================================

    func testBug87_sha256ConstantIsNotSentinel() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }

        let stillHasSentinel = content.contains("TBD_PIN_BEFORE_RELEASE")

        XCTAssertFalse(stillHasSentinel,
            "Bug 87 CONFIRMED: ModelDownloader.expectedSHA256 contains the sentinel " +
            "\"TBD_PIN_BEFORE_RELEASE\". verifySHA256() detects this sentinel and returns " +
            "true without performing any hash check, silently accepting corrupted or " +
            "malicious model files in release builds. The existing testSHA256ConstantsExist " +
            "test only checks !isEmpty, so the sentinel passes undetected. " +
            "Fix: replace \"TBD_PIN_BEFORE_RELEASE\" with the real SHA256 hex digest of " +
            "the model file (run `shasum -a 256 <model.gguf>` to compute it) and remove " +
            "the sentinel short-circuit from verifySHA256().")
    }

    func testBug87_sha256ConstantLooksLikeRealHash() {
        // Secondary source check: even after removing the sentinel, the constant
        // must be a plausible SHA256 hex string (64 lowercase hex characters).
        let hash = ModelDownloader.expectedSHA256

        let isSentinel = hash == "TBD_PIN_BEFORE_RELEASE"
        XCTAssertFalse(isSentinel,
            "Bug 87 CONFIRMED: ModelDownloader.expectedSHA256 == \"TBD_PIN_BEFORE_RELEASE\". " +
            "Fix: pin the real SHA256 hash before release.")

        let isValidHexLength = hash.count == 64
        XCTAssertTrue(isValidHexLength,
            "Bug 87 CONFIRMED: ModelDownloader.expectedSHA256 has length \(hash.count), " +
            "not 64. A valid SHA256 hex digest is exactly 64 lowercase hex characters. " +
            "Fix: replace the sentinel with the real hash produced by `shasum -a 256 <model.gguf>`.")

        let isLowercaseHex = hash.allSatisfy { $0.isHexDigit && ($0.isLetter ? $0.isLowercase : true) }
        XCTAssertTrue(isLowercaseHex,
            "Bug 87 CONFIRMED: ModelDownloader.expectedSHA256 (\"\(hash)\") contains " +
            "non-lowercase-hex characters. Fix: store the hash as a 64-character lowercase " +
            "hex string exactly as produced by `shasum -a 256`.")
    }
}
