import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 88, 89, 90, 91, 92, 93, 94
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_88_94: XCTestCase {

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
    // Bug 88 — Injection permanently destroys non-string clipboard content
    //
    // inject() saves only pasteboard.string(forType: .string) and restores
    // only plain text. clearContents() removes ALL types (RTF, images, files).
    // Copying a file in Finder then dictating permanently loses the file path.
    //
    // EXPECTED: The clipboard save/restore logic preserves ALL pasteboard types
    //           by saving and restoring pasteboard.pasteboardItems (the full item
    //           array), not just the plain-text string.
    // ACTUAL:   Only pasteboard.string(forType: .string) is saved; all other
    //           types are silently discarded after inject() returns.
    // =======================================================================

    func testBug88_clipboardSaveMustPreserveAllPasteboardTypes() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }

        // The fix requires saving/restoring the full pasteboardItems array.
        let savesByItems  = content.contains("pasteboardItems")
        // The bug pattern: only string(forType: .string) is saved, nothing else.
        let savesOnlyString = content.contains("pasteboard.string(forType: .string)")
            && !content.contains("pasteboardItems")

        XCTAssertTrue(savesByItems,
            "Bug 88 CONFIRMED: TextInjector.inject() saves only pasteboard.string(forType: .string) " +
            "and restores only plain text. clearContents() wipes ALL types including RTF, images, " +
            "and file URLs — non-string clipboard content is permanently destroyed on every injection. " +
            "Fix: replace the savedClipboard string variable with a saved copy of " +
            "pasteboard.pasteboardItems and write those items back via " +
            "pasteboard.writeObjects(_:) or pasteboard.clearContents()+writeItems(_:) at restore time.")

        // Extra guard: verify the old single-type pattern is gone.
        XCTAssertFalse(savesOnlyString,
            "Bug 88 CONFIRMED: pasteboard.string(forType: .string) is still the only save — " +
            "pasteboardItems-based save is absent. Fix: save the full item array.")
    }

    // =======================================================================
    // Bug 89 — Key-up CGEvent silently dropped → V key stuck system-wide
    //
    // postPasteEvent() creates the key-up CGEvent inside `if let up = ...`.
    // If CGEvent creation fails and returns nil the key-up is never sent.
    // The V key remains "held" in the HID stream until physically pressed again.
    //
    // EXPECTED: The key-up creation result is checked; if nil is returned the
    //           code must either retry, log a recoverable error, or guard/throw
    //           rather than silently skipping the key-up send.
    // ACTUAL:   `if let up = CGEvent(...)` swallows nil silently — no guard,
    //           no error, no retry.
    // =======================================================================

    func testBug89_keyUpCGEventNilMustNotBeSilentlyDropped() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }

        // Extract only the postPasteEvent() function body to avoid false matches
        // from comments or other functions.
        guard let funcStart = content.range(of: "private static func postPasteEvent()") else {
            XCTFail("Bug 89: Cannot find postPasteEvent() in TextInjector.swift"); return
        }
        // Take a ~300 char window covering the whole (short) function body.
        let bodyStart = funcStart.lowerBound
        let bodyEnd = content.index(bodyStart, offsetBy: 300, limitedBy: content.endIndex) ?? content.endIndex
        let funcBody = String(content[bodyStart..<bodyEnd])

        // The fix: the key-up CGEvent creation must NOT be wrapped in a silent `if let`.
        // Acceptable patterns in the function body:
        //   `guard let up = CGEvent(... keyDown: false)` — fails loudly
        //   explicit `else { logger.error ... }` after the if-let
        //   or any throw/assertionFailure for the nil case
        let hasBugPattern = funcBody.contains("if let up")
            || funcBody.contains("if let keyUp")

        let hasGuardPattern = funcBody.contains("guard let up")
            || funcBody.contains("guard let keyUp")

        // The bug is present when only the silent `if let` form is used (no guard).
        XCTAssertFalse(hasBugPattern && !hasGuardPattern,
            "Bug 89 CONFIRMED: postPasteEvent() creates the key-up CGEvent inside `if let up = ...`. " +
            "When CGEvent creation returns nil the key-up is silently dropped, leaving the V key " +
            "held in the HID stream system-wide until the user physically presses it. " +
            "Fix: replace `if let up = CGEvent(... keyDown: false)` with " +
            "`guard let up = CGEvent(... keyDown: false) else { logger.error(...); return }` " +
            "so that a nil key-up is never silently discarded.")
    }

    // =======================================================================
    // Bug 90 — Transcription text leaked in cleartext clipboard in password fields
    //
    // inject() places the full transcription on NSPasteboard.general for 300 ms
    // in plaintext with no check for SecureInputEnabled or AXRole. Any process
    // monitoring the clipboard can read the password during the paste window.
    //
    // EXPECTED: Before writing text to the pasteboard, inject() checks whether
    //           the target field has secure input active — via SecInputIsEnabled()
    //           or by reading the focused element's AXRole for password markers —
    //           and refuses to proceed (or uses an alternative injection path)
    //           when a password field is detected.
    // ACTUAL:   No such check exists; the pasteboard is always used regardless of
    //           whether the destination field is a password input.
    // =======================================================================

    func testBug90_injectMustCheckSecureInputBeforePasteboard() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }

        // Acceptable fix signals: SecInputIsEnabled, AXSecureTextField,
        // kAXPasswordTextAttribute, or an AXRole check for password fields.
        let checksSecureInput =
            content.contains("SecInputIsEnabled")
            || content.contains("AXSecureTextField")
            || content.contains("kAXPasswordText")
            || content.contains("AXRole") && content.contains("password")
            || content.contains("isSecure")

        XCTAssertTrue(checksSecureInput,
            "Bug 90 CONFIRMED: TextInjector.inject() places the full transcription on " +
            "NSPasteboard.general for 300 ms without checking whether the target field is a " +
            "password input. Any clipboard-monitoring process can read the plaintext credential. " +
            "Fix: call SecInputIsEnabled() (or read the focused element's AXRole for " +
            "kAXPasswordTextAttribute / AXSecureTextField) before using the pasteboard path, " +
            "and refuse injection or switch to a secure alternative when a password field is detected.")
    }

    // =======================================================================
    // Bug 91 — Concurrent download() calls both pass isDownloading guard
    //
    // download() reads `isDownloading` at the top (guard !isDownloading),
    // then sets it to true 13 lines later inside `await MainActor.run { ... }`.
    // A second concurrent call races through the guard before the write lands.
    //
    // EXPECTED: isDownloading is set to true synchronously at the very top of
    //           download(), before any `await`, so no second caller can pass the
    //           guard in the same actor turn.
    // ACTUAL:   The write is deferred to `await MainActor.run { isDownloading = true }`,
    //           creating an async window where concurrent callers see false.
    // =======================================================================

    func testBug91_isDownloadingMustBeSetBeforeFirstAwait() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }

        // Find the download() function body and verify that `isDownloading = true`
        // appears before the first `await` inside it.
        guard let funcRange = content.range(of: "func download()") else {
            XCTFail("Bug 91: Cannot find download() in ModelDownloader.swift"); return
        }

        let bodyFromFunc = String(content[funcRange.lowerBound...])

        // Locate first `await` and first `isDownloading = true`
        let firstAwaitOffset    = bodyFromFunc.range(of: "await")?.lowerBound
        let firstSetTrueOffset  = bodyFromFunc.range(of: "isDownloading = true")?.lowerBound

        guard let setOffset = firstSetTrueOffset else {
            XCTFail(
                "Bug 91 CONFIRMED: `isDownloading = true` not found in download() at all. " +
                "Fix: add `isDownloading = true` as the first statement inside download(), " +
                "before any `await` expression.")
            return
        }

        guard let awaitOffset = firstAwaitOffset else {
            // No await at all — the set is trivially before any await, which is fine.
            return
        }

        XCTAssertLessThan(setOffset, awaitOffset,
            "Bug 91 CONFIRMED: In ModelDownloader.download(), `isDownloading = true` is written " +
            "AFTER the first `await` (inside `await MainActor.run { ... }`). " +
            "Concurrent callers both pass the `guard !isDownloading` check before the write lands, " +
            "causing duplicate download sessions that invalidate each other. " +
            "Fix: move `isDownloading = true` to be the very first statement in download(), " +
            "synchronously — before any `await` or async context switch.")
    }

    // =======================================================================
    // Bug 92 — Onboarding mic denial deadlocks — user permanently stuck
    //
    // microphoneStep calls AVCaptureDevice.requestAccess and advances step only
    // when granted == true. After a denial macOS never re-prompts; every
    // subsequent tap returns false immediately. There is no error message, no
    // "Open Settings" link, and no Skip button. Onboarding cannot complete.
    //
    // EXPECTED: The mic permission handler has an explicit `else` / `guard else`
    //           path for granted == false that either shows an error message,
    //           offers to open System Settings (Privacy & Security → Microphone),
    //           or provides a Skip option so onboarding can proceed.
    // ACTUAL:   The `if granted { step = .accessibility }` block has no else
    //           branch; denial produces no UI feedback and no forward path.
    // =======================================================================

    func testBug92_micDenialMustProvideForwardPath() {
        guard let content = readSource("OpenVerb/UI/OnboardingView.swift") else {
            XCTFail("Cannot read OnboardingView.swift"); return
        }

        // Scope the check to the AVCaptureDevice.requestAccess closure, which is
        // the only place where `granted` is available. Extract ~400 chars around
        // the requestAccess call to avoid false matches from unrelated else branches
        // (e.g. the modelDownloadStep's `} else if let err` blocks).
        guard let accessRange = content.range(of: "AVCaptureDevice.requestAccess") else {
            XCTFail("Bug 92: Cannot find AVCaptureDevice.requestAccess in OnboardingView.swift"); return
        }
        let windowStart = accessRange.lowerBound
        let windowEnd = content.index(windowStart, offsetBy: 400, limitedBy: content.endIndex) ?? content.endIndex
        let handlerWindow = String(content[windowStart..<windowEnd])

        // The fix must handle granted == false inside the requestAccess callback.
        // Acceptable patterns: `else {`, `!granted`, `granted == false`, `else if !granted`.
        let hasElseInHandler = handlerWindow.contains("} else {")
            || handlerWindow.contains("} else\n")
            || handlerWindow.contains("else {")
        let handlesDenialInHandler =
            handlerWindow.contains("!granted")
            || handlerWindow.contains("granted == false")
            || handlerWindow.contains("false {")

        let hasDenialPath = hasElseInHandler || handlesDenialInHandler

        XCTAssertTrue(hasDenialPath,
            "Bug 92 CONFIRMED: OnboardingView.microphoneStep advances step only when granted == true. " +
            "After a denial macOS never re-prompts; tapping the button again returns false immediately. " +
            "There is no error message, no Settings link, and no Skip — onboarding is permanently stuck. " +
            "Fix: add an else branch inside the AVCaptureDevice.requestAccess handler for " +
            "granted == false that either shows an error with an 'Open System Settings' button " +
            "or exposes a Skip action so the user can proceed past the mic step.")
    }

    // =======================================================================
    // Bug 93 — polishedResult without result → app stuck in .inferring 3 min
    //
    // drainResult()'s while-loop treats only `.result` and `.error` as terminal.
    // `.polishedResult` is non-terminal, so if the engine sends polishedResult
    // but never sends result (e.g. engine returns early or crashes after polish),
    // the loop blocks on receiveMessage(timeoutMs: 180_000) for 3 full minutes.
    // Escape is disabled during .inferring and no new session can start.
    //
    // EXPECTED: Either (a) the polishedResult case breaks out of the drain loop
    //           (treating it as a terminal result when no further result arrives),
    //           or (b) the timeout used is significantly shorter than 180 s with
    //           explicit handling for the "result never arrived" scenario.
    // ACTUAL:   polishedResult is handled then the loop continues to block on
    //           the next receiveMessage() with the full 3-minute timeout.
    // =======================================================================

    func testBug93_polishedResultWithoutResultMustNotBlockFor180Seconds() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }

        // --- Check 1: drainResult() must NOT use a 180-second timeout exclusively ---
        // The bug: the only receiveMessage call inside drainResult uses 180_000 ms.
        // The fix: either the timeout is reduced, or polishedResult breaks the loop.
        //
        // Approach: verify that the literal "180_000" does NOT appear as the sole
        // timeout inside a drainResult function.  We look for the drainResult block
        // and assert that it contains a timeout value other than 180_000 OR that
        // the polishedResult case has an explicit terminal exit.

        // Find the drainResult function — we know it contains a 180_000 timeout.
        // The bug is confirmed if BOTH of these are true simultaneously:
        //   (a) the only receiveMessage timeout in drainResult is 180_000, AND
        //   (b) the polishedResult case has no return/break of its own.

        // (a) Does drainResult use only the 180-second (180_000 ms) timeout?
        //     The fix would add a shorter secondary timeout after polishedResult.
        let drainHasOnlyMaxTimeout: Bool = {
            guard let drainSig = content.range(of: "private func drainResult(generation:") else { return false }
            let from = drainSig.lowerBound
            let maxOffset = min(4500, content.distance(from: from, to: content.endIndex))
            let to = content.index(from, offsetBy: maxOffset)
            let body = String(content[from..<to])
            // The bug: only 180_000 ms timeout present.
            let has180k = body.contains("timeoutMs: 180_000")
            // The fix: a shorter explicit timeout also present (10_000, 30_000, 60_000, etc.)
            // We check for timeoutMs: followed by a number that is NOT 180_000.
            // Split on "timeoutMs:" and examine what follows each occurrence.
            let parts = body.components(separatedBy: "timeoutMs:")
            // parts[0] is before first occurrence; parts[1..] each start with the value.
            var hasShorterExplicit = false
            for part in parts.dropFirst() {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                // Extract leading digits and underscores then parse as Int removing underscores.
                let raw = trimmed.prefix(while: { $0.isNumber || $0 == "_" })
                let numStr = String(raw).replacingOccurrences(of: "_", with: "")
                if let num = Int(numStr), num > 0, num < 180_000 {
                    hasShorterExplicit = true
                    break
                }
            }
            return has180k && !hasShorterExplicit
        }()

        // (b) polishedResult case is non-terminal: no return/break in its own body.
        // We scope to just the polishedResult case by stopping at the next `case .`
        // keyword that follows it, so we do not bleed into case .result's body.
        let polishedResultIsNonTerminal: Bool = {
            guard let caseLabel = content.range(of: "case .polishedResult(") else { return true }
            let afterLabel = caseLabel.upperBound
            let remainder = String(content[afterLabel...])
            // Find the next `case .` in the remainder — that is the start of case .result.
            // Use a leading newline to avoid matching within an expression.
            let nextCasePattern = "case ."
            // Search for either "case .result" or "case .warning" — whichever comes first.
            let nextCaseOffset: String.Index
            if let nextMatch = remainder.range(of: "\n            case .") {
                // Stop right at the newline before the next case — excludes case .result body.
                nextCaseOffset = content.index(afterLabel, offsetBy: remainder.distance(from: remainder.startIndex, to: nextMatch.lowerBound))
            } else if let nextMatch = remainder.range(of: nextCasePattern) {
                nextCaseOffset = content.index(afterLabel, offsetBy: remainder.distance(from: remainder.startIndex, to: nextMatch.lowerBound))
            } else {
                // No next case found — take a tight 160-char window (body is 2 lines ~130 chars).
                nextCaseOffset = content.index(afterLabel, offsetBy: min(160, content.distance(from: afterLabel, to: content.endIndex)))
            }
            let caseBody = String(content[afterLabel..<nextCaseOffset])
            return !caseBody.contains("return") && !caseBody.contains("break")
        }()

        // The bug is confirmed when BOTH conditions hold simultaneously.
        let bugIsPresent = drainHasOnlyMaxTimeout && polishedResultIsNonTerminal
        XCTAssertFalse(bugIsPresent,
            "Bug 93 CONFIRMED: drainResult() uses a single receiveMessage(timeoutMs: 180_000) call " +
            "and the .polishedResult case has no return/break. If the engine sends polishedResult " +
            "but never sends a result message, the loop blocks for 3 full minutes. Escape is " +
            "disabled during .inferring; the user cannot start a new session. " +
            "Fix: either (a) add `return` after handling .polishedResult to treat it as terminal, " +
            "or (b) use a shorter secondary timeout (e.g. timeoutMs: 10_000) after polishedResult " +
            "arrives so the stuck state resolves in seconds rather than 3 minutes.")
    }

    // =======================================================================
    // Bug 94 (source) — keyCodeAndFlags shift detection broken for punctuation
    //
    // keyCodeAndFlags(for:) computes `needsShift = char != char.lowercased()`.
    // Shifted punctuation characters like !@#$%^&*()_+{}|:"<>? have no
    // lowercase form — char.lowercased() returns the same character — so
    // needsShift is always false and the Shift flag is never set. The wrong
    // unshifted key is injected (e.g. ! → 1, @ → 2).
    //
    // EXPECTED: Shift detection uses a lookup table or CharacterSet containing
    //           known shifted punctuation, not `char != char.lowercased()`.
    // ACTUAL:   `char != char.lowercased()` is the only shift-detection mechanism.
    // =======================================================================

    func testBug94_shiftDetectionMustNotRelyOnlyOnLowercasedComparison() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }

        // The bug: sole shift detection is `char != char.lowercased()`
        let hasOldHeuristic = content.contains("char != char.lowercased()")
            || content.contains("!= char.lowercased()")

        // The fix: a lookup table, CharacterSet, or explicit shifted-punctuation set.
        let hasLookupBasedShift =
            content.contains("shiftedPunctuation")
            || content.contains("shiftedChars")
            || content.contains("requiresShift")
            || content.contains("CharacterSet")
            || content.contains("needsShift") && content.contains("[")
            // Accept any map/set containing at least one shifted punctuation literal.
            || content.contains("\"!\"") && content.contains("shift")
            || content.contains("\"@\"") && content.contains("shift")

        // The fix must add a lookup; the old heuristic must be replaced.
        XCTAssertFalse(hasOldHeuristic,
            "Bug 94 CONFIRMED (source): keyCodeAndFlags(for:) uses `char != char.lowercased()` as " +
            "its sole shift-detection mechanism. Shifted punctuation characters (!@#$%^&*()_+ etc.) " +
            "have no lowercase form so lowercased() returns the same character — needsShift is always " +
            "false and Shift is never set. ! injects as 1, @ as 2, etc. " +
            "Fix: replace the lowercased() comparison with a lookup table or CharacterSet that " +
            "explicitly lists all characters that require the Shift key.")

        XCTAssertTrue(hasLookupBasedShift,
            "Bug 94 CONFIRMED (source): no lookup-table / CharacterSet based shift detection found " +
            "in TextInjector.swift. The lowercased() heuristic must be replaced with an explicit " +
            "set of shifted characters (e.g. a `shiftedPunctuation: Set<Character>` constant " +
            "or an extension on CharacterSet).")
    }

    // =======================================================================
    // Bug 94 (behavioral) — '!' does not map to a keycode that requires Shift
    //
    // keyCodeForCharacter("!") must return nil (since '!' has no direct key —
    // it is Shift+1). keyCodeAndFlags(for: "!") must return keyCode 0x12 (the
    // '1' key) with .maskShift set. Currently, because of the broken
    // lowercased() heuristic, it either returns (0x12, []) — no Shift — or
    // returns nil if '!' is absent from charToKeyCode.
    //
    // EXPECTED: keyCodeAndFlags(for: "!") returns (0x12, .maskShift) so that
    //           the '!' character is injected as Shift+1.
    // ACTUAL:   Shift is not set; '!' injects as plain '1'.
    // =======================================================================

    func testBug94_exclamationMarkRequiresShiftFlag() {
        // keyCodeAndFlags(for:) must return (.maskShift set, keyCode for '1') for '!'
        guard let (keyCode, flags) = TextInjector.keyCodeAndFlags(for: "!") else {
            XCTFail(
                "Bug 94 CONFIRMED (behavioral): TextInjector.keyCodeAndFlags(for: \"!\") returned nil. " +
                "The '!' character has no entry in charToKeyCode and no shifted-punctuation fallback. " +
                "Fix: add '!' → (0x12, needsShift: true) to the lookup table so that Shift+1 is " +
                "posted when injecting an exclamation mark.")
            return
        }

        // '1' key is ANSI keyCode 0x12
        XCTAssertEqual(keyCode, 0x12,
            "Bug 94 CONFIRMED (behavioral): keyCodeAndFlags(for: \"!\") returned keyCode \(keyCode) " +
            "but expected 0x12 (the '1' key — '!' is Shift+1 on ANSI layout). " +
            "Fix: ensure the lookup table maps '!' to the '1' key code (0x12).")

        XCTAssertTrue(flags.contains(.maskShift),
            "Bug 94 CONFIRMED (behavioral): keyCodeAndFlags(for: \"!\") returned flags \(flags) " +
            "without .maskShift. The '!' character requires Shift to be held (Shift+1 on ANSI). " +
            "The broken `char != char.lowercased()` heuristic returns false for '!' because " +
            "lowercased() returns '!' unchanged — needsShift is never set for shifted punctuation. " +
            "Fix: use a lookup table or CharacterSet that explicitly marks '!' (and all other " +
            "shifted-punctuation characters) as requiring the Shift modifier.")
    }
}
