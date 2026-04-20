import XCTest
import AppKit
@testable import OpenVerb

// ---------------------------------------------------------------------------
// NegativeTests_Bugs_109_115 — one test per bug from bugs.md.
//
// Every test asserts CORRECT behaviour and FAILS while the bug exists.
// GREEN = bug fixed.  GREEN before the fix = false negative (test is wrong).
//
// Bugs covered:
//   Bug 109 — Markdown ordered-list regex never matches (raw string escaping)
//   Bug 110 — onPartialResult ignores chunkId/isFinal — no dedup on retransmit
//   Bug 111 — handleSleep() sets .stopped before async disconnect() closes fd
//   Bug 112 — Stale resumeData never cleared when next download starts fresh
//   Bug 113 — drainResult processes one message after abortAndRestart() bumps generation
//   Bug 114 — waitForProcessExit busy-waits on cooperative thread via RunLoop
//   Bug 115 — Language picker shows no selection for unsupported system locales
// ---------------------------------------------------------------------------

final class NegativeTests_Bugs_109_115: XCTestCase {

    // Reads a source file by path relative to the package source root.
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
    // Bug 109 — Markdown ordered-list regex never matches
    //
    // ClipboardStyle.swift:37 uses the raw-string literal #"^\d+\\. "#.
    // In a raw string, backslash is literal, so the pattern passed to the
    // regex engine is  ^\d+\. — which matches "1\. " (a literal backslash +
    // dot), not "1. " (digit dot space).  Ordered-list clipboard content is
    // therefore never classified as Markdown.
    //
    // EXPECTED (behavioural): describe("1. First item\n2. Second item")
    //           returns a string containing "markdown:true".
    // EXPECTED (source):      the pattern does NOT use #"..\\..."# raw-string
    //                         escaping — it must use "\." in a normal string
    //                         or just "." in a raw string so the engine sees
    //                         the metacharacter dot.
    // ACTUAL:   The raw-string double-backslash makes the engine match a
    //           literal backslash; ordered lists are silently misclassified.
    // =======================================================================

    func testBug109_orderedListDetectedAsMarkdown_behavioural() {
        let input = "1. First item\n2. Second item\n3. Third item"
        let description = ClipboardStyle.describe(input)
        XCTAssertTrue(description.contains("markdown:true"),
            "Bug 109 CONFIRMED: ClipboardStyle.describe() returns \"\(description)\" for " +
            "ordered-list Markdown input, but expected \"markdown:true\". " +
            "Fix: change the raw-string pattern #\"^\\d+\\\\. \"# at ClipboardStyle.swift:37 " +
            "to a normal string \"^\\\\d+\\\\. \" or a raw string without the double backslash.")
    }

    func testBug109_orderedListRegexPatternDoesNotUseLiteralBackslash_sourceInspection() {
        guard let content = readSource("OpenVerb/Context/ClipboardStyle.swift") else {
            XCTFail("Cannot read ClipboardStyle.swift"); return
        }
        // The buggy pattern in source is:  #"^\d+\\. "#
        // That raw-string literal passes ^\d+\\. to the regex engine,
        // which matches a literal backslash before the dot — not "1. ".
        // We check for the broken double-backslash form inside a raw string.
        // In a normal (non-raw) Swift string, the source bytes #"^\d+\\. "#
        // are represented as: #\"^\\d+\\\\. \"#
        let brokenSourceLiteral = ##"#"^\d+\\. "#"##
        let hasBrokenPattern = content.contains(brokenSourceLiteral)
        XCTAssertFalse(hasBrokenPattern,
            "Bug 109 CONFIRMED: ClipboardStyle.swift contains the raw-string pattern " +
            "#\"^\\\\d+\\\\\\\\. \"# which passes a literal backslash to the regex engine " +
            "and never matches ordered-list lines like \"1. item\". " +
            "Fix: replace with a non-raw string \"^\\\\d+\\\\. \" so NSRegularExpression " +
            "receives the correct metacharacter dot.")
    }

    // =======================================================================
    // Bug 110 — onPartialResult ignores chunkId and isFinal — no dedup
    //
    // OpenVerbApp.swift:265–270 wires the onPartialResult callback but the
    // closure signature is `{ text, _, _ in … }`, discarding chunkId and
    // isFinal entirely.  If the engine retransmits a chunk (identical chunkId),
    // livePartialText accumulates the text twice.
    //
    // EXPECTED: the onPartialResult handler reads chunkId and uses it to
    //           deduplicate — a seen chunkId must be ignored.
    // ACTUAL:   both chunkId and isFinal are bound to `_` and never read.
    // =======================================================================

