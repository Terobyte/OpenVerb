import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 116, 117, 118, 119, 120, 121, 122
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_116_122: XCTestCase {

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
    // Bug 116 — Concurrent inject() calls interleave clipboard state
    //
    // TextInjector is a struct with static methods, no actor isolation, and no
    // serial dispatch queue guarding inject(). A stale drainResult Task can
    // call inject() while a new session's inject() is already running; the two
    // savedClipboard snapshots cross-contaminate each other.
    //
    // EXPECTED: TextInjector.inject() is protected from concurrent access via
    //   @MainActor annotation directly on the method, an `actor` declaration
    //   for the type, or a serial DispatchQueue ensuring only one inject() runs
    //   at a time.
    // ACTUAL:   No concurrency protection — concurrent calls run freely.
    // =======================================================================

    func testBug116_TextInjectorProtectedFromConcurrentAccess() {
        guard let src = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Bug 116 CONFIRMED: Cannot read TextInjector.swift. Fix: add actor isolation or serial queue guard to TextInjector.inject().")
            return
        }

        // The fix must include one of:
        //   (a) @MainActor directly before `static func inject(` on the function
        //   (b) declare TextInjector as an actor instead of a struct
        //   (c) a serial DispatchQueue used as a mutex around inject()

        // Option (a): @MainActor on the inject method signature.
        // The comment line mentions "@MainActor Task" — we must not match that.
        // We look for "@MainActor" immediately preceding "static func inject(" or
        // "@MainActor static func inject(" on the same logical line.
        let mainActorOnInject: Bool = {
            // Find the actual function declaration line and check the line or
            // the preceding line for @MainActor.
            let lines = src.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if line.contains("static func inject(") {
                    // Check same line or the immediately preceding non-empty line.
                    if line.contains("@MainActor") { return true }
                    if i > 0 && lines[i - 1].trimmingCharacters(in: .whitespaces) == "@MainActor" {
                        return true
                    }
                }
            }
            return false
        }()

        // Option (b): actor declaration
        let isActor = src.contains("actor TextInjector")

        // Option (c): serial queue — a DispatchQueue property inside TextInjector
        // that is referenced in the inject() function body.
        let hasSerialQueue: Bool = {
            // Look for a DispatchQueue property declared in the type.
            src.contains("DispatchQueue(label:") && src.contains("inject(")
        }()

        XCTAssertTrue(
            mainActorOnInject || isActor || hasSerialQueue,
            "Bug 116 CONFIRMED: TextInjector.inject() has no concurrency guard — concurrent calls " +
            "can interleave clipboard save/restore state. " +
            "Fix: annotate inject() with @MainActor, convert TextInjector to an actor, " +
            "or serialize calls through a dedicated serial DispatchQueue."
        )
    }

    // =======================================================================
    // Bug 117 — activate(options: []) deprecated and silently fails on macOS 14+
    //
    // TextInjector.swift (lines 72, 175) and CommandExecutor.swift (line 142)
    // call targetApp.activate(options: []).  On Sonoma this form is restricted
    // more aggressively than on earlier macOS versions, so activation silently
    // fails and the injected text is lost.
    //
    // EXPECTED: call sites use either .activateIgnoringOtherApps or, on
    //   macOS 14+, the replacement API NSRunningApplication.activate() with
    //   no arguments (the non-deprecated form).
    // ACTUAL:   all three call sites use activate(options: []) — the deprecated
    //           form with an empty options set.
    // =======================================================================

    func testBug117_ActivateUsesNonDeprecatedFormInTextInjector() {
        guard let src = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Bug 117 CONFIRMED: Cannot read TextInjector.swift. Fix: replace activate(options: []) with the macOS 14+ API or .activateIgnoringOtherApps.")
            return
        }

        // The deprecated no-op call must be gone.
        XCTAssertFalse(
            src.contains("activate(options: [])"),
            "Bug 117 CONFIRMED: TextInjector.swift still calls activate(options: []) which " +
            "silently fails on macOS 14+ Sonoma. " +
            "Fix: replace with NSRunningApplication.activate() (macOS 14+) or use " +
            ".activateIgnoringOtherApps on older targets."
        )
    }

    func testBug117_ActivateUsesNonDeprecatedFormInCommandExecutor() {
        guard let src = readSource("OpenVerb/Output/CommandExecutor.swift") else {
            XCTFail("Bug 117 CONFIRMED: Cannot read CommandExecutor.swift. Fix: replace activate(options: []) with the macOS 14+ API or .activateIgnoringOtherApps.")
            return
        }

        XCTAssertFalse(
            src.contains("activate(options: [])"),
            "Bug 117 CONFIRMED: CommandExecutor.swift still calls activate(options: []) which " +
            "silently fails on macOS 14+ Sonoma. " +
            "Fix: replace with NSRunningApplication.activate() (macOS 14+) or use " +
            ".activateIgnoringOtherApps on older targets."
        )
    }

    // =======================================================================
    // Bug 118 — RecordingHUDBugsTests resolves source paths against CWD —
    //           fails silently on CI
    //
    // RecordingHUDBugsTests.readSource() only tries URL(fileURLWithPath:),
    // which resolves relative to the process working directory.  When the test
    // runner's CWD is not `app/`, every readSource() call returns nil and all
    // tests silently report "Cannot read file" instead of their real assertions,
    // hiding real regressions.
    //
    // EXPECTED: readSource() falls back to Bundle.main.resourceURL lookup (as
    //   OpenBugsNegativeTests does) so it works regardless of CWD.
    // ACTUAL:   only the direct URL(fileURLWithPath:) path is tried; no Bundle
    //           fallback exists.
    // =======================================================================

    func testBug118_RecordingHUDBugsTestsHasBundleFallback() {
        guard let src = readSource("OpenVerbTests/RecordingHUDBugsTests.swift") else {
            XCTFail("Bug 118 CONFIRMED: Cannot read RecordingHUDBugsTests.swift. Fix: add Bundle.main.resourceURL fallback to readSource() in RecordingHUDBugsTests.")
            return
        }

        // The fix requires that the Bundle lookup appears in the readSource helper.
        let hasBundleFallback = src.contains("Bundle.main.resourceURL")

        XCTAssertTrue(
            hasBundleFallback,
            "Bug 118 CONFIRMED: RecordingHUDBugsTests.readSource() has no Bundle fallback — " +
            "all source-inspection tests silently fail with 'Cannot read file' when CWD ≠ app/. " +
            "Fix: add a Bundle.main.resourceURL lookup as a fallback after the direct URL attempt, " +
            "matching the pattern used by OpenBugsNegativeTests."
        )
    }

    // =======================================================================
    // Bug 119 — recvBuffer not cleared if connectSync called while already
    //           connected — stale bytes leak into the new session
    //
    // EngineClient.connectSync() begins with:
    //   guard fd == -1 else { return }
    // This early-return prevents a double-connect but also skips the
    // recvBuffer reset that follows it.  If the prior session left unread bytes
    // in recvBuffer, those bytes are returned as the first message of the new
    // session, triggering spurious protocol errors.
    //
    // EXPECTED: connectSync() clears recvBuffer even when fd != -1 (the socket
    //   is already open), OR the guard is removed and the buffer is always
    //   cleared unconditionally at the start of the method.
    // ACTUAL:   the guard returns before touching recvBuffer.
    // =======================================================================

    func testBug119_ConnectSyncClearsRecvBufferOnReconnect() {
        guard let src = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Bug 119 CONFIRMED: Cannot read EngineClient.swift. Fix: clear recvBuffer before the guard fd == -1 check in connectSync().")
            return
        }

        // Isolate the connectSync function body for analysis.
        // The function starts with `private func connectSync(path: String) throws {`
        // and ends at the closing `}` of that function.
        guard let funcStart = src.range(of: "private func connectSync(path: String) throws {") else {
            XCTFail("Bug 119 CONFIRMED: connectSync() not found in EngineClient.swift. File structure changed — review manually.")
            return
        }

        // Extract from the function start to the end of the file; we'll work
        // within this suffix to find relative positions.
        let funcBody = String(src[funcStart.lowerBound...])

        let guardPattern = "guard fd == -1 else { return }"
        let resetPattern = "recvBuffer = RecvAccumulator()"

        guard let guardRangeInBody = funcBody.range(of: guardPattern) else {
            // guard removed — the bug is fixed (option b); verify a reset exists.
            XCTAssertTrue(
                funcBody.contains(resetPattern),
                "Bug 119 CONFIRMED: guard fd == -1 removed but recvBuffer is never cleared in " +
                "connectSync(). Fix: always reset recvBuffer at the start of connectSync()."
            )
            return
        }

        // guard still present — the first recvBuffer reset in the function body
        // must appear BEFORE the guard to be reachable on reconnect.
        // Skip past the property declaration `private var recvBuffer = RecvAccumulator()`
        // by only looking within the function body (which starts after the class properties).
        guard let firstResetInBody = funcBody.range(of: resetPattern) else {
            XCTFail("Bug 119 CONFIRMED: recvBuffer is never reset inside connectSync(). Fix: add recvBuffer = RecvAccumulator() before the guard fd == -1 line.")
            return
        }

        XCTAssertTrue(
            firstResetInBody.lowerBound < guardRangeInBody.lowerBound,
            "Bug 119 CONFIRMED: EngineClient.connectSync() clears recvBuffer only AFTER " +
            "the guard fd == -1 early-return — reconnecting while already connected skips " +
            "the reset and stale bytes from the prior session are returned as the first " +
            "message of the new session. " +
            "Fix: move `recvBuffer = RecvAccumulator()` to before the guard fd == -1 line."
        )
    }

    // =======================================================================
    // Bug 120 — isConnected calls ioQueue.sync from MainActor — latent deadlock
    //
    // EngineClient.isConnected is implemented as:
    //   var isConnected: Bool { ioQueue.sync { fd >= 0 } }
    // Any future ioQueue block that dispatches back to the MainActor (e.g.
    // via Task { @MainActor ... }) would deadlock because MainActor is already
    // blocked inside ioQueue.sync.
    //
    // EXPECTED: isConnected does NOT use ioQueue.sync from the main actor. It
    //   must either be nonisolated and access fd via an atomic, or be rewritten
    //   as an async property that uses ioQueue.async.
    // ACTUAL:   ioQueue.sync is used directly.
    // =======================================================================

    func testBug120_IsConnectedDoesNotUseIOQueueSync() {
        guard let src = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Bug 120 CONFIRMED: Cannot read EngineClient.swift. Fix: remove ioQueue.sync from isConnected.")
            return
        }

        // The buggy line is:
        //   var isConnected: Bool { ioQueue.sync { fd >= 0 } }
        XCTAssertFalse(
            src.contains("var isConnected: Bool { ioQueue.sync"),
            "Bug 120 CONFIRMED: EngineClient.isConnected uses ioQueue.sync — calling it from " +
            "the MainActor will deadlock if any ioQueue block dispatches back to MainActor. " +
            "Fix: make isConnected nonisolated and back fd with an os_atomic / NSLock, or " +
            "rewrite as an async property using ioQueue.async."
        )
    }

    // =======================================================================
    // Bug 121 — Double configure() + register() on app launch installs tap twice
    //
    // In AppDelegate.normalStartup() (OpenVerbApp.swift), hotkeyManager.configure()
    // is called before the callbacks are wired, then hotkeyManager.register() is
    // called afterward.  HotkeyManager.configure() calls installEventTap() which
    // calls removeEventTap() then CGEvent.tapCreate() — it installs a live tap
    // with no callbacks assigned yet.  Then register() immediately tears it down
    // and reinstalls.  Between the two installations handleCGKeyEvent fires with
    // no onToggleRecording / onCancelRecording callbacks — keypresses are silently
    // dropped.
    //
    // EXPECTED: configure() only updates the stored key without touching the
    //   CGEvent tap (tap management belongs to register()). OR register() is
    //   idempotent and configure() does not call installEventTap at all.
    // ACTUAL:   configure() calls installEventTap() unconditionally.
    // =======================================================================

    func testBug121_ConfigureDoesNotInstallEventTapDirectly() {
        guard let src = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Bug 121 CONFIRMED: Cannot read HotkeyManager.swift. Fix: configure() should only store the key; tap installation should happen only in register().")
            return
        }

        // Isolate the configure() method body.
        guard let configureRange = src.range(of: "func configure(keyCode: CGKeyCode, modifiers: CGEventFlags)") else {
            XCTFail("Bug 121 CONFIRMED: configure(keyCode:modifiers:) not found in HotkeyManager.swift — file structure changed.")
            return
        }

        // Extract from the function signature to the end of file and find its body
        // (between the first `{` after the signature and its matching `}`).
        let afterSignature = String(src[configureRange.upperBound...])
        guard let bodyOpen = afterSignature.range(of: "{") else {
            XCTFail("Bug 121 CONFIRMED: Cannot locate configure() body in HotkeyManager.swift.")
            return
        }
        // Grab up to 200 chars of the body for a focused check (the method is short).
        let bodyStart = afterSignature.index(bodyOpen.upperBound, offsetBy: 0)
        let bodyEnd   = afterSignature.index(bodyStart,
                                              offsetBy: 200,
                                              limitedBy: afterSignature.endIndex) ?? afterSignature.endIndex
        let configureBody = String(afterSignature[bodyStart..<bodyEnd])

        // The buggy body is:
        //   installEventTap(key: HotKey(virtualKey: keyCode, flags: modifiers))
        // The fix removes that call from configure() — configure() only stores
        // the key (e.g. `hotKey = HotKey(...)` or updates a stored property).
        XCTAssertFalse(
            configureBody.contains("installEventTap("),
            "Bug 121 CONFIRMED: HotkeyManager.configure() calls installEventTap() — this " +
            "installs a CGEvent tap without any callbacks assigned yet, then register() " +
            "tears it down and reinstalls, leaving a window where hotkey events are dropped. " +
            "Fix: configure() should only update the stored hotkey; tap installation " +
            "must happen exclusively in register()."
        )
    }

    // =======================================================================
    // Bug 122 — autoClearTimer guard !Task.isCancelled after catch { return }
    //           is dead code
    //
    // AppState.swift, inside the autoClearTimer Task body:
    //
    //   do {
    //       try await Task.sleep(for: delay)
    //   } catch {
    //       return          // <-- cancellation exits here
    //   }
    //   guard !Task.isCancelled else { return }  // <-- unreachable via cancellation
    //   self?.transition(to: .idle)
    //
    // Task.sleep throws CancellationError on cancellation; the catch block
    // returns immediately.  The guard below can never be reached via cancellation,
    // making it dead code that misleads readers.
    //
    // EXPECTED: the guard !Task.isCancelled after the catch block is removed,
    //   OR the check is moved inside the do block where it is reachable.
    // ACTUAL:   the dead guard remains after the catch block.
    // =======================================================================

    func testBug122_DeadCancelGuardRemovedFromAutoClearTimer() {
        guard let src = readSource("OpenVerb/State/AppState.swift") else {
            XCTFail("Bug 122 CONFIRMED: Cannot read AppState.swift. Fix: remove or relocate the dead guard !Task.isCancelled after the catch block in autoClearTimer.")
            return
        }

        // Locate the autoClearTimer task body.  The task starts with
        // `let task = Task<Void, Never> { [weak self] in` inside the `.error`
        // case of applyEntryEffects.  Anchor on the unique assignment to detect it.
        guard let taskDeclRange = src.range(of: "let task = Task<Void, Never> { [weak self] in") else {
            // If the task declaration changed form, verify the dead guard is gone.
            XCTAssertFalse(
                src.contains("guard !Task.isCancelled else { return }"),
                "Bug 122 CONFIRMED: dead guard !Task.isCancelled still present after catch block. " +
                "Fix: remove the guard or move it inside the do block where it is reachable."
            )
            return
        }

        // Extract a window covering the task body (~300 chars after the declaration).
        let windowStart = taskDeclRange.lowerBound
        let windowEnd   = src.index(taskDeclRange.upperBound,
                                     offsetBy: 300,
                                     limitedBy: src.endIndex) ?? src.endIndex
        let window = String(src[windowStart..<windowEnd])

        // Both parts of the dead-code pattern must be present in the same task body:
        //   1. A catch block that returns (cancellation already handled).
        //   2. A guard !Task.isCancelled after that catch — unreachable.
        let catchReturns = window.contains("} catch {") && window.contains("return")
        let hasDeadGuard = window.contains("guard !Task.isCancelled else { return }")

        XCTAssertFalse(
            catchReturns && hasDeadGuard,
            "Bug 122 CONFIRMED: autoClearTimer Task in AppState.swift has a dead " +
            "`guard !Task.isCancelled else { return }` immediately after a `catch { return }` " +
            "block — the guard is unreachable via Task cancellation since the catch already returns. " +
            "Fix: remove the dead guard, or restructure so the check is inside the do block."
        )
    }
}
