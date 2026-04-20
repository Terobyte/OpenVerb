import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 102, 103, 104, 105, 106, 107, 108
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_102_108: XCTestCase {

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
    // Bug 102 — Surrogate-pair split: UTF-16 cursor offset bisects an emoji
    //
    // AccessibilityReader.swift:139–148 — NSString.substring(to: cursorPos)
    // uses a raw UTF-16 code unit index.  Multi-codepoint emoji like
    // 👨‍👩‍👧‍👦 (family) span many UTF-16 code units joined by ZWJ.  A cursor
    // offset that lands inside the emoji produces a lone surrogate or a
    // ZWJ-split cluster, yielding a string that is not valid UTF-8 when
    // bridged to Swift (or at minimum is a broken grapheme cluster).
    //
    // EXPECTED: the text-extraction path aligns the UTF-16 offset to a
    //           grapheme-cluster boundary before slicing (e.g. via
    //           String.unicodeScalars / rangeOfComposedCharacterSequence).
    // ACTUAL:   NSString.substring(to:) slices at the raw UTF-16 offset,
    //           potentially mid-emoji.
    // =======================================================================

    func testBug102_surrogatePairSplitProducesInvalidOutput() {
        guard let content = readSource("OpenVerb/Context/AccessibilityReader.swift") else {
            XCTFail("Cannot read AccessibilityReader.swift"); return
        }
        let hasGraphemeFix = content.contains("rangeOfComposedCharacterSequence")
        XCTAssertTrue(hasGraphemeFix,
            "Bug 102 CONFIRMED: AccessibilityReader.swift does not use " +
            "rangeOfComposedCharacterSequence(at:) before NSString slicing. " +
            "Fix: snap cursorPos to grapheme-cluster boundary before substring(to:).")
    }

    // =======================================================================
    // Bug 103 — hotkeyKeyCode = 0 (A key) treated as "not set"
    //
    // AppSettings.swift:208–209 — init() uses `defaults.integer(forKey:)`
    // which returns 0 for both "key absent" and "key present with value 0".
    // The guard `if storedKeyCode != 0` therefore treats ⌥A (keyCode 0x00)
    // as "not stored" and silently reverts to the Space default on every
    // launch.
    //
    // EXPECTED: persisting hotkeyKeyCode = 0 and reloading produces 0.
    // ACTUAL:   reloading produces 0x31 (Space default).
    // =======================================================================

    @MainActor
    func testBug103_hotkeyKeyCodeZeroRevertsToDefaultOnReload() {
        let suiteName = "io.openverb.test.bug103.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        // Create settings and set keyCode to 0 (the 'A' key on ANSI layout).
        let settings1 = AppSettings(defaults: testDefaults)
        settings1.hotkeyKeyCode = 0   // triggers didSet → writes to testDefaults
        testDefaults.synchronize()

        // Create a fresh AppSettings from the same suite (simulates app restart).
        let settings2 = AppSettings(defaults: testDefaults)
        let reloadedCode = settings2.hotkeyKeyCode

        XCTAssertEqual(reloadedCode, 0,
            "Bug 103 CONFIRMED: hotkeyKeyCode 0 (⌥A) was stored but reloaded as \(reloadedCode) " +
            "(the Space default 0x31). defaults.integer(forKey:) returns 0 for both absent and " +
            "stored-zero, so the guard `if storedKeyCode != 0` erases the stored value. " +
            "Fix: use defaults.object(forKey:) != nil to distinguish absent from stored-zero, " +
            "or store keyCode as a String/Data so 0 round-trips cleanly.")
    }

    // =======================================================================
    // Bug 104 — isDownloading cancel race: rapid double-tap overwrites valid
    //           resumeData with nil
    //
    // ModelDownloader.swift:110–117 — cancel() calls
    // cancel(byProducingResumeData:) unconditionally.  isDownloading is
    // written async inside the completion block.  A second cancel() fired
    // before that block runs hits an already-cancelled task, which delivers
    // nil, overwriting the valid resume token.
    //
    // EXPECTED: cancel() guards against double-cancellation by checking
    //           downloadTask != nil (or isDownloading) synchronously
    //           and nils out downloadTask before returning.
    // ACTUAL:   no synchronous guard; downloadTask is not cleared at the
    //           call site; second cancel() can deliver nil resume data.
    // =======================================================================

    func testBug104_cancelDoesNotGuardAgainstDoubleCancellation() {
        guard let source = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }

        // The fix requires that cancel() either:
        // (a) sets downloadTask = nil synchronously before returning, OR
        // (b) guards with `guard downloadTask != nil else { return }` (or
        //     equivalent) so a second cancel() is a no-op.
        //
        // Check for presence of a synchronous nil-out of downloadTask
        // inside cancel() before the async closure, which is the minimal
        // fix to prevent the second cancel from reaching the task.
        //
        // We look for the pattern: within the cancel() method body,
        // `downloadTask = nil` appears BEFORE `cancel(byProducingResumeData`.
        // A simple line-order check suffices here because the method is short.
        let cancelMethodRange = source.range(of: "func cancel()")
        XCTAssertNotNil(cancelMethodRange, "cancel() method must exist")
        guard let cancelStart = cancelMethodRange?.upperBound else { return }

        let afterCancel = String(source[cancelStart...])

        // Find the positions of the guard/nil-out and the async closure call.
        let nilOutIdx    = afterCancel.range(of: "downloadTask = nil")
        let cancelCallIdx = afterCancel.range(of: "cancel(byProducingResumeData")

        // A guard at the top (`guard downloadTask != nil else { return }`)
        // also prevents double-call — accept that pattern too.
        let guardIdx = afterCancel.range(of: "guard downloadTask != nil")
        let guardIsDownloadingIdx = afterCancel.range(of: "guard isDownloading")

        let hasSynchronousGuard: Bool = {
            // Pattern 1: nil-out downloadTask before the async closure call
            if let nil_ = nilOutIdx, let call_ = cancelCallIdx {
                return nil_.lowerBound < call_.lowerBound
            }
            // Pattern 2: guard downloadTask != nil at the top
            if let guard_ = guardIdx, let call_ = cancelCallIdx {
                return guard_.lowerBound < call_.lowerBound
            }
            // Pattern 3: guard isDownloading at the top
            if let guard_ = guardIsDownloadingIdx, let call_ = cancelCallIdx {
                return guard_.lowerBound < call_.lowerBound
            }
            return false
        }()

        XCTAssertTrue(hasSynchronousGuard,
            "Bug 104 CONFIRMED: cancel() does not guard against double-cancellation. " +
            "The second rapid cancel() fires on an already-cancelled URLSessionDownloadTask, " +
            "which delivers nil resume data, silently overwriting the valid resume token. " +
            "Fix: add `guard downloadTask != nil else { return }` at the top of cancel(), " +
            "or set `downloadTask = nil` synchronously before calling " +
            "cancel(byProducingResumeData:).")
    }

    // =======================================================================
    // Bug 105 — configure() has no retry watchdog — hotkey silently dies on
    //           tap failure during reconfiguration
    //
    // HotkeyManager.swift:100–103, 109–110 — register() starts the retry
    // watchdog when tapCreate returns nil.  configure() calls
    // installEventTap() directly, bypassing register(), so tap failures
    // mid-session leave the hotkey permanently dead with no recovery.
    //
    // EXPECTED: configure() either calls register() (which starts the
    //           watchdog) or explicitly starts the retry watchdog when
    //           installEventTap returns nil / eventTap is nil after the call.
    // ACTUAL:   configure() has no watchdog branch at all.
    // =======================================================================

    func testBug105_configureHasNoRetryWatchdog() {
        guard let source = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Cannot read HotkeyManager.swift"); return
        }

        // Isolate the configure() method body.
        guard let configureRange = source.range(of: "func configure(keyCode:") else {
            XCTFail("configure(keyCode:) not found in HotkeyManager.swift"); return
        }
        // Grab everything from configure() onward (next func ends the scope).
        let afterConfigure = String(source[configureRange.lowerBound...])

        // Find the end of the configure() method by locating the next
        // top-level `func ` or `private func` declaration.
        let configureBody: String
        if let nextFunc = afterConfigure.range(of: "\n    func ",
                                               range: afterConfigure.index(afterConfigure.startIndex,
                                                                           offsetBy: 10)..<afterConfigure.endIndex) {
            configureBody = String(afterConfigure[..<nextFunc.lowerBound])
        } else {
            configureBody = afterConfigure
        }

        // The fix requires that configure() either:
        // (a) calls register() (which already contains the watchdog), OR
        // (b) calls startRetryWatchdog() directly when eventTap is nil
        //     after installEventTap returns.
        let callsRegister        = configureBody.contains("register()")
        let callsWatchdog        = configureBody.contains("startRetryWatchdog()")
        let checksEventTapNil    = configureBody.contains("eventTap == nil")

        let hasRecovery = callsRegister || callsWatchdog || checksEventTapNil

        XCTAssertTrue(hasRecovery,
            "Bug 105 CONFIRMED: configure(keyCode:modifiers:) calls installEventTap() " +
            "without any watchdog branch. If the tap fails mid-session (e.g. permissions " +
            "revoked), the hotkey is permanently dead with no retry recovery. " +
            "Fix: after installEventTap(), check `if eventTap == nil { startRetryWatchdog() }` " +
            "or delegate to register() which already contains that logic.")
    }

    // =======================================================================
    // Bug 106 — showConflictAlert re-enters installEventTap which re-enters
    //           showConflictAlert — potential stack overflow on double conflict
    //
    // HotkeyManager.swift:365–371, 113–156 — showConflictAlert() calls
    // installEventTap() with the alternative key.  If that alternative key
    // also fails tapCreate, handleTapCreateFailure() → showConflictAlert()
    // is called again inside the still-running NSAlert.runModal() session,
    // creating a nested modal.
    //
    // EXPECTED: showConflictAlert / installEventTap guards against
    //           re-entrancy with a flag (e.g. isShowingConflictAlert).
    // ACTUAL:   no re-entrancy guard exists.
    // =======================================================================

    func testBug106_conflictAlertHasNoReentrancyGuard() {
        guard let source = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Cannot read HotkeyManager.swift"); return
        }

        // A re-entrancy guard would appear as a stored property flag plus a
        // guard/check at the top of showConflictAlert (or installEventTap).
        // Accept any of the following patterns:
        //   - a Bool property named isShowingAlert / isShowingConflictAlert /
        //     isHandlingConflict / conflictAlertShowing
        //   - a guard statement that returns early when such a flag is set
        let reentrancyPatterns = [
            "isShowingAlert",
            "isShowingConflictAlert",
            "isHandlingConflict",
            "conflictAlertShowing",
            "conflictInProgress",
        ]
        let hasReentrancyGuard = reentrancyPatterns.contains { source.contains($0) }

        XCTAssertTrue(hasReentrancyGuard,
            "Bug 106 CONFIRMED: showConflictAlert() calls installEventTap() with the " +
            "alternative hotkey. If that alternative also fails tapCreate, " +
            "handleTapCreateFailure() → showConflictAlert() is invoked again inside " +
            "the running NSAlert.runModal() session, creating nested modals and risking " +
            "a stack overflow on a machine where all alternatives conflict. " +
            "Fix: add a `private var isShowingConflictAlert = false` guard at the top " +
            "of showConflictAlert(), set it true before runModal and false after.")
    }

    // =======================================================================
    // Bug 107 — ShortcutCaptureView.deinit calls NSEvent.removeMonitor
    //           without dispatching to the main thread
    //
    // ShortcutRecorder.swift:54–58 — deinit can run on any thread that drops
    // the last reference.  NSEvent.removeMonitor(_:) is AppKit and must be
    // called on the main thread; calling it off-main is undefined behaviour.
    //
    // EXPECTED: deinit dispatches the NSEvent.removeMonitor call to the main
    //           thread (DispatchQueue.main.async or Task { @MainActor in }).
    // ACTUAL:   deinit calls NSEvent.removeMonitor directly, no thread hop.
    // =======================================================================

    func testBug107_deinitRemovesMonitorOffMainThread() {
        guard let source = readSource("OpenVerb/Input/ShortcutRecorder.swift") else {
            XCTFail("Cannot read ShortcutRecorder.swift"); return
        }

        // Isolate the deinit block.
        guard let deinitRange = source.range(of: "deinit {") else {
            XCTFail("deinit not found in ShortcutRecorder.swift"); return
        }
        // Take everything from deinit onward to the closing brace.
        let afterDeinit = String(source[deinitRange.lowerBound...])

        // Negative check: removeMonitor must not be called bare (without a
        // surrounding main-thread dispatch) in the deinit body.
        // We approximate this by checking that a dispatch wrapper appears
        // before the removeMonitor call site within the deinit block.
        let removeMonitorIdx  = afterDeinit.range(of: "NSEvent.removeMonitor")
        let mainDispatchIdx   = afterDeinit.range(of: "DispatchQueue.main")
            ?? afterDeinit.range(of: "Task { @MainActor")
            ?? afterDeinit.range(of: "MainActor.run")

        let isWrapped: Bool = {
            guard let rm = removeMonitorIdx else { return true }  // no call at all = no bug
            guard let md = mainDispatchIdx  else { return false } // dispatch absent = buggy
            return md.lowerBound < rm.lowerBound
        }()

        XCTAssertTrue(isWrapped,
            "Bug 107 CONFIRMED: ShortcutCaptureView.deinit calls NSEvent.removeMonitor " +
            "directly without dispatching to the main thread. deinit can run on any thread " +
            "that drops the last reference; calling AppKit off-main is undefined behaviour. " +
            "Fix: wrap the NSEvent.removeMonitor call inside deinit with " +
            "`DispatchQueue.main.async { NSEvent.removeMonitor(monitor) }` or " +
            "`Task { @MainActor in NSEvent.removeMonitor(monitor) }`.")
    }

    // =======================================================================
    // Bug 108 — AppSettings.shared static let accessible cross-actor — first
    //           access may initialize off the main actor
    //
    // AppSettings.swift:28–29, 37 — The class is @MainActor but
    // `static let shared = AppSettings()` is a lazy static and can be
    // accessed (and thus initialised) from any context.  A call like
    // `AppSettings.shared` from a non-@MainActor context runs init() off
    // the main actor, violating the isolation guarantee.
    //
    // EXPECTED: `static let shared` is annotated `nonisolated(unsafe)` with
    //           a note that it is pre-initialised on the main actor before
    //           any background access, OR the accessor is restricted to
    //           @MainActor only (e.g. a computed var).
    // ACTUAL:   plain `static let shared` with no isolation annotation.
    // =======================================================================

    func testBug108_sharedStaticLetMissingNonisolatedUnsafeOrMainActorGuard() {
        guard let source = readSource("OpenVerb/Settings/AppSettings.swift") else {
            XCTFail("Cannot read AppSettings.swift"); return
        }

        // Find the shared declaration line.
        guard let sharedLine = source
            .components(separatedBy: "\n")
            .first(where: { $0.contains("static let shared") || $0.contains("static var shared") })
        else {
            XCTFail("AppSettings.shared declaration not found"); return
        }

        // The fix is one of:
        // (a) nonisolated(unsafe) static let shared = ...
        // (b) a @MainActor-constrained computed var (which forces callers to
        //     await / hop to the main actor before accessing it), detected by
        //     `static var shared` combined with the class being @MainActor.
        let hasNonisolatedUnsafe = sharedLine.contains("nonisolated(unsafe)")
        let isComputedVar        = sharedLine.contains("static var shared")

        let isFixed = hasNonisolatedUnsafe || isComputedVar

        XCTAssertTrue(isFixed,
            "Bug 108 CONFIRMED: AppSettings is @MainActor but `static let shared` has no " +
            "isolation annotation. Any non-@MainActor context that accesses " +
            "AppSettings.shared first will run init() off the main actor, violating the " +
            "@MainActor isolation contract. Declaration found: \"\(sharedLine.trimmingCharacters(in: .whitespaces))\". " +
            "Fix: annotate as `nonisolated(unsafe) static let shared = AppSettings()` " +
            "(safe only if guaranteed to be initialised on the main actor at startup), " +
            "or change to a `@MainActor static var shared: AppSettings { ... }` computed " +
            "property so the compiler enforces main-actor access.")
    }
}