    func testBug110_onPartialResultUsesChunkIdForDedup_sourceInspection() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        // The buggy assignment looks like:
        //   engineManager.engineClient.onPartialResult = { [weak self] text, _, _ in
        // A correct implementation must not discard chunkId with `_`.
        // We verify that there is NO onPartialResult assignment that uses
        // `_, _` as the second and third parameters (discarding both chunkId
        // and isFinal), since that form guarantees no dedup is possible.
        let brokenPattern = "onPartialResult = { [weak self] text, _, _ in"
        let hasBrokenAssignment = content.contains(brokenPattern)
        XCTAssertFalse(hasBrokenAssignment,
            "Bug 110 CONFIRMED: OpenVerbApp.swift wires onPartialResult with " +
            "both chunkId and isFinal discarded (`_, _`). Engine retransmits are " +
            "appended to livePartialText undetected, producing doubled transcript text. " +
            "Fix: capture chunkId in the closure, maintain a `lastSeenChunkId` property, " +
            "and skip any chunk whose ID matches the previously processed one.")
    }

    // =======================================================================
    // Bug 111 — handleSleep() sets .stopped before async disconnect() closes fd
    //
    // EngineManager.swift:500–511: handleSleep() calls engineClient.disconnect()
    // then immediately sets status = .stopped — both synchronously on MainActor.
    // The disconnect() call closes the fd, which is correct.
    // The race manifests on the wake side: handleWake() calls tryPing() →
    // connectSync(), which can find fd != -1 if the OS has not yet propagated
    // the close, then status is already .stopped so the fast-path ping in
    // handleWake() is skipped and ensureRunning() sees status != .running and
    // proceeds without verifying the fd is truly dead.
    //
    // EXPECTED: handleWake() must not short-circuit on fd != -1 without
    //           verifying the connection is live; OR handleSleep() must
    //           guarantee disconnect is fully flushed before setting .stopped.
    // ACTUAL:   status is set synchronously while fd teardown is async-ish.
    // =======================================================================

    func testBug111_handleSleepSetsStoppedAfterDisconnect_sourceInspection() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        // The bug is that handleSleep() sets status = .stopped synchronously
        // without awaiting any confirmation that the fd is closed.
        // A correct implementation either: (a) uses `await disconnect()` and
        // then sets .stopped, or (b) handleWake() calls tryPing() regardless
        // of fd state to confirm liveness.
        //
        // We check that handleWake() does NOT skip the ping on the basis of
        // fd alone — i.e. it does not contain a guard/return that avoids
        // reconnect when fd appears open.
        //
        // Proxy: handleWake() must invoke tryPing() unconditionally; the correct
        // form is that tryPing() is the FIRST substantive call in the Task body.
        // We detect the bug by verifying handleSleep does not set `.stopped`
        // inline right after `disconnect()` without any await boundary.
        let handleSleepBlock = content.components(separatedBy: "func handleSleep()").last ?? ""
        let sleepUpToHandleWake = handleSleepBlock.components(separatedBy: "func handleWake()").first ?? ""
        // In the buggy code, disconnect() and status = .stopped are on back-to-back
        // lines with no `await` in between.
        let disconnectThenStopped = sleepUpToHandleWake.contains("engineClient.disconnect()") &&
                                    sleepUpToHandleWake.contains("status = .stopped")
        // A fix would introduce an `await` between the two, or remove the inline .stopped set.
        let hasAwaitBetween = sleepUpToHandleWake.contains("await")
        XCTAssertTrue(!disconnectThenStopped || hasAwaitBetween,
            "Bug 111 CONFIRMED: handleSleep() sets status = .stopped synchronously " +
            "immediately after engineClient.disconnect() with no await boundary. " +
            "If handleWake() fires before the fd close propagates, a reconnect attempt " +
            "may reuse a half-closed socket. " +
            "Fix: either await a guaranteed-closed signal before setting .stopped, or " +
            "ensure handleWake() always calls tryPing() rather than short-circuiting on fd state.")
    }

    // =======================================================================
    // Bug 112 — Stale resumeData never cleared when next download starts fresh
    //
    // ModelDownloader.swift:98–103: download() checks `if let data = resumeData`
    // and passes it to downloadTask(withResumeData:) unconditionally.
    // resumeData is only cleared on SHA256 failure or successful completion.
    // If the user cancels, deletes the partial file, then retries:
    //   1. cancel() stores stale resumeData (points at deleted partial file).
    //   2. download() finds resumeData != nil and calls downloadTask(withResumeData:).
    //   3. URLSession attempts to resume from a missing file → corrupt download.
    //
    // EXPECTED: at the start of download(), if the destination file does not
    //           exist, any cached resumeData must be discarded (set to nil)
    //           before deciding whether to resume or start fresh.
    // ACTUAL:   resumeData is consumed unconditionally regardless of file state.
    // =======================================================================

    func testBug112_staleResumeDataClearedWhenNoPartialFileExists_sourceInspection() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }
        // A correct download() implementation must check for the existence of
        // the destination/partial file INSIDE the download() function body,
        // BEFORE the `if let data = resumeData` branch, and clear resumeData
        // when the file is absent.
        //
        // Extract the download() function body by splitting on its signature.
        // We look for a fileExists guard combined with a resumeData nil-clear
        // that appears before the `if let data = resumeData` consume.
        guard let downloadFuncRange = content.range(of: "func download() async throws {") else {
            XCTFail("Cannot find download() function in ModelDownloader.swift"); return
        }
        // Grab everything from download() onward.
        let afterDownloadFunc = String(content[downloadFuncRange.lowerBound...])
        // Split at the next top-level func to isolate the function body.
        let downloadBody: String
        if let nextFunc = afterDownloadFunc.range(of: "\n    func ", range: afterDownloadFunc.index(afterDownloadFunc.startIndex, offsetBy: 10)..<afterDownloadFunc.endIndex) {
            downloadBody = String(afterDownloadFunc[..<nextFunc.lowerBound])
        } else {
            downloadBody = afterDownloadFunc
        }
        // The fix requires: a fileExists check in download() + resumeData = nil
        // BEFORE the `if let data = resumeData` branch.
        let hasFileExistsCheck = downloadBody.contains("fileExists")
        let resumeNilBeforeConsume: Bool = {
            guard let nilRange  = downloadBody.range(of: "resumeData = nil"),
                  let useRange  = downloadBody.range(of: "if let data = resumeData") else {
                return false
            }
            return nilRange.lowerBound < useRange.lowerBound
        }()
        XCTAssertTrue(hasFileExistsCheck && resumeNilBeforeConsume,
            "Bug 112 CONFIRMED: ModelDownloader.download() never checks whether the " +
            "destination file still exists before trusting resumeData. A cancel → " +
            "delete-partial-file → retry sequence feeds stale resume bytes to URLSession, " +
            "potentially producing a corrupt model file. " +
            "Fix: at the top of download(), before `if let data = resumeData`, check " +
            "FileManager.fileExists(atPath: destinationURL.path); if the file is absent, " +
            "set self.resumeData = nil so the next download always starts fresh.")
    }

    // =======================================================================
    // Bug 113 — drainResult processes one message after abortAndRestart() bumps generation
    //
    // OpenVerbApp.swift:803–847: the generation guard is ONLY in the while
    // condition. After `await receiveMessage()` resumes, the loop body executes
    // fully — including `livePartialText +=` — before the while-condition
    // re-checks generation.  One message from the aborted session leaks into
    // the new session's livePartialText.
    //
    // EXPECTED: the generation check must happen INSIDE the loop body,
    //           immediately after `await receiveMessage()` returns and BEFORE
    //           any action is taken on the message.
    // ACTUAL:   generation is only checked in the `while` condition — one
    //           post-abort message always slips through unguarded.
    // =======================================================================

    func testBug113_drainResultChecksGenerationBeforeProcessingMessage_sourceInspection() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        // The bug: generation is only in the `while` condition and in the catch
        // block.  After a successful `await receiveMessage()` the loop body
        // runs without re-checking generation — one stale message slips through.
        //
        // A correct implementation places the guard in the SUCCESS path:
        //   msg = try await receiveMessage(...)
        //   } catch { ... }           // catch block (already has guard)
        //   guard generation == drainGeneration else { return }  // ← NEW
        //   switch msg { ... }
        //
        // Strategy: extract the text BETWEEN the closing `}` of the catch block
        // and the `switch msg {` line.  The guard must appear in that gap.
        guard let drainRange = content.range(of: "func drainResult(generation:") else {
            XCTFail("Cannot find drainResult in OpenVerbApp.swift"); return
        }
        let afterDrain = String(content[drainRange.lowerBound...])

        // Find the end of the catch block — the `return` inside the catch,
        // followed by the closing brace of the catch.
        // We use the landmark `return\n        }\n\n        switch msg` which
        // represents the normal (unfixed) layout.
        let catchEndMarker = "return\n            }\n\n            switch msg {"
        let fixedCatchEndMarker = "return\n            }\n\n            guard generation == drainGeneration else { return }\n            switch msg {"

        let hasMidLoopGuard = afterDrain.contains(fixedCatchEndMarker)
        let hasOriginalLayout = afterDrain.contains(catchEndMarker)

        // Pass only if the mid-loop guard is present; fail if we see the
        // original layout (guard absent between catch-end and switch msg).
        XCTAssertTrue(hasMidLoopGuard || !hasOriginalLayout,
            "Bug 113 CONFIRMED: drainResult() lacks a generation guard in the success path. " +
            "After `await receiveMessage()` completes, the while-condition is not re-checked " +
            "until the end of the loop body, so one message from an aborted session is fully " +
            "processed (livePartialText +=) before the stale-generation check fires. " +
            "Fix: add `guard generation == drainGeneration else { return }` immediately after " +
            "the closing `}` of the do-catch block and before the `switch msg {` statement.")
    }

    // =======================================================================
    // Bug 114 — waitForProcessExit busy-waits on cooperative thread via RunLoop
    //
    // EngineManager.swift:344–350: waitForProcessExit() is `nonisolated` and
    // called from a detached Task (cooperative thread pool).  It spins with
    // `RunLoop.current.run(until: Date().addingTimeInterval(0.05))`.
    // A cooperative thread has no run-loop sources; this degenerates to a
    // 50 ms busy-wait, burning the thread slot for the full 500 ms timeout on
    // every shutdown() call.
    //
    // EXPECTED: use `Task.sleep` (or equivalent async suspension) so the
    //           cooperative thread is yielded during the wait.
    // ACTUAL:   RunLoop.current.run(until:) spin-waits and starves the pool.
    // =======================================================================

    func testBug114_waitForProcessExitUsesTaskSleepNotRunLoop_sourceInspection() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        // The buggy implementation uses RunLoop.current.run(until:) inside
        // waitForProcessExit. A fixed implementation replaces it with Task.sleep
        // (making the function async) or process.waitUntilExit() with a
        // deadline.  Either way, RunLoop.current.run(until:) must be gone.
        let hasRunLoopSpin = content.contains("RunLoop.current.run(until:")
        XCTAssertFalse(hasRunLoopSpin,
            "Bug 114 CONFIRMED: waitForProcessExit() uses RunLoop.current.run(until:) " +
            "in a nonisolated context called from a detached Task. On a cooperative thread " +
            "there are no run-loop sources, so this is a pure 50 ms busy-wait that " +
            "holds the thread pool slot for the full 500 ms on every shutdown(). " +
            "Fix: convert waitForProcessExit to async and replace the RunLoop spin with " +
            "`try? await Task.sleep(for: .milliseconds(50))` so the cooperative thread " +
            "is yielded during the wait.")
    }

    // =======================================================================
    // Bug 115 — Language picker shows no selection for unsupported system locales
    //
    // AppSettings.swift:221: on first launch the language is set from
    // Locale.current.language.languageCode?.identifier without validation.
    // PreferencesView.swift:77–92: the picker only lists 6 languages.
    // Any other system locale (zh-CN, ar, pt-BR) leaves the picker with no
    // visible selection, and the unrecognised code is silently forwarded to
    // the engine, which may reject or mishandle it.
    //
    // EXPECTED: setting language to an unsupported code must either (a) map it
    //           to the closest supported language or (b) fall back to the
    //           hardcoded default rather than storing the raw code.
    // ACTUAL:   the setter accepts any string; unsupported codes are stored
    //           and forwarded to the engine unchanged.
    // =======================================================================

    @MainActor
    func testBug115_unsupportedLanguageCodeFallsBackToDefault_behavioural() throws {
        let suiteName = "io.openverb.test.bug115.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        defer { mockDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: mockDefaults)

        // Supported languages in the picker (as documented in PreferencesView).
        let supportedLanguages: Set<String> = ["en", "de", "fr", "es", "it", "pt"]

        // Set an unsupported locale code.
        settings.language = "zh-CN"

        // After assignment the stored value must either be nil (no language
        // override, engine uses its own default) or one of the supported codes —
        // never the raw unsupported string.
        let stored = settings.language
        let isValid = stored == nil || supportedLanguages.contains(stored ?? "")
        XCTAssertTrue(isValid,
            "Bug 115 CONFIRMED: AppSettings.language accepted unsupported code " +
            "\"zh-CN\" and stored it as-is (\"\(stored ?? "nil")\"). " +
            "The language picker in PreferencesView will show no selection and " +
            "the engine will receive an unrecognised language token. " +
            "Fix: validate the language code against the supported set in the " +
            "didSet observer (or a dedicated setter). Reject unsupported codes by " +
            "falling back to nil or \"en\" rather than storing them as-is.")
    }

}
