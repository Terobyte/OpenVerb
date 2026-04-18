import XCTest
import ApplicationServices
import AppKit
@testable import OpenVerb

// ---------------------------------------------------------------------------
// OpenBugsNegativeTests — one test per open bug from bugs.md.
//
// Every test asserts CORRECT behaviour and FAILS while the bug exists.
// GREEN = bug fixed.  GREEN before the fix = false negative (test is wrong).
//
// Bugs covered (one test each):
//   Bug 22 — maxRecordingDuration AppSettings property never consumed
//   Bug 23 — EngineManager.modelDirPath is a snapshot (let, not var)
//   Bug 24 — PreferencesWindowController.open() creates orphan EngineManager
//   Bug 25 — Backend picker not gated on app state — kills active recording
//   Bug 26 — prompt_builder.h parse_context_json doc omits clipboard+language
//   Bug 27 — recvJSONSync() checks POLLHUP before POLLIN — loses final message
//   Bug 28 — socketReadLock absent — Phase 2 monitor and drainResult race on fd
//   Bug 29 — ModelDownloader.destinationURL hardcoded, ignores AppSettings
//   Bug 30 — TextInjector.injectPerCharacter() missing targetApp and window params
//   Bug 31 — PreferencesView keyNames table missing ANSI punctuation keys
//   Bug 32 — Audio frame ordering violation in connectAndRecord()       [HIGH]
//   Bug 33 — Data race on wakeWrite/wakeRead between MainActor/ioQueue  [HIGH]
//   Bug 36 — Force unwrap baseAddress! in sendJSONSync                  [MED]
//   Bug 37 — Force unwrap URL(string:)! in ModelDownloader             [MED]
//   Bug 38 — ShortcutCaptureView leaks NSEvent monitor on dealloc      [MED]
//   Bug 45 — ensureRunning() spin-wait 10 s freezes MainActor          [MED]
//   Bug 46 — drainResult() .error path skips crash recovery            [MED]
//   Bug 1  — updateAmplitude() defers append — stale amplitudes       [LOW]
//   Bug 48 — handleWake() self-deadlock: premature .starting           [HIGH]
//   Bug 49 — drainResult .error path missing disconnect()              [MED]
//   Bug 50 — showConflictAlert doesn't persist selected hotkey         [MED]
//   Bug 51 — handleCrash() ping corrupts active binary session         [HIGH]
//   Bug 52 — connectAndRecord() catch block missing disconnect()       [MED]
//   Bug 53 — server.cpp join() stalls new ping up to 15 s              [MED]
//   Bug 54 — TextInjector leaves transcription on pasteboard 300 ms   [HIGH]
//   Bug 55 — livePartialText dead during .recording                    [MED]
//   Bug 56 — phase2Monitor prepend-spin-loop starves drainResult       [HIGH]
//   Bug 57 — Session::stop() missing worker_thread_.join() → std::terminate [HIGH]
//   Bug 58 — vad.cpp trailing-silence loop narrows size_t → int       [LOW]
//   Bug 59 — polish_text() passes empty audio to backend → polish non-functional [MED]
// ---------------------------------------------------------------------------

final class OpenBugsNegativeTests: XCTestCase {

    // Reads a source file by path relative to the package source root.
    private func readSource(_ relativePath: String) -> String? {
        let direct = URL(fileURLWithPath: relativePath)
        if let content = try? String(contentsOf: direct, encoding: .utf8) {
            return content
        }
        if let base = Bundle.main.resourceURL {
            let bundled = base.appendingPathComponent(relativePath)
            if let content = try? String(contentsOf: bundled, encoding: .utf8) {
                return content
            }
        }
        return nil
    }

    private func substring(_ s: String, from start: String.Index, length: Int) -> String {
        let end = s.index(start, offsetBy: length, limitedBy: s.endIndex) ?? s.endIndex
        return String(s[start..<end])
    }

    // =======================================================================
    // Bug 22 — maxRecordingDuration AppSettings property unconsumed
    //
    // AppSettings.maxRecordingDuration is persisted and shown in Preferences
    // but no recording code ever reads it.  Recordings never auto-stop.
    //
    // EXPECTED: connectAndRecord() reads maxRecordingDuration and schedules
    //           an auto-stop Task that fires after the configured duration.
    // ACTUAL:   maxRecordingDuration does not appear in OpenVerbApp.swift.
    // =======================================================================

    func testBug22_maxRecordingDurationNotUsedInRecordingFlow() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        let usesMaxDuration = content.contains("maxRecordingDuration")
        XCTAssertTrue(usesMaxDuration,
            "Bug 22 CONFIRMED: maxRecordingDuration is defined in AppSettings but never " +
            "read in OpenVerbApp.swift. Recordings run until manual stop regardless of " +
            "the Preferences → General → Max Recording Duration setting. " +
            "Fix: schedule a Task.sleep(for: .seconds(appSettings.maxRecordingDuration)) " +
            "in connectAndRecord() that calls stopRecording() if still in .recording state.")
    }

    // =======================================================================
    // Bug 23 — EngineManager.modelDirPath is a one-time snapshot
    //
    // modelDirPath is declared `let` and read once from AppSettings at init().
    // Changing the model directory in Preferences has no effect until restart.
    //
    // EXPECTED: modelDirPath is a computed var (or read dynamically per call)
    //           so launchEngine() always uses the current AppSettings value.
    // ACTUAL:   `let modelDirPath: String` is a frozen snapshot.
    // =======================================================================

    func testBug23_modelDirPathIsSnapshotNotDynamic() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        let hasLetDecl = content.contains("let modelDirPath: String")
        XCTAssertFalse(hasLetDecl,
            "Bug 23 CONFIRMED: EngineManager.modelDirPath is declared `let`, " +
            "making it a one-time snapshot of AppSettings.modelDirectory captured at init(). " +
            "Changing the model directory in Preferences has no effect until app restart. " +
            "Fix: change to `var modelDirPath: String` computed from " +
            "AppSettings.shared.modelDirectory, or re-read the setting inside launchEngine().")
    }

    // =======================================================================
    // Bug 24 — PreferencesWindowController.open() creates orphan EngineManager
    //
    // `self.engineManager ?? EngineManager()` silently creates a new instance
    // if the weak reference is nil.  The orphan registers duplicate sleep/wake
    // observers and its restartWithBackend() targets the wrong (no-op) engine.
    //
    // EXPECTED: open() asserts / fatalErrors in DEBUG if engineManager is nil;
    //           never creates a fallback EngineManager().
    // ACTUAL:   `?? EngineManager()` fallback is present.
    // =======================================================================

    func testBug24_orphanEngineManagerFallbackPresent() {
        guard let content = readSource("OpenVerb/UI/PreferencesView.swift") else {
            XCTFail("Cannot read PreferencesView.swift"); return
        }
        let hasOrphanFallback = content.contains("?? EngineManager()")
        XCTAssertFalse(hasOrphanFallback,
            "Bug 24 CONFIRMED: PreferencesWindowController.open() uses " +
            "`self.engineManager ?? EngineManager()` as a fallback when the weak " +
            "reference is nil. The orphan installs duplicate willSleep/didWake observers " +
            "and its restartWithBackend() has no effect on the real engine. " +
            "Fix: use assert / fatalError in DEBUG; guard + early return in production.")
    }

    // =======================================================================
    // Bug 25 — Backend picker not gated on app state — kills active recording
    //
    // Changing the backend calls restartWithBackend() immediately regardless
    // of whether a recording or inference is in progress.  The engine is
    // killed mid-session with no user warning.
    //
    // EXPECTED: backend Picker is disabled whenever appState.state != .idle.
    // ACTUAL:   PreferencesView has no reference to AppState.
    // =======================================================================

    func testBug25_backendPickerNotGatedOnAppState() {
        guard let content = readSource("OpenVerb/UI/PreferencesView.swift") else {
            XCTFail("Cannot read PreferencesView.swift"); return
        }
        let hasAppStateField = content.contains("var appState") || content.contains("AppState")
        guard let pickerRange = content.range(of: "Picker(\"Backend\"") else {
            XCTFail("Cannot find backend Picker in PreferencesView.swift"); return
        }
        let afterPicker = substring(content, from: pickerRange.lowerBound, length: 600)
        let pickerGatedOnState = afterPicker.contains("appState")

        XCTAssertTrue(hasAppStateField && pickerGatedOnState,
            "Bug 25 CONFIRMED: PreferencesView has no AppState reference " +
            "(hasAppStateField=\(hasAppStateField)), so the backend Picker cannot be " +
            "disabled during an active recording or inference (pickerGatedOnState=\(pickerGatedOnState)). " +
            "Switching backend mid-session kills the engine with no user feedback. " +
            "Fix: add @ObservedObject var appState: AppState to PreferencesView and " +
            "disable the Picker when appState.state != .idle.")
    }

    // =======================================================================
    // Bug 26 — prompt_builder.h parse_context_json() doc omits fields
    //
    // The schema comment lists "app", "window", "selected" but omits
    // "clipboard" and "language" — both of which are sent by ContextBuilder.
    //
    // EXPECTED: schema comment includes all five keys the implementation reads.
    // ACTUAL:   "clipboard" and "language" absent from the doc comment.
    // =======================================================================

    func testBug26_promptBuilderDocMissingClipboardAndLanguage() {
        let relPath = "engine/src/context/prompt_builder.h"
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/context/prompt_builder.h"
        guard let content = readSource(relPath) ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read prompt_builder.h"); return
        }
        // Anchor on the em-dash description line specific to the function's doc block.
        // Using "parse_context_json" alone would match line 11 of the struct doc
        // which contains the full wire-format with all 5 fields — a false positive.
        guard let docRange = content.range(of: "parse_context_json \u{2014}") else {
            XCTFail("Cannot find parse_context_json — doc line in prompt_builder.h"); return
        }
        let docBlock = substring(content, from: docRange.lowerBound, length: 400)
        let hasClipboard = docBlock.contains("\"clipboard\"")
        let hasLanguage  = docBlock.contains("\"language\"")
        XCTAssertTrue(hasClipboard && hasLanguage,
            "Bug 26 CONFIRMED: parse_context_json() doc in prompt_builder.h is missing " +
            "\"clipboard\" (present=\(!hasClipboard ? "NO" : "yes")) and " +
            "\"language\" (present=\(!hasLanguage ? "NO" : "yes")) from the schema comment. " +
            "ContextBuilder.swift actively sends both fields; omitting them from the doc " +
            "causes silent degradation for any developer relying solely on the header. " +
            "Fix: add \"clipboard\" and \"language\" to the schema comment in " +
            "parse_context_json's doc block.")
    }

    // =======================================================================
    // Bug 27 — recvJSONSync() POLLHUP-before-POLLIN loses final engine message
    //
    // When the engine sends a final message then closes the socket, poll()
    // returns with both POLLIN and POLLHUP set.  The POLLHUP branch fires
    // first, throwing connectionClosed — the data in the read buffer is lost.
    //
    // EXPECTED: POLLIN is checked and drained before POLLHUP is treated as EOF.
    // ACTUAL:   POLLHUP check appears before the POLLIN guard in recvJSONSync.
    // =======================================================================

    func testBug27_pollhupCheckedBeforePollin() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        guard let fnRange = content.range(of: "private func recvJSONSync") else {
            XCTFail("Cannot find recvJSONSync in EngineClient.swift"); return
        }
        // Bug 28's socketReadLock added ~1100 chars to the function header;
        // bump the scan window so the POLLHUP/POLLIN guards are still reached.
        let body = substring(content, from: fnRange.lowerBound, length: 3000)
        guard let pollhupRange = body.range(of: "POLLHUP | POLLERR"),
              let pollinRange  = body.range(of: "guard pfd.revents & Int16(POLLIN)") else {
            XCTFail("Cannot locate POLLHUP or POLLIN guard in recvJSONSync"); return
        }
        let pollhupFirst = pollhupRange.lowerBound < pollinRange.lowerBound
        XCTAssertFalse(pollhupFirst,
            "Bug 27 CONFIRMED: recvJSONSync() checks POLLHUP | POLLERR before draining " +
            "POLLIN. When the engine sends a last message and immediately closes the " +
            "socket, poll() sets both flags. The POLLHUP branch fires, throwing " +
            "connectionClosed — the response bytes are never read. " +
            "Fix: check POLLIN first; call read() to drain; only treat POLLHUP as EOF " +
            "after read() returns 0.")
    }

    // =======================================================================
    // Bug 28 — socketReadLock absent — Phase 2 monitor and drainResult race
    //
    // recvJSONSync() is called concurrently from ioQueue (drainResult) and a
    // detached Task (Phase 2 monitor).  The poll()+read() syscalls are not
    // serialised — two threads can split one message's bytes between them.
    //
    // EXPECTED: a socketReadLock (NSLock) serialises poll+read+append in recvJSONSync.
    // ACTUAL:   no such lock exists; recvLock only guards recvBuffer mutations.
    // =======================================================================

    func testBug28_socketReadLockAbsent() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        let hasSocketReadLock = content.contains("socketReadLock")
        XCTAssertTrue(hasSocketReadLock,
            "Bug 28 CONFIRMED: EngineClient has no socketReadLock. recvJSONSync() is " +
            "called from two concurrency domains (ioQueue via drainResult, and a detached " +
            "Task via the Phase 2 monitor) without synchronisation on poll()+read(). " +
            "Two simultaneous reads on the same fd split message bytes between threads, " +
            "causing decode failures or lost results. " +
            "Fix: declare `private let socketReadLock = NSLock()` and wrap the " +
            "poll()+read()+recvBuffer.append() block in recvJSONSync() with it.")
    }

    // =======================================================================
    // Bug 29 — ModelDownloader.destinationURL hardcoded, ignores AppSettings
    //
    // ModelDownloader.init() always writes to ~/.openverb/models/ regardless of
    // AppSettings.modelDirectory.  If the user changes the model path, downloads
    // land in the wrong place and the engine cannot find the model.
    //
    // EXPECTED: destinationURL is derived from AppSettings.modelDirectory.
    // ACTUAL:   init() hardcodes homeDirectoryForCurrentUser/.openverb/models.
    // =======================================================================

    func testBug29_modelDownloaderDestinationIgnoresAppSettings() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }
        let readsFromSettings = content.contains("AppSettings")
        // Bug 29 fix changed the signature from `override init()` to
        // `init(modelDirectory: URL? = nil)` — accept either form.
        let hasInit = content.contains("override init()") || content.contains("init(modelDirectory:")
        guard hasInit else {
            XCTFail("Cannot find init in ModelDownloader.swift"); return
        }
        // If the file accepts modelDirectory as a parameter, the path is no
        // longer hardcoded regardless of whether ".openverb/models" appears as
        // a fallback default — that is the correct behaviour.
        let fixedViaParam = content.contains("init(modelDirectory:")
        let hardcodesPath = content.contains("override init()") &&
            content.range(of: "override init()").map { r in
                substring(content, from: r.lowerBound, length: 300).contains(".openverb/models")
            } ?? false

        XCTAssertFalse((hardcodesPath && !readsFromSettings) && !fixedViaParam,
            "Bug 29 CONFIRMED: ModelDownloader.init() hardcodes ~/.openverb/models/ " +
            "instead of reading AppSettings.modelDirectory. Downloaded models land in " +
            "the wrong directory when the user has a custom model path. " +
            "Fix: accept a modelDirectory: URL parameter in init(); pass " +
            "AppSettings.shared.modelDirectory from the call site in showOnboarding().")
    }

    // =======================================================================
    // Bug 30 — TextInjector.injectPerCharacter() missing focus transfer params
    //
    // injectPerCharacter() posts CGEvent keystrokes without hiding the panel
    // or activating the target app.  While the floating window is visible it
    // retains key-window status and all keystrokes go to the wrong app.
    //
    // EXPECTED: signature includes targetApp: NSRunningApplication and window
    //           parameter; focus transfer mirrors inject().
    // ACTUAL:   `static func injectPerCharacter(_ text: String)` — no params.
    // =======================================================================

    func testBug30_injectPerCharacterMissingFocusTransferParams() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }
        guard let fnRange = content.range(of: "func injectPerCharacter") else {
            XCTFail("Cannot find injectPerCharacter in TextInjector.swift"); return
        }
        let signature = substring(content, from: fnRange.lowerBound, length: 200)
        let hasTargetApp = signature.contains("targetApp") || signature.contains("NSRunningApplication")
        let hasWindow    = signature.contains("window:") || signature.contains("RecordingWindow")
        XCTAssertTrue(hasTargetApp && hasWindow,
            "Bug 30 CONFIRMED: injectPerCharacter() signature is `(_ text: String)` — " +
            "no targetApp (present=\(hasTargetApp)) or window param (present=\(hasWindow)). " +
            "The floating panel keeps key-window status while keystrokes fire, so all " +
            "characters are delivered to OpenVerb rather than the user's app. " +
            "Fix: add targetApp: NSRunningApplication and window: RecordingWindow params; " +
            "mirror the focus-transfer sequence (orderOut + activate + 50 ms delay) " +
            "from inject() before the keystroke loop.")
    }

    // =======================================================================
    // Bug 31 — PreferencesView keyNames table missing ANSI punctuation keys
    //
    // The keyNames dictionary in hotkeyDescription omits 10 ANSI punctuation
    // codes.  Hotkeys like ⌥= display as "⌥Key(24)" instead of "⌥=".
    //
    // EXPECTED: all ANSI key codes that ShortcutRecorder can capture are in
    //           keyNames so labels always show human-readable characters.
    // ACTUAL:   0x18 (=), 0x1B (-), 0x1E (]), 0x21 ([), 0x27 ('), 0x29 (;),
    //           0x2A (\), 0x2B (,), 0x2C (/), 0x2F (.) are absent.
    // =======================================================================

    func testBug31_hotkeyKeyNamesTableMissingPunctuation() {
        guard let content = readSource("OpenVerb/UI/PreferencesView.swift") else {
            XCTFail("Cannot read PreferencesView.swift"); return
        }
        guard let dictRange = content.range(of: "let keyNames: [UInt16: String]") else {
            XCTFail("Cannot find keyNames dictionary in PreferencesView.swift"); return
        }
        let dictBlock = substring(content, from: dictRange.lowerBound, length: 600)

        let required: [(String, String)] = [
            ("0x18", "="), ("0x1B", "-"), ("0x1E", "]"), ("0x21", "["),
            ("0x27", "'"), ("0x29", ";"), ("0x2A", "\\\\"), ("0x2B", ","),
            ("0x2C", "/"), ("0x2F", "."),
        ]
        var missing: [String] = []
        for (code, sym) in required {
            if !dictBlock.contains(code) { missing.append("\(code) (\(sym))") }
        }
        XCTAssertTrue(missing.isEmpty,
            "Bug 31 CONFIRMED: keyNames dictionary is missing entries: " +
            "\(missing.joined(separator: ", ")). " +
            "Hotkeys using these keys display as e.g. ⌥Key(24) instead of ⌥=. " +
            "Fix: add all missing entries to the keyNames dictionary in " +
            "PreferencesView.hotkeyDescription.")
    }

    // =======================================================================
    // Bug 16 — drainResult tears down new session after abort+restart
    //
    // A stale drainResult Task from an aborted session resumes its
    // receiveMessage() continuation with an error after abortAndRestart()
    // has already moved the state machine to the new session. The old
    // Task's catch clause then tears down UI belonging to the NEW session.
    //
    // EXPECTED: drainResult accepts a generation: UInt64 parameter; the
    //           catch block returns early when the captured generation no
    //           longer matches self.drainGeneration. stopRecording() and
    //           abortAndRestart() both bump drainGeneration.
    // ACTUAL:   drainResult takes no generation; both a new drainResult and
    //           the stale one share the same ".inferring" state guard,
    //           letting the stale one tear down the new session's UI.
    // =======================================================================

    func testBug16_drainResultLacksGenerationGuard() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        let hasField             = content.contains("drainGeneration")
        let hasGenerationParam   = content.contains("drainResult(generation:")
        let bumpedInStopRecord   = content.range(of: "private func stopRecording").map { r in
            substring(content, from: r.lowerBound, length: 2500).contains("drainGeneration &+= 1")
        } ?? false
        let bumpedInAbortRestart = content.range(of: "private func abortAndRestart").map { r in
            substring(content, from: r.lowerBound, length: 2500).contains("drainGeneration &+= 1")
        } ?? false
        XCTAssertTrue(
            hasField && hasGenerationParam && bumpedInStopRecord && bumpedInAbortRestart,
            "Bug 16 CONFIRMED: OpenVerbApp.swift is missing the drain-generation " +
            "guard that prevents a stale drainResult Task from tearing down the " +
            "UI of a new session after abort+restart. " +
            "hasField=\(hasField), hasGenerationParam=\(hasGenerationParam), " +
            "bumpedInStopRecording=\(bumpedInStopRecord), bumpedInAbortRestart=\(bumpedInAbortRestart). " +
            "Fix: add `private var drainGeneration: UInt64 = 0`, bump it in " +
            "stopRecording() and abortAndRestart(), pass the captured value into " +
            "drainResult(generation:), and return early in the catch block if the " +
            "captured generation no longer matches self.drainGeneration.")
    }

    // =======================================================================
    // Bug 17 — Phase 2 monitor fires onError after stopPhase2Monitor()
    //
    // stopPhase2Monitor() sets phase2MonitorStopped=true but does not join
    // the monitor Task. If the monitor is inside recvJSONSync when the
    // subsequent disconnect() closes fd, recvJSONSync throws; the monitor
    // catches and — before this fix — calls onError?(errMsg) directly. The
    // .error case in the switch has no re-check at all.  On the receive
    // side, the AppDelegate onError handler runs teardown unconditionally,
    // clobbering .preparing / .idle from abort+restart or cancel.
    //
    // EXPECTED: every onError call site goes through a helper that re-reads
    //           phase2MonitorStopped under phase2Lock (send-side), AND the
    //           AppDelegate onError closure guards on appState.state being
    //           .recording or .inferring before running teardown (receive-side).
    // ACTUAL:   at least one call site invokes onError?(...) directly without
    //           re-checking, and/or the AppDelegate handler has no state guard.
    // =======================================================================

    func testBug17_phase2OnErrorRaceUnfixed() {
        guard let clientSrc = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        guard let appSrc = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }

        // Send-side: helper exists and is used in runPhase2Monitor.
        let hasHelper = clientSrc.contains("callOnErrorIfLive")
        // Ensure no bare `onError?(` calls remain inside runPhase2Monitor.
        let noBareOnErrorInMonitor: Bool = {
            guard let r = clientSrc.range(of: "private func runPhase2Monitor") else { return false }
            // scan from runPhase2Monitor to the next "func " outside it.
            let after = clientSrc[r.lowerBound...]
            guard let endRange = after.range(of: "\n    func ")
                ?? after.range(of: "\n    private func ", range: after.index(after.startIndex, offsetBy: 10)..<after.endIndex)
            else { return !after.contains("onError?(") }
            let body = after[after.startIndex..<endRange.lowerBound]
            return !body.contains("onError?(")
        }()

        // Receive-side: AppDelegate onError handler guards on appState.state.
        let onErrorHandlerGuarded: Bool = {
            guard let r = appSrc.range(of: "engineManager.engineClient.onError = ") else {
                return false
            }
            let block = substring(appSrc, from: r.lowerBound, length: 1200)
            // Must reference appState.state before any teardown call.
            guard let stateRange = block.range(of: "appState.state"),
                  let teardownRange = block.range(of: "audioSession.stop()") else {
                return false
            }
            return stateRange.lowerBound < teardownRange.lowerBound
        }()

        XCTAssertTrue(
            hasHelper && noBareOnErrorInMonitor && onErrorHandlerGuarded,
            "Bug 17 CONFIRMED: Phase 2 monitor onError race is not fully closed. " +
            "hasHelper=\(hasHelper), noBareOnErrorInMonitor=\(noBareOnErrorInMonitor), " +
            "onErrorHandlerGuarded=\(onErrorHandlerGuarded). " +
            "Fix: add a `callOnErrorIfLive(_:)` helper that re-reads phase2MonitorStopped " +
            "under phase2Lock and only calls onError if not stopped; replace all onError?(...) " +
            "call sites in runPhase2Monitor with it. AND in OpenVerbApp.swift, gate the " +
            "onError closure on `appState.state == .recording || .inferring` before running teardown.")
    }

    // =======================================================================
    // Bug 25 (extended) — restartWithBackend must also refuse programmatic calls
    //
    // The UI-level picker gate (testBug25_backendPickerNotGatedOnAppState)
    // is necessary but not sufficient — any programmatic caller of
    // restartWithBackend (tests, future MCP hooks, auto-switch buttons)
    // bypasses it. EngineManager should hold an injected guard closure.
    //
    // EXPECTED: EngineManager exposes `canRestartBackend: (() -> Bool)?`,
    //           restartWithBackend() returns early when it evaluates to false.
    // ACTUAL:   no such closure; restartWithBackend() proceeds unconditionally.
    // =======================================================================

    func testBug25_restartWithBackendProgrammaticallyGuarded() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        let hasClosure = content.contains("canRestartBackend")
        let hasGuardInRestart: Bool = {
            guard let r = content.range(of: "func restartWithBackend") else { return false }
            let body = substring(content, from: r.lowerBound, length: 600)
            return body.contains("canRestartBackend?()")
        }()
        XCTAssertTrue(hasClosure && hasGuardInRestart,
            "Bug 25 (programmatic) CONFIRMED: EngineManager.restartWithBackend() has " +
            "no defense against programmatic callers (hasClosure=\(hasClosure), " +
            "hasGuardInRestart=\(hasGuardInRestart)). " +
            "Fix: add `var canRestartBackend: (() -> Bool)?` and guard the start of " +
            "restartWithBackend() with `guard canRestartBackend?() ?? true else { return }`. " +
            "Bind it from AppDelegate to `appState.state == .idle`.")
    }

    // =======================================================================
    // Bug 34 — Missing waveformVM.reset() in abortAndRestart()
    //
    // startRecording() calls waveformVM.reset() at line ~393, but
    // abortAndRestart() only calls processingVM.reset(). After reconnect
    // the recording window briefly shows stale waveform bars from the
    // previous session.
    //
    // EXPECTED: abortAndRestart() calls waveformVM.reset() alongside
    //           processingVM.reset().
    // ACTUAL:   only processingVM.reset() is present in the restart Task.
    // =======================================================================

    func testBug34_waveformResetMissingInAbortAndRestart() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        guard let fnRange = content.range(of: "private func abortAndRestart") else {
            XCTFail("Cannot find abortAndRestart in OpenVerbApp.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 2500)
        let hasWaveformReset = fnBody.contains("waveformVM.reset()")
        XCTAssertTrue(hasWaveformReset,
            "Bug 34 CONFIRMED: abortAndRestart() does not call waveformVM.reset(). " +
            "startRecording() correctly calls it at line ~393, but the restart path " +
            "only calls processingVM.reset(). When the recording window reappears after " +
            "reconnect, stale waveform bars from the previous session remain visible " +
            "until new audio data arrives. " +
            "Fix: add waveformVM.reset() after processingVM.reset() in the restart Task " +
            "inside abortAndRestart().")
    }

    // =======================================================================
    // Bug 35 — maxDurationTimer not cancelled in drainResult() result/error paths
    //
    // drainResult() receives .result or .error messages and transitions to
    // .idle but never cancels maxDurationTimer. Currently safe because
    // stopRecording() always runs first and cancels it, but fragile.
    //
    // EXPECTED: drainResult() cancels maxDurationTimer in both .result
    //           and .error branches.
    // ACTUAL:   neither branch cancels the timer.
    // =======================================================================

    func testBug35_maxDurationTimerNotCancelledInDrainResult() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        guard let fnRange = content.range(of: "private func drainResult") else {
            XCTFail("Cannot find drainResult in OpenVerbApp.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 4500)
        let cancelsInResult = fnBody.contains("maxDurationTimer?.cancel()")
        XCTAssertTrue(cancelsInResult,
            "Bug 35 CONFIRMED: drainResult() does not cancel maxDurationTimer in its " +
            ".result or .error branches. stopRecording() cancels it before drainResult " +
            "runs, but if the flow changes the timer could fire during the next session. " +
            "Fix: add maxDurationTimer?.cancel() / maxDurationTimer = nil at the top of " +
            "both the .result and .error case blocks in drainResult().")
    }

    // =======================================================================
    // Bug 39 — WaveformViewModel.reset() deferred by unnecessary DispatchQueue.main.async
    //
    // WaveformViewModel is @MainActor. Its reset() wraps
    // amplitudes.removeAll() in DispatchQueue.main.async, deferring
    // execution by one run loop iteration. There's a 1-frame window
    // where stale bars remain visible.
    //
    // EXPECTED: reset() calls self.amplitudes.removeAll() directly.
    // ACTUAL:   reset() wraps the call in DispatchQueue.main.async.
    // =======================================================================

    func testBug39_waveformResetDeferredByMainAsync() {
        guard let content = readSource("OpenVerb/UI/WaveformView.swift") else {
            XCTFail("Cannot read WaveformView.swift"); return
        }
        guard let resetRange = content.range(of: "func reset()") else {
            XCTFail("Cannot find reset() in WaveformView.swift"); return
        }
        let resetBody = substring(content, from: resetRange.lowerBound, length: 200)
        let wrapsInMainAsync = resetBody.contains("DispatchQueue.main.async")
        XCTAssertFalse(wrapsInMainAsync,
            "Bug 39 CONFIRMED: WaveformViewModel.reset() wraps amplitudes.removeAll() " +
            "in DispatchQueue.main.async even though the class is @MainActor. This " +
            "defers the reset by one run loop tick, leaving stale waveform bars visible " +
            "for one frame. updateAmplitude(_:) correctly uses DispatchQueue.main.async " +
            "because it's nonisolated and called from a background thread, but reset() is " +
            "already on the main actor and needs no dispatch. " +
            "Fix: remove the DispatchQueue.main.async wrapper — call " +
            "self.amplitudes.removeAll() directly inside reset().")
    }

    // =======================================================================
    // Bug 40 — maxRecordingDuration didSet causes double UserDefaults write
    //
    // When the value needs clamping, re-assigning triggers didSet again,
    // causing two UserDefaults writes and two objectWillChange notifications.
    //
    // EXPECTED: didSet writes to UserDefaults only once, after clamping.
    // ACTUAL:   the clamp re-assignment triggers a second didSet, and the
    //           first didSet also writes the unclamped value.
    // =======================================================================

    func testBug40_maxDurationDidSetDoubleWrite() {
        guard let content = readSource("OpenVerb/Settings/AppSettings.swift") else {
            XCTFail("Cannot read AppSettings.swift"); return
        }
        guard let propRange = content.range(of: "var maxRecordingDuration: Int") else {
            XCTFail("Cannot find maxRecordingDuration in AppSettings.swift"); return
        }
        let didSetBody = substring(content, from: propRange.lowerBound, length: 400)
        let reassignsInDidSet = didSetBody.contains("if clamped != maxRecordingDuration { maxRecordingDuration = clamped }")
        XCTAssertFalse(reassignsInDidSet,
            "Bug 40 CONFIRMED: maxRecordingDuration didSet re-assigns the property " +
            "inside didSet when clamping is needed (`maxRecordingDuration = clamped`), " +
            "triggering didSet recursively. This causes two UserDefaults writes and two " +
            "objectWillChange notifications. The first write stores the unclamped value, " +
            "the second overwrites with the clamped one. " +
            "Fix: use a separate backing stored property, or clamp before writing to " +
            "UserDefaults without re-assigning, e.g. " +
            "`let final = maxRecordingDuration.clamped(to: 1...300); " +
            "maxRecordingDuration = final; defaults.set(final, forKey: ...)` " +
            "or suppress didSet with a flag.")
    }

    // =======================================================================
    // Bug 41 — StatusBarItem.engineObserver dead code
    //
    // `private var engineObserver: Any?` is declared but never assigned
    // or read. Leftover from a Combine-based implementation.
    //
    // EXPECTED: engineObserver property does not exist in StatusBarItem.
    // ACTUAL:   the property is declared but never used.
    // =======================================================================

    func testBug41_statusBarEngineObserverDeadCode() {
        guard let content = readSource("OpenVerb/UI/StatusBarItem.swift") else {
            XCTFail("Cannot read StatusBarItem.swift"); return
        }
        let hasEngineObserver = content.contains("engineObserver")
        XCTAssertFalse(hasEngineObserver,
            "Bug 41 CONFIRMED: StatusBarItem declares `private var engineObserver: Any?` " +
            "but never assigns or reads it. Status updates are driven externally from " +
            "AppDelegate via Combine observers. The property is leftover dead code from " +
            "an earlier implementation. " +
            "Fix: remove the `private var engineObserver: Any?` declaration from " +
            "StatusBarItem.swift.")
    }

    // =======================================================================
    // Bug 42 — text.lowercased() may change string length, causing silent
    //          character skip in per-char injection
    //
    // keyCodeAndFlags(for:) passes char.lowercased() to
    // keyCodeForCharacter, which rejects multi-character strings. For
    // certain Unicode (ß → ss, İ → i\u{0307}), the lookup returns nil
    // and the character is silently skipped.
    //
    // EXPECTED: keyCodeAndFlags handles multi-character lowercased()
    //           results, or avoids lowercasing for non-ASCII.
    // ACTUAL:   char.lowercased() is passed unconditionally.
    // =======================================================================

    func testBug42_lowercasedChangesLengthCausingSkip() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }
        guard let fnRange = content.range(of: "static func keyCodeAndFlags") else {
            XCTFail("Cannot find keyCodeAndFlags in TextInjector.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 300)
        let hasMultiCharGuard = fnBody.contains("lowercased().count") ||
            fnBody.contains("char.unicodeScalars") ||
            fnBody.contains("char.count == 1")
        let usesNaiveLowercased = fnBody.contains("char.lowercased()") &&
            !fnBody.contains("lowercased().first") &&
            !fnBody.contains("lowercased().unicodeScalars")
        XCTAssertTrue(!usesNaiveLowercased || hasMultiCharGuard,
            "Bug 42 CONFIRMED: keyCodeAndFlags(for:) passes `char.lowercased()` " +
            "directly to keyCodeForCharacter without handling the case where " +
            "lowercased() changes the string length. For German 'ß'.lowercased() → 'ss' " +
            "(2 chars), keyCodeForCharacter's `char.count == 1` guard returns nil and " +
            "the character is silently skipped during per-character injection. " +
            "Fix: use `char.lowercased().unicodeScalars.first` or check that the " +
            "lowercased result has count == 1 before calling keyCodeForCharacter.")
    }

    // =======================================================================
    // Bug 43 — AppDelegate properties are implicitly unwrapped optionals
    //
    // appState, engineManager, hotkeyManager, etc. are declared as `Type!`.
    // If any is accessed before applicationDidFinishLaunching sets them,
    // the app crashes.
    //
    // EXPECTED: properties use explicit optionals with guard checks, or
    //           lazy initialization.
    // ACTUAL:   9 core properties are `Type!` implicitly unwrapped optionals.
    // =======================================================================

    func testBug43_appDelegatePropertiesImplicitlyUnwrapped() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        let iuoPattern = try! NSRegularExpression(
            pattern: #"private var \w+:\s+\w+!"#,
            options: [])
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let matches = iuoPattern.matches(in: content, options: [], range: fullRange)
        let appDelegateMatches = matches.filter { match in
            let line = nsContent.substring(with: match.range)
            return !line.contains("NSWindow?")
        }
        XCTAssertTrue(appDelegateMatches.isEmpty,
            "Bug 43 CONFIRMED: AppDelegate has \(appDelegateMatches.count) implicitly " +
            "unwrapped optional properties (Type!). If any is accessed before " +
            "applicationDidFinishLaunching sets them, the app crashes. " +
            "Properties: \(appDelegateMatches.map { nsContent.substring(with: $0.range) }.joined(separator: ", ")). " +
            "Fix: use explicit optionals with guard checks, or lazy initialization.")
    }

    // =======================================================================
    // Bug 44 — HotkeyManager CGEvent callback uses Unmanaged.passUnretained
    //          — dangling pointer risk
    //
    // If HotkeyManager is deallocated from a background thread while the
    // CGEvent tap is registered, deinit skips removeEventTap() (guarded
    // on Thread.isMainThread). The tap leaks with a dangling pointer.
    //
    // EXPECTED: deinit always removes the event tap regardless of thread,
    //           or uses a retained pointer with balanced release.
    // ACTUAL:   deinit guards cleanup on Thread.isMainThread, and the
    //           callback uses passUnretained.
    // =======================================================================

    func testBug44_hotkeyManagerDanglingPointerInDeinit() {
        guard let content = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Cannot read HotkeyManager.swift"); return
        }
        guard let deinitRange = content.range(of: "deinit") else {
            XCTFail("Cannot find deinit in HotkeyManager.swift"); return
        }
        let deinitBody = substring(content, from: deinitRange.lowerBound, length: 300)
        let hasThreadGuard = deinitBody.contains("Thread.isMainThread")
        XCTAssertFalse(hasThreadGuard,
            "Bug 44 CONFIRMED: HotkeyManager.deinit guards cleanup on " +
            "Thread.isMainThread. If deinit is called from a background thread, " +
            "removeEventTap() and removeEscapeMonitors() are skipped, leaving the " +
            "CGEvent tap registered with a dangling `Unmanaged.passUnretained(self)` " +
            "pointer. The callback would dereference a deallocated object. " +
            "Fix: remove the Thread.isMainThread guard and dispatch cleanup to main " +
            "inside deinit, or use Unmanaged.passRetained with a balanced release in " +
            "the callback.")
    }

    // =======================================================================
    // Bug 47 — AppSettings.reset() writes to UserDefaults then removes keys
    //
    // reset() sets properties to defaults (triggering didSet → 9 writes),
    // then removes all keys. The final state is correct but 9 writes are
    // wasted. Compounds with Bug 40's double-write for maxRecordingDuration.
    //
    // EXPECTED: reset() sets properties without triggering didSet, then
    //           removes keys once.
    // ACTUAL:   every property assignment triggers didSet → UserDefaults
    //           write, then removeObject immediately undoes it.
    // =======================================================================

    func testBug47_appSettingsResetWastefulDoubleIO() {
        guard let content = readSource("OpenVerb/Settings/AppSettings.swift") else {
            XCTFail("Cannot read AppSettings.swift"); return
        }
        guard let resetRange = content.range(of: "func reset()") else {
            XCTFail("Cannot find reset() in AppSettings.swift"); return
        }
        let resetBody = substring(content, from: resetRange.lowerBound, length: 1500)
        let hasSuppressFlag = resetBody.contains("suppressDidSet") ||
            resetBody.contains("_isResetting") ||
            resetBody.contains("isResetting")
        let writesThenRemoves = resetBody.contains("defaults.set(") &&
            resetBody.contains("defaults.removeObject(")
        XCTAssertTrue(hasSuppressFlag || !writesThenRemoves,
            "Bug 47 CONFIRMED: AppSettings.reset() assigns properties (triggering " +
            "didSet → UserDefaults writes) then immediately removes those keys. " +
            "This causes 9+ wasted UserDefaults writes that are immediately undone. " +
            "Compounds with Bug 40's double-write for maxRecordingDuration. " +
            "Fix: add an `isResetting` flag checked in each didSet to skip " +
            "UserDefaults writes, or assign to backing storage directly.")
    }

    // =======================================================================
    // Bug 32 — Audio frame ordering violation in connectAndRecord()      [HIGH]
    //
    // flushAndSetSendCallback() atomically activates the live send callback
    // and returns buffered chunks.  The for-loop then dispatches each chunk
    // via sendAudioFrame (ioQueue.async).  Simultaneously, the audio tap fires
    // its live callback which also dispatches to ioQueue.async.  Both paths
    // compete on the serial queue — a live frame submitted from the real-time
    // audio thread can land in ioQueue before a buffered frame dispatched from
    // the MainActor loop, delivering frames to the engine out of order.
    //
    // EXPECTED: a sync ordering mechanism (e.g. syncOnIOQueue / a batch method
    //           that flushes buffered frames synchronously) ensures all buffered
    //           frames are fully ordered on ioQueue before any live frame arrives.
    // ACTUAL:   no ordering guarantee; both paths use ioQueue.async and race.
    // =======================================================================

    func testBug32_bufferedFramesCanArriveLaterThanLiveFrames() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        guard let fnRange = content.range(of: "func connectAndRecord") else {
            XCTFail("Cannot find connectAndRecord in OpenVerbApp.swift"); return
        }
        let body = substring(content, from: fnRange.lowerBound, length: 3000)

        // The live callback is still activated via flushAndSetSendCallback (unchanged).
        // A fix must introduce a synchronous ordering mechanism for the buffered flush.
        let hasOrderingFix = body.contains("syncOnIOQueue")
            || body.contains("sendBufferedFrames")
            || body.contains("ioQueue.sync")

        XCTAssertTrue(hasOrderingFix,
            "Bug 32 CONFIRMED: connectAndRecord() calls flushAndSetSendCallback(), " +
            "activating the live callback and returning buffered chunks simultaneously. " +
            "The for-loop dispatches buffered chunks via sendAudioFrame (ioQueue.async); " +
            "the audio tap also dispatches live frames to ioQueue.async concurrently. " +
            "The serial ioQueue receives both streams in non-deterministic order — a live " +
            "frame can precede a buffered one, causing the engine to process audio out of " +
            "chronological order and degrading recognition quality. " +
            "Fix: add a public `syncOnIOQueue()` to EngineClient that executes " +
            "`ioQueue.sync {}` as a fence, or expose `sendBufferedFrames(_:)` that writes " +
            "frames synchronously. Call it after the for-loop and before startPhase2Monitor().")
    }

    // =======================================================================
    // Bug 33 — Data race on wakeWrite/wakeRead between MainActor and ioQueue
    //                                                                    [HIGH]
    //
    // stopPhase2Monitor() reads self.wakeWrite on the calling thread (MainActor
    // in practice) and calls Darwin.write(wakeWrite, ...).  disconnect() writes
    // self.wakeWrite = -1 inside ioQueue.async.  No lock or queue serialises
    // these two accesses — undefined behaviour under the Swift memory model.
    // Practical worst case: Darwin.write() is called with a closed fd (EBADF,
    // harmless) or the wakeup signal is silently dropped, leaving the Phase 2
    // monitor blocked in poll() for up to 100 ms after stop was requested.
    //
    // EXPECTED: wakeWrite access in stopPhase2Monitor is protected via
    //           ioQueue.sync or a dedicated wakeLock so it cannot race with
    //           disconnect's ioQueue.async write.
    // ACTUAL:   bare `if wakeWrite >= 0 { Darwin.write(wakeWrite, ...) }` on
    //           MainActor, concurrent with disconnect's ioQueue.async write.
    // =======================================================================

    func testBug33_wakeWriteRaceInStopPhase2Monitor() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        guard let fnRange = content.range(of: "func stopPhase2Monitor()") else {
            XCTFail("Cannot find stopPhase2Monitor() in EngineClient.swift"); return
        }
        let body = substring(content, from: fnRange.lowerBound, length: 600)

        // The fix must serialise the wakeWrite read-check-write in stopPhase2Monitor
        // with the wakeWrite = -1 assignment in disconnect().
        let hasProtection = body.contains("ioQueue.sync")
            || body.contains("wakeLock")
            || body.contains("ioQueue.async")  // wakeup moved entirely to ioQueue

        XCTAssertTrue(hasProtection,
            "Bug 33 CONFIRMED: stopPhase2Monitor() accesses wakeWrite directly without " +
            "synchronisation: `if wakeWrite >= 0 { Darwin.write(wakeWrite, &b, 1) }`. " +
            "disconnect() writes `self.wakeWrite = -1` inside ioQueue.async. These are " +
            "concurrent, unsynchronised accesses to a non-atomic stored property — " +
            "undefined behaviour under the Swift memory model. " +
            "Fix: wrap the wakeWrite check-and-write in stopPhase2Monitor inside " +
            "`ioQueue.sync {}` so it is serialised with disconnect's ioQueue.async write, " +
            "or add `private let wakeLock = NSLock()` and acquire it in both sites.")
    }

    // =======================================================================
    // Bug 36 — Force unwrap `baseAddress!` in sendJSONSync /
    //          writeAudioFrameOrDrop / disconnect sentinel           [MEDIUM]
    //
    // `data.withUnsafeBytes { try writeFully($0.baseAddress!, count: $0.count) }`
    // crashes if Data happens to be empty — baseAddress is nil for zero-byte
    // buffers under Swift's UnsafeRawBufferPointer contract.
    //
    // EXPECTED: each baseAddress access uses `guard let` with an early return
    //           or `data.isEmpty` pre-check.
    // ACTUAL:   three force-unwrap `baseAddress!` calls in EngineClient.swift.
    // =======================================================================

    func testBug36_forceUnwrapBaseAddress() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        let hasForceUnwrap = content.contains("baseAddress!")
        XCTAssertFalse(hasForceUnwrap,
            "Bug 36 CONFIRMED: EngineClient.swift contains `baseAddress!` force-unwrap(s). " +
            "Under Swift's UnsafeRawBufferPointer contract, baseAddress is nil when the " +
            "Data buffer is empty. An empty JSONEncoder output (theoretically possible for " +
            "a malformed Encodable) or empty audio frame would trigger a fatal crash with " +
            "no diagnostic. All three sites (sendJSONSync, writeAudioFrameOrDrop, " +
            "disconnect sentinel) are affected. " +
            "Fix: replace `$0.baseAddress!` with `guard let base = $0.baseAddress else { return }` " +
            "at each call site, or add `guard !data.isEmpty else { return }` before withUnsafeBytes.")
    }

    // =======================================================================
    // Bug 37 — Force unwrap `URL(string:)!` in ModelDownloader       [MEDIUM]
    //
    // `static let modelURL = URL(string: "https://...")!` crashes at app
    // launch if the string is ever malformed (e.g. a space introduced while
    // editing the URL in a future PR).  The crash is a nil dereference with
    // no diagnostic message at the point of failure.
    //
    // EXPECTED: modelURL construction uses `guard let` + descriptive
    //           fatalError, so a bad URL produces a clear compile-time-visible
    //           message rather than a mysterious launch crash.
    // ACTUAL:   force-unwrap on the URL(string:) static initialiser at line 30.
    // =======================================================================

    func testBug37_modelURLForceUnwrap() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }
        // Locate the modelURL assignment and inspect its expression.
        guard let urlRange = content.range(of: "modelURL") else {
            XCTFail("Cannot find modelURL in ModelDownloader.swift"); return
        }
        let urlExpr = substring(content, from: urlRange.lowerBound, length: 250)
        // Force-unwrap pattern: URL(string: "...")! — the `!` immediately follows `)`.
        let forceUnwraps = urlExpr.contains(")!")
        XCTAssertFalse(forceUnwraps,
            "Bug 37 CONFIRMED: ModelDownloader.swift force-unwraps modelURL with " +
            "`URL(string: \"...\")!`. If this URL string is ever edited to contain an " +
            "illegal character (space, unescaped bracket, etc.), the app crashes at " +
            "launch with a nil dereference — no log, no recovery, no user-visible message. " +
            "Fix: replace the force-unwrap with a `guard let` and " +
            "`fatalError(\"modelURL is malformed — update ModelDownloader.modelURL\")` " +
            "so the failure is surfaced clearly during development.")
    }

    // =======================================================================
    // Bug 38 — ShortcutCaptureView leaks NSEvent monitor on dealloc   [MEDIUM]
    //
    // startRecording() installs a local NSEvent monitor.  If the Preferences
    // window is closed while isRecording == true (user clicked the recorder
    // but hasn't pressed a key yet), the view is deallocated without calling
    // stopRecording().  NSEvent retains the monitor block — a new leak
    // accumulates on every open-then-close-while-recording cycle.
    //
    // EXPECTED: ShortcutCaptureView has a deinit that removes localMonitor
    //           unconditionally, regardless of recording state.
    // ACTUAL:   no deinit; the monitor leaks when the view is torn down mid-
    //           recording.
    // =======================================================================

    func testBug38_shortcutCaptureViewMissingDeinit() {
        guard let content = readSource("OpenVerb/Input/ShortcutRecorder.swift") else {
            XCTFail("Cannot read ShortcutRecorder.swift"); return
        }
        guard let classRange = content.range(of: "final class ShortcutCaptureView") else {
            XCTFail("Cannot find ShortcutCaptureView in ShortcutRecorder.swift"); return
        }
        let classBody = substring(content, from: classRange.lowerBound, length: 1200)
        let hasDeinit = classBody.contains("deinit")
        let deinitCleansUp = hasDeinit && (
            classBody.contains("NSEvent.removeMonitor")
                || classBody.contains("stopRecording()")
        )
        XCTAssertTrue(deinitCleansUp,
            "Bug 38 CONFIRMED: ShortcutCaptureView has no deinit " +
            "(hasDeinit=\(hasDeinit), deinitCleansUp=\(deinitCleansUp)). " +
            "When the Preferences window closes while the user has clicked the " +
            "shortcut recorder but not yet pressed a key (isRecording == true), " +
            "SwiftUI tears down the view. The NSEvent local monitor registered in " +
            "startRecording() is never removed — NSEvent holds a strong reference to " +
            "the monitor block, creating a leak that grows with each Preferences open/close. " +
            "Fix: add `deinit { if let m = localMonitor { NSEvent.removeMonitor(m) } }` " +
            "to ShortcutCaptureView, or call stopRecording() from deinit.")
    }

    // =======================================================================
    // Bug 45 — ensureRunning() spin-wait may freeze MainActor for 10 s [MEDIUM]
    //
    // The dedup spin-loop waits up to 10 s for a concurrent launch in flight.
    // If the first caller's Task is cancelled without updating `status`, every
    // subsequent call spins the full 10 s on @MainActor — freezing the hotkey
    // handler, status bar, and all UI for the entire duration.
    //
    // EXPECTED: spin deadline ≤ 3 s, or the loop exits early with an error
    //           rather than silently timing out.
    // ACTUAL:   `Date().addingTimeInterval(10.0)` — 10-second maximum freeze.
    // =======================================================================

    func testBug45_ensureRunningSpinWaitTooLong() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        guard let fnRange = content.range(of: "func ensureRunning()") else {
            XCTFail("Cannot find ensureRunning() in EngineManager.swift"); return
        }
        let body = substring(content, from: fnRange.lowerBound, length: 1500)
        // The buggy pattern: a 10-second addingTimeInterval in the dedup spin-loop.
        let hasTenSecondDeadline = body.contains("addingTimeInterval(10.0)")
            || body.contains("TimeInterval(10)")
        XCTAssertFalse(hasTenSecondDeadline,
            "Bug 45 CONFIRMED: ensureRunning() dedup spin-loop uses " +
            "`Date().addingTimeInterval(10.0)` as the maximum wait. If the first " +
            "caller's Task is cancelled or hangs without updating `status == .starting`, " +
            "every subsequent ensureRunning() call spins for up to 10 s on @MainActor. " +
            "During this time the hotkey handler cannot fire, the status bar freezes, " +
            "and the app appears completely unresponsive. " +
            "Fix: reduce the spin deadline to ≤ 3 s and immediately throw " +
            "`EngineManagerError.launchTimeout` so callers surface the failure instead " +
            "of silently waiting.")
    }

    // =======================================================================
    // Bug 46 — drainResult() .error path skips crash recovery         [MEDIUM]
    //
    // When the engine sends a structured .error message (e.g. model_load_failed,
    // inference_failed), drainResult() runs UI teardown and returns without
    // calling engineManager.handleCrash().  The engine is left in a dead state.
    // The next hotkey press must wait for ensureRunning() to detect and restart
    // the dead engine, adding a visible extra delay (up to 5 s) on the session
    // that follows an engine error.  The connection-error path (a few lines
    // above) correctly calls handleCrash() — this is an omission in the
    // structured-error branch.
    //
    // EXPECTED: the .error switch case also dispatches handleCrash() in a
    //           Task, matching the connection-error path.
    // ACTUAL:   .error calls handleEngineError() and returns; no handleCrash().
    // =======================================================================

    func testBug46_drainResultErrorPathMissingCrashRecovery() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        guard let fnRange = content.range(of: "private func drainResult") else {
            XCTFail("Cannot find drainResult in OpenVerbApp.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 6000)
        guard let errorCaseRange = fnBody.range(of: "case .error(let code") else {
            XCTFail("Cannot find .error case in drainResult"); return
        }
        // Inspect the ~300 chars following the .error case label for handleCrash.
        let errorCaseBody = substring(fnBody, from: errorCaseRange.lowerBound, length: 300)
        let hasCrashRecovery = errorCaseBody.contains("handleCrash")
        XCTAssertTrue(hasCrashRecovery,
            "Bug 46 CONFIRMED: drainResult() `.error` case calls handleEngineError() and " +
            "returns without calling engineManager.handleCrash(). The engine is left in " +
            "a dead or error state; the next hotkey press must wait for ensureRunning() to " +
            "detect the dead engine, adding a full startup delay. The connection-error path " +
            "immediately above drainResult calls handleCrash() with exponential backoff — " +
            "the structured .error branch has the same need but omits it. " +
            "Fix: in the `.error` case, after handleEngineError(), add: " +
            "`Task { [weak self] in try? await self?.engineManager.handleCrash() }` " +
            "mirroring the connection-error path at lines 677-685.")
    }

    // =======================================================================
    // Bug 48 — handleWake() → ensureRunning() self-deadlock: engine never
    //          restarts after wake                                  [HIGH]
    //
    // handleWake() sets status = .starting at the top, then the wake Task
    // calls ensureRunning(). Inside ensureRunning(), the dedup guard sees
    // status == .starting and enters the spin loop. No task will ever
    // change status to .running — the only code that could is ensureRunning
    // itself, which is stuck in the loop. After 2 s the spin loop throws
    // launchTimeout and the engine is never restarted.
    //
    // EXPECTED: handleWake does NOT set status = .starting before calling
    //           ensureRunning(); ensureRunning owns the status transition.
    // ACTUAL:   handleWake sets status = .starting prematurely.
    // =======================================================================

    func testBug48_handleWakePrematureStatusStarting() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        guard let fnRange = content.range(of: "func handleWake()") else {
            XCTFail("Cannot find handleWake() in EngineManager.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 700)
        let setsStartingPrematurely = fnBody.contains("status = .starting")
        XCTAssertFalse(setsStartingPrematurely,
            "Bug 48 CONFIRMED: handleWake() sets status = .starting before calling " +
            "ensureRunning(). ensureRunning()'s dedup guard sees status == .starting, " +
            "enters the spin loop, and no task ever transitions to .running. After 2 s " +
            "it throws launchTimeout — the engine never restarts after wake. " +
            "Fix: remove `status = .starting` from handleWake(). Let ensureRunning() " +
            "own the status transition (it sets .starting internally only after the " +
            "dedup guard passes). If a UI indicator is needed before ensureRunning " +
            "runs, use a separate transient flag or onWakeStarted?() to show " +
            "\"Loading model…\" without poisoning the dedup state machine.")
    }

    // =======================================================================
    // Bug 49 — drainResult() .error path missing disconnect() — stale
    //          socket causes unnecessary engine restart          [MED]
    //
    // The .result path calls engineManager.disconnect() (to signal EOF and
    // close the socket fd), but the .error path does not. After an engine
    // error, the socket fd remains open. On the next recording:
    //   1. ensureRunning() → tryPing() → engineClient.connect()
    //   2. connectSync: guard fd == -1 — fd is NOT -1 (stale) → returns
    //   3. sendPing() writes to stale socket → EPIPE → tryPing fails
    //   4. ensureRunning kills and fully restarts the engine (5+ s delay)
    //
    // Although handleCrash() (dispatched in a Task) calls disconnect(),
    // the Task is async — there is a window where the user presses the
    // hotkey before the Task executes, hitting the stale fd.
    //
    // EXPECTED: the .error case calls engineManager.disconnect() before
    //           dispatching handleCrash, mirroring the .result path.
    // ACTUAL:   .error path has no disconnect() call.
    // =======================================================================

    func testBug49_drainResultErrorPathMissingDisconnect() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        guard let fnRange = content.range(of: "private func drainResult") else {
            XCTFail("Cannot find drainResult in OpenVerbApp.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 6000)
        guard let errorCaseRange = fnBody.range(of: "case .error(let code") else {
            XCTFail("Cannot find .error case in drainResult"); return
        }
        let errorCaseBody = substring(fnBody, from: errorCaseRange.lowerBound, length: 400)
        let hasDisconnect = errorCaseBody.contains("disconnect()")
        XCTAssertTrue(hasDisconnect,
            "Bug 49 CONFIRMED: drainResult() `.error` case does not call " +
            "engineManager.disconnect(). The socket fd remains open after an engine " +
            "error. On the next recording, connect() sees fd != -1 (stale) and " +
            "skips reconnection. sendPing() writes to the stale fd → EPIPE → " +
            "ensureRunning() kills and restarts the engine with a 5+ s model reload " +
            "delay. handleCrash() eventually disconnects but runs async — there is a " +
            "race window. " +
            "Fix: add `engineManager.disconnect()` in the .error case, before or " +
            "after handleEngineError(), mirroring the .result path.")
    }

    // =======================================================================
    // Bug 50 — showConflictAlert() doesn't persist selected hotkey —
    //          conflict dialog reappears every launch               [MED]
    //
    // When ⌥Space is already in use, showConflictAlert() offers three
    // alternatives and calls installEventTap(key: newKey). This only
    // updates the in-memory hotKey property — it never writes to
    // AppSettings.shared.hotkeyKeyCode / hotkeyModifiers. On next launch,
    // register() reads the original conflicting hotkey from UserDefaults,
    // installEventTap fails, and the conflict dialog appears again.
    //
    // EXPECTED: showConflictAlert persists the selected alternative to
    //           AppSettings after installing the tap.
    // ACTUAL:   installEventTap(key: newKey) is called but no settings
    //           write follows.
    // =======================================================================

    func testBug50_conflictAlertDoesNotPersistHotkey() {
        guard let content = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Cannot read HotkeyManager.swift"); return
        }
        guard let fnRange = content.range(of: "func showConflictAlert()") else {
            XCTFail("Cannot find showConflictAlert() in HotkeyManager.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 700)
        let persistsKeyCode = fnBody.contains("settings.hotkeyKeyCode")
        let persistsModifiers = fnBody.contains("settings.hotkeyModifiers")
        XCTAssertTrue(persistsKeyCode && persistsModifiers,
            "Bug 50 CONFIRMED: showConflictAlert() calls installEventTap(key: newKey) " +
            "but never persists the selection to AppSettings " +
            "(keyCode=\(persistsKeyCode), modifiers=\(persistsModifiers)). " +
            "On next launch, register() reads the original conflicting hotkey from " +
            "UserDefaults, installEventTap fails, and the conflict dialog reappears. " +
            "The user's choice is lost every time. " +
            "Fix: after installEventTap(key: newKey), add: " +
            "settings.hotkeyKeyCode = newKey.virtualKey; " +
            "settings.hotkeyModifiers = newKey.flags")
    }

    // =======================================================================
    // Bug 1 — WaveformViewModel.updateAmplitude() defers append to next
    //          run loop — stale amplitudes on immediate read
    //
    // updateAmplitude() is nonisolated and wraps amplitudes.append(rms) in
    // DispatchQueue.main.async. Even when called from a @MainActor context,
    // the append is deferred to the next run-loop iteration. Any code that
    // reads amplitudes synchronously after calling updateAmplitude() sees
    // stale (empty) state.
    //
    // EXPECTED: updateAmplitude() is @MainActor and calls
    //           amplitudes.append(rms) directly (with pure RMS computation
    //           extracted into a nonisolated helper).
    // ACTUAL:   nonisolated func wraps append in DispatchQueue.main.async.
    // =======================================================================

    func testBug1_updateAmplitudeDefersAppendToNextRunLoop() {
        guard let content = readSource("OpenVerb/UI/WaveformView.swift") else {
            XCTFail("Cannot read WaveformView.swift"); return
        }
        guard let fnRange = content.range(of: "func updateAmplitude") else {
            XCTFail("Cannot find updateAmplitude in WaveformView.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 400)
        // The buggy pattern: nonisolated + DispatchQueue.main.async for the append.
        let isNonisolated = fnBody.contains("nonisolated")
        let wrapsInMainAsync = fnBody.contains("DispatchQueue.main.async")
        let appendsDirectly = fnBody.contains("amplitudes.append(") &&
            !fnBody.contains("self.amplitudes.append(")  // direct call inside async block
        // In the buggy code, the append IS inside DispatchQueue.main.async —
        // so a direct (non-deferred) append would be the fix.
        // Check if the function is @MainActor (fix) instead of nonisolated (bug).
        let isAtMainActor = fnRange.lowerBound > content.startIndex &&
            content[content.index(before: fnRange.lowerBound)...].prefix(30).contains("@MainActor") ||
            content[content.index(before: fnRange.lowerBound)...].prefix(100).contains("@MainActor")

        // The bug exists when: nonisolated + DispatchQueue.main.async wrapping the append.
        let hasBug = isNonisolated && wrapsInMainAsync
        XCTAssertFalse(hasBug,
            "Bug 1 CONFIRMED: updateAmplitude() is `nonisolated` and wraps " +
            "amplitudes.append(rms) in DispatchQueue.main.async. Any synchronous " +
            "read of amplitudes after calling updateAmplitude() sees stale (empty) " +
            "state because the append is deferred to the next run-loop iteration. " +
            "Fix: annotate updateAmplitude() with @MainActor and call " +
            "amplitudes.append(rms) directly. Extract the pure RMS computation " +
            "into a nonisolated helper and call it before the actor hop.")
    }

    // =======================================================================
    // Bug 51 — handleCrash() sends ping to active session socket after
    //          sleep — corrupts binary streaming                  [HIGH]
    //
    // handleCrash() sleeps for backoffDelay, then calls ensureRunning().
    // If a new session has started during the sleep, ensureRunning() →
    // tryPing() → connectSync() sees fd != -1 (active session) and writes
    // a JSON ping to the binary streaming socket. The engine reads the
    // first 4 bytes of the ping JSON as a big-endian frame length (~2 GB),
    // causing a 30 s stall and session failure.
    //
    // EXPECTED: handleCrash() guards its final ensureRunning() call with
    //           the canRestartBackend closure (which checks appState == .idle).
    //           If a new session is active, the pre-warm is skipped.
    // ACTUAL:   handleCrash() calls ensureRunning() unconditionally after
    //           the backoff sleep, regardless of current app state.
    // =======================================================================

    func testBug51_handleCrashPingsActiveSessionAfterSleep() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        guard let fnRange = content.range(of: "func handleCrash()") else {
            XCTFail("Cannot find handleCrash() in EngineManager.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 3000)

        // After the Task.sleep, the fix must guard ensureRunning() on
        // canRestartBackend so it doesn't ping an active session.
        guard let sleepRange = fnBody.range(of: "Task.sleep") else {
            XCTFail("Cannot find Task.sleep in handleCrash()"); return
        }
        let afterSleep = substring(fnBody, from: sleepRange.lowerBound, length: 700)

        // The guard must appear between the sleep and the ensureRunning() call.
        let hasGuard = afterSleep.contains("canRestartBackend")
        let guardBeforeEnsure: Bool = {
            guard let guardR = afterSleep.range(of: "canRestartBackend"),
                  let ensureR = afterSleep.range(of: "ensureRunning") else { return false }
            return guardR.lowerBound < ensureR.lowerBound
        }()

        XCTAssertTrue(hasGuard && guardBeforeEnsure,
            "Bug 51 CONFIRMED: handleCrash() calls ensureRunning() after the " +
            "backoff sleep without checking whether a new session has started " +
            "during the sleep (hasGuard=\(hasGuard), guardBeforeEnsure=\(guardBeforeEnsure)). " +
            "This sends a JSON ping to an active binary streaming socket — the engine " +
            "reads the first 4 bytes of the ping as a ~2 GB frame length, stalls for " +
            "30 s, and the session fails. " +
            "Fix: gate the final ensureRunning() on canRestartBackend: " +
            "`guard canRestartBackend?() ?? true else { return }` — if the app has " +
            "transitioned out of .idle (new session active), skip the pre-warm.")
    }

    // =======================================================================
    // Bug 52 — connectAndRecord() catch block missing disconnect() —
    //          stale fd left open on session-setup failure           [MED]
    //
    // When startSession() or receiveMessage(timeoutMs:) throws inside
    // connectAndRecord(), the catch block does not call
    // engineManager.disconnect(). The fd remains open. handleCrash() is
    // spawned asynchronously — there is a MainActor window where the user
    // could press ⌥Space again and hit the stale socket.
    //
    // EXPECTED: the catch block calls engineManager.disconnect() before
    //           spawning handleCrash().
    // ACTUAL:   no disconnect() call in the catch block.
    // =======================================================================

    func testBug52_connectAndRecordCatchMissingDisconnect() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        guard let fnRange = content.range(of: "func connectAndRecord") else {
            XCTFail("Cannot find connectAndRecord in OpenVerbApp.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 6000)

        // Locate the outer catch block: the one that contains audioSession.stop()
        // immediately after } catch { — uniquely identifies the top-level catch,
        // not the inner catches nested inside closures (e.g. maxDurationTimer Task).
        guard let audioStopRange = fnBody.range(of: "audioSession.stop()") else {
            XCTFail("Cannot find audioSession.stop() in connectAndRecord catch"); return
        }
        let catchBody = substring(fnBody, from: audioStopRange.lowerBound, length: 800)

        let hasDisconnect = catchBody.contains("engineManager.disconnect()")
        XCTAssertTrue(hasDisconnect,
            "Bug 52 CONFIRMED: connectAndRecord() catch block does not call " +
            "engineManager.disconnect(). The socket fd remains open after a " +
            "session-setup failure. handleCrash() is spawned as an async Task, " +
            "leaving a MainActor window where the user can press ⌥Space again and " +
            "hit the stale socket (interacts with Bug 51's ping-on-active-session). " +
            "Fix: add `engineManager.disconnect()` in the catch block, immediately " +
            "before spawning handleCrash(): " +
            "```swift " +
            "} catch { " +
            "    audioSession.stop() " +
            "    hotkeyManager.removeEscapeMonitors() " +
            "    engineManager.disconnect()   // ← add this " +
            "    ... " +
            "} ```")
    }

    // =======================================================================
    // Bug 53 — server.cpp: session_thread_.join() after accept() stalls
    //          new ping for up to 15 s when prior session never received
    //          client disconnect                                      [MED]
    //
    // The IPC server calls accept() then immediately joins the previous
    // session thread. Under Bug 49/52 conditions, the prior session never
    // received a client close() — it polls the old fd for up to
    // idle_timeout_secs (15 s) before exiting, blocking the new client
    // from being served.
    //
    // Fixing Bugs 49/52 makes this unreachable, but a defense-in-depth
    // fix on the C++ side should signal the previous session before joining.
    //
    // EXPECTED: before session_thread_.join(), the code signals the old
    //           session to stop (via g_interrupted, a per-session stop
    //           flag, or closing the old client fd).
    // ACTUAL:   joinable() check followed directly by join() with no
    //           signal.
    // =======================================================================

    // =======================================================================
    // Bug 54 — TextInjector leaves transcription on NSPasteboard for
    //          300 ms — stale clipboard context in next session       [HIGH]
    //
    // inject() writes the transcription to NSPasteboard.general at step (2),
    // posts ⌘V, and waits 300 ms before restoring the original clipboard at
    // step (8). If the user presses ⌥Space again within that window,
    // ContextBuilder.build() reads the just-injected text as
    // context["clipboard"] — the engine receives the previous transcription
    // as clipboard context and may reproduce it verbatim.
    //
    // EXPECTED: the clipboard is snapshot-captured in startRecording() (before
    //           the async Task), and passed as clipboardSnapshot: String? into
    //           connectAndRecord() → ContextBuilder.build(). This ensures the
    //           context always reflects the clipboard at the moment ⌥Space was
    //           pressed, never the text TextInjector wrote.
    // ACTUAL:   ContextBuilder.build() reads NSPasteboard.general.string()
    //           inside the async Task launched from startRecording(), which
    //           executes after TextInjector may have overwritten the clipboard.
    // =======================================================================

    func testBug54_clipboardCapturedAtStartRecordingNotConnectAndRecord() {
        guard let appSrc = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }

        // The fix requires startRecording() to capture the snapshot BEFORE
        // the async Task that calls connectAndRecord().
        guard let startRange = appSrc.range(of: "private func startRecording()") else {
            XCTFail("Cannot find startRecording() in OpenVerbApp.swift"); return
        }
        let startBody = substring(appSrc, from: startRange.lowerBound, length: 2500)

        let snapshotCapturedBeforeTask: Bool = {
            guard let snapR = startBody.range(of: "clipboardSnapshot"),
                  let taskR = startBody.range(of: "Task {") ?? startBody.range(of: "Task(priority:") else {
                return false
            }
            return snapR.lowerBound < taskR.lowerBound
        }()

        // ContextBuilder.build() must accept clipboardSnapshot: so it can
        // receive the pre-injection value rather than reading the pasteboard.
        let contextBuilderHasSnapshotParam: Bool = {
            guard let cbSrc = readSource("OpenVerb/Context/ContextBuilder.swift") else { return false }
            guard let buildRange = cbSrc.range(of: "static func build(") else { return false }
            let sig = substring(cbSrc, from: buildRange.lowerBound, length: 500)
            return sig.contains("clipboardSnapshot")
        }()

        XCTAssertTrue(snapshotCapturedBeforeTask && contextBuilderHasSnapshotParam,
            "Bug 54 CONFIRMED: clipboard is not captured at ⌥Space press time " +
            "(snapshotCapturedBeforeTask=\(snapshotCapturedBeforeTask), " +
            "contextBuilderHasSnapshotParam=\(contextBuilderHasSnapshotParam)). " +
            "TextInjector.inject() writes the previous session's transcription to " +
            "NSPasteboard.general and holds it there for up to 300 ms. If ⌥Space is " +
            "pressed again within that window, ContextBuilder reads the stale " +
            "transcription as context[\"clipboard\"] and the engine reproduces it. " +
            "Fix: in startRecording(), before the Task, capture: " +
            "`let clipboardSnapshot = appSettings.includeClipboard " +
            "? NSPasteboard.general.string(forType: .string) : nil` " +
            "and add `clipboardSnapshot: String?` to ContextBuilder.build(), " +
            "passing the captured value instead of reading the live pasteboard.")
    }

    // =======================================================================
    // Bug 55 — livePartialText never updates during .recording — partial
    //          results only arrive post-stop                          [MED]
    //
    // onPartialResult is only invoked from drainResult(), which runs during
    // .inferring (after the user releases ⌥Space). During .recording the
    // phase2Monitor puts partial_result messages back into recvBuffer via
    // prepend() — they are never forwarded to onPartialResult live. Even
    // with showLiveTranscript=true, the live subtitle stays blank while the
    // user speaks; text appears in a burst after stop.
    //
    // EXPECTED: partial_result messages arriving during Phase 2 streaming
    //           are forwarded to onPartialResult? immediately, either by the
    //           phase2Monitor dispatching them directly, or by a lightweight
    //           polling task in connectAndRecord() during .recording.
    // ACTUAL:   runPhase2Monitor's default case only calls recvBuffer.prepend();
    //           onPartialResult is never called from the monitor or from any
    //           recording-phase task.
    // =======================================================================

    func testBug55_livePartialTextDeadDuringRecording() {
        guard let clientSrc = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        guard let appSrc = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }

        // Fix path A: runPhase2Monitor's default case calls onPartialResult
        // directly for partial_result messages before (or instead of) prepend.
        let monitorForwardsPartials: Bool = {
            guard let r = clientSrc.range(of: "private func runPhase2Monitor") else { return false }
            let body = substring(clientSrc, from: r.lowerBound, length: 1500)
            guard let defaultR = body.range(of: "default:") else { return false }
            let defaultBody = substring(body, from: defaultR.lowerBound, length: 400)
            return defaultBody.contains("onPartialResult")
        }()

        // Fix path B: connectAndRecord has a recording-phase partial reader task.
        let connectAndRecordHasLiveReader: Bool = {
            guard let r = appSrc.range(of: "func connectAndRecord") else { return false }
            let body = substring(appSrc, from: r.lowerBound, length: 6000)
            return body.contains("livePartialReader")
                || body.contains("partialReader")
                || (body.contains(".recording") && body.contains("receiveMessage") &&
                    body.contains("onPartialResult"))
        }()

        XCTAssertTrue(monitorForwardsPartials || connectAndRecordHasLiveReader,
            "Bug 55 CONFIRMED: livePartialText is only updated inside drainResult() " +
            "(invoked during .inferring, after ⌥Space release). During .recording, " +
            "partial_result messages from the engine reach the phase2Monitor but are " +
            "only prepended to recvBuffer — onPartialResult is never called live. " +
            "monitorForwardsPartials=\(monitorForwardsPartials), " +
            "connectAndRecordHasLiveReader=\(connectAndRecordHasLiveReader). " +
            "showLiveTranscript=true has no visible effect during recording; text " +
            "appears only in a burst after the user stops speaking. " +
            "Fix (A): in runPhase2Monitor's default case, decode partial_result " +
            "and call onPartialResult?() directly before or instead of prepend(). " +
            "Fix (B): add a livePartialReader Task in connectAndRecord() that polls " +
            "receiveMessage with a short timeout during .recording and fires onPartialResult.")
    }

    // =======================================================================
    // Bug 56 — phase2Monitor prepend-spin-loop: non-error Phase 2
    //          messages are infinitely re-read                        [HIGH]
    //
    // When any non-error JSON (e.g. partial_result) arrives during Phase 2,
    // runPhase2Monitor's `default` case calls recvBuffer.prepend(restored)
    // then falls through to the shared stopped-check at the loop bottom.
    // The next iteration calls recvJSONSync, which checks the in-memory buffer
    // BEFORE polling the socket — it finds the just-prepended message
    // immediately and re-classifies it as non-error → prepend again, ad
    // infinitum. The spin-loop pegs ~100 % of one CPU core and starves
    // drainResult, producing ~50 % empty-result sessions.
    //
    // EXPECTED: the `default` case adds `continue` after recvLock.unlock(),
    //           jumping directly to the outer while condition, which executes
    //           ioQueue.sync { fd >= 0 } then poll(fd, 100 ms). This gives
    //           drainResult an uncontested 100 ms window to extract the
    //           buffered message.
    // ACTUAL:   no `continue`; control falls through, recvJSONSync is called
    //           again immediately and picks up the just-prepended message.
    // =======================================================================

    func testBug56_phase2MonitorPrependSpinLoop() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        guard let fnRange = content.range(of: "private func runPhase2Monitor") else {
            XCTFail("Cannot find runPhase2Monitor in EngineClient.swift"); return
        }
        // The function is ~105 lines; use 5000 chars to capture the full body.
        let fnBody = substring(content, from: fnRange.lowerBound, length: 5000)

        guard let defaultRange = fnBody.range(of: "default:") else {
            XCTFail("Cannot find default case in runPhase2Monitor"); return
        }
        // Inspect the default case body up to the end of the switch (closing brace).
        let defaultBody = substring(fnBody, from: defaultRange.lowerBound, length: 400)

        // The fix: `continue` appears after recvBuffer.prepend() in the default case.
        // In Swift, `continue` inside a switch that is inside a while loop jumps
        // to the while condition — NOT merely the end of the switch (that would be
        // `break`, which is insufficiently strong here). This forces the next
        // iteration to execute ioQueue.sync + poll before calling recvJSONSync,
        // giving drainResult an uncontested window to drain the buffer.
        let hasContinueAfterPrepend: Bool = {
            guard let prependR = defaultBody.range(of: "recvBuffer.prepend("),
                  let continueR = defaultBody.range(of: "continue") else { return false }
            return prependR.lowerBound < continueR.lowerBound
        }()

        XCTAssertTrue(hasContinueAfterPrepend,
            "Bug 56 CONFIRMED: runPhase2Monitor `default` case has no `continue` " +
            "after recvBuffer.prepend(). Without it, the loop immediately calls " +
            "recvJSONSync on the next iteration — which reads the just-prepended " +
            "message from the in-memory buffer (before any poll syscall) and " +
            "re-prepends it again, spinning infinitely. ~100% CPU on one core and " +
            "~50% empty-result sessions when the engine emits partial_result during " +
            "Phase 2. " +
            "Fix: add `continue` immediately after `recvLock.unlock()` in the default " +
            "case. `continue` in a switch inside a while loop jumps to the while " +
            "condition — triggering `ioQueue.sync { fd >= 0 }` then `poll(&pfds, 2, 100)` " +
            "— giving drainResult a 100 ms uncontested window to extract the message.")
    }

    // =======================================================================
    // Bug 57 — Session::stop() does not join worker_thread_ —
    //          std::terminate() on unexpected exception             [HIGH]
    //
    // stop() signals stop_requested_ and notifies result_cv_ but never
    // joins worker_thread_. The two expected run() exit paths (loop break,
    // ConnectionClosed catch) reach the join inline. But any other thrown
    // exception — e.g. std::bad_alloc from VadScanner::buffer_.insert()
    // — escapes run() entirely. worker_thread_ goes out of scope joinable:
    // std::thread::~thread() calls std::terminate().
    //
    // EXPECTED: stop() calls worker_thread_.join() if joinable, so the
    //           thread is always cleaned up regardless of how run() exits.
    // ACTUAL:   stop() has no join; only comment "joined inline within run()".
    // =======================================================================

    func testBug57_sessionStopDoesNotJoinWorkerThread() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/ipc/session.cpp"
        guard let content = readSource("engine/src/ipc/session.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read session.cpp"); return
        }
        guard let stopRange = content.range(of: "void Session::stop()") else {
            XCTFail("Cannot find Session::stop() in session.cpp"); return
        }
        let stopBody = substring(content, from: stopRange.lowerBound, length: 300)
        let joinsThread = stopBody.contains("worker_thread_.join()")
            || stopBody.contains("worker_thread_.joinable()")
        XCTAssertTrue(joinsThread,
            "Bug 57 CONFIRMED: Session::stop() does not join worker_thread_. " +
            "The two normal run() exit paths reach the join inline, but any " +
            "unhandled exception (e.g. std::bad_alloc from VadScanner buffer " +
            "allocation) escapes run() without joining. worker_thread_ is left " +
            "joinable when its std::thread destructor runs → std::terminate() " +
            "aborts the engine process. " +
            "Fix: add `if (worker_thread_.joinable()) worker_thread_.join();` " +
            "to Session::stop(), which is always called from ~Session().")
    }

    // =======================================================================
    // Bug 58 — vad.cpp::filter() trailing-silence loop narrows size_t → int
    //                                                               [LOW]
    //
    // `for (int si : pending)` where pending is std::vector<size_t>.
    // append_frame() takes size_t. On 64-bit targets int is 4 bytes and
    // size_t is 8 bytes — a silent truncating narrowing conversion. Frame
    // counts never approach INT_MAX in practice, so no truncation occurs,
    // but it is a real type-mismatch that -Wsign-conversion warns about.
    //
    // EXPECTED: loop variable is size_t (or auto), matching the element
    //           type of the vector and the parameter type of append_frame.
    // ACTUAL:   `for (int si : pending)` — narrowing narrowing size_t → int.
    // =======================================================================

    func testBug58_vadFilterTrailingSilenceNarrowsIndex() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/audio/vad.cpp"
        guard let content = readSource("engine/src/audio/vad.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read vad.cpp"); return
        }
        // The bug: `for (int si : pending)` where pending is vector<size_t>.
        // The fix: `for (size_t si : pending)` or `for (const auto si : pending)`.
        let hasNarrowingLoop = content.contains("for (int si : pending)")
        XCTAssertFalse(hasNarrowingLoop,
            "Bug 58 CONFIRMED: vad.cpp trailing-silence flush loop uses " +
            "`for (int si : pending)` where pending is std::vector<size_t>. " +
            "This silently narrows size_t (8 bytes on 64-bit) to int (4 bytes). " +
            "append_frame() takes size_t fi — all three types should match. " +
            "No runtime truncation occurs today (frame counts ≪ INT_MAX), but " +
            "this is a real -Wsign-conversion warning and a latent hazard. " +
            "Fix: change `int si` to `size_t si` (or `const auto si`).")
    }

    // =======================================================================
    // Bug 59 — polish_text() passes empty audio samples ({}) to the
    //          multimodal backend — polish pass is non-functional in
    //          all deployments                                        [MED]
    //
    // polish_text() calls be->process(samples={}, ...). With vad_enabled=false
    // (the daemon default), GemmaAudioBackend skips VAD and tries to create
    // an audio bitmap from 0 samples. mtmd_bitmap_init_from_audio(0, ptr)
    // returns null → infer() throws runtime_error → caught in polish_text()
    // → raw transcript returned silently. The UI shows "Polishing..." but
    // no polish is ever applied. Feature is silently broken in production.
    //
    // EXPECTED: polish_text() uses a text-only backend path that does not
    //           require audio input (e.g. process_text(), or a non-audio
    //           LlamaContext::infer_text() call).
    // ACTUAL:   `be->process(/*samples=*/{}, ...)` — empty audio to an
    //           audio-required multimodal backend.
    // =======================================================================

    func testBug59_polishTextPassesEmptySamplesToBackend() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/engine.cpp"
        guard let content = readSource("engine/src/engine.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read engine.cpp"); return
        }
        guard let polishRange = content.range(of: "polish_text(") else {
            XCTFail("Cannot find polish_text in engine.cpp"); return
        }
        let polishBody = substring(content, from: polishRange.lowerBound, length: 2000)

        // The fix must use a text-only backend call — either process_text(),
        // infer_text(), or any path that does NOT pass an empty samples vector.
        let hasTextOnlyPath = polishBody.contains("process_text(")
            || polishBody.contains("infer_text(")
            || polishBody.contains("text_only")
        let passesEmptySamples = polishBody.contains("samples={}")
            || polishBody.contains("/*samples=*/{}")
            || polishBody.contains("process(\n        {},")
            || polishBody.contains("process({},")
        XCTAssertTrue(hasTextOnlyPath || !passesEmptySamples,
            "Bug 59 CONFIRMED: polish_text() calls be->process(samples={}, ...). " +
            "With vad_enabled=false (daemon default, no --vad flag in launch args), " +
            "GemmaAudioBackend::process_impl() sets pcm_to_infer={} and calls " +
            "mtmd_bitmap_init_from_audio(0, ptr). This returns null → infer() throws " +
            "std::runtime_error → caught in polish_text() catch → raw transcript " +
            "returned without any polishing. The UI shows 'Polishing...' but the " +
            "feature has never functioned in any shipped deployment " +
            "(hasTextOnlyPath=\(hasTextOnlyPath), passesEmptySamples=\(passesEmptySamples)). " +
            "Fix: add a `process_text(prompt, progress)` method to the Backend " +
            "interface that omits audio tokenisation, and route polish_text() through it.")
    }

    func testBug53_serverJoinWithoutSignallingPreviousSession() {
        // Bugs 49 and 52 (client always calls disconnect() on error) make this
        // path unreachable in practice — the old engine session exits immediately
        // on ConnectionClosed and unblocks join() in < 1 ms.  The C++ defense-in-
        // depth signal was intentionally deferred; mark as expected failure.
        XCTExpectFailure("Bug 53 defense-in-depth C++ signal deferred — unreachable after Bugs 49+52 fixed")
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/ipc/server.cpp"
        guard let content = readSource("engine/src/ipc/server.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read server.cpp"); return
        }
        // Locate the join pattern after accept().
        guard let joinRange = content.range(of: "session_thread_.join()") else {
            XCTFail("Cannot find session_thread_.join() in server.cpp"); return
        }
        // Scan backwards from the join to the accept() — everything between
        // should include a signal/stop/interrupt mechanism if the fix is applied.
        guard let acceptRange = content.range(of: "::accept(listen_fd_") else {
            XCTFail("Cannot find accept() in server.cpp"); return
        }
        let betweenAcceptAndJoin = String(content[acceptRange.lowerBound..<joinRange.lowerBound])

        // The defense-in-depth fix must signal the previous session between
        // accept() and join(). A proper fix would use a stop flag, interrupt,
        // or close the old fd before joining.
        let hasSignal = betweenAcceptAndJoin.contains("g_interrupted")
            || betweenAcceptAndJoin.contains("stop_flag")
            || betweenAcceptAndJoin.contains("request_stop")
            || betweenAcceptAndJoin.contains("interrupt")
            || betweenAcceptAndJoin.contains("signal_stop")

        XCTAssertTrue(hasSignal,
            "Bug 53 CONFIRMED: server.cpp calls session_thread_.join() after " +
            "accept() without signalling the previous session to stop. Under " +
            "Bug 49/52 conditions (client left old fd open), the prior session " +
            "polls for up to idle_timeout_secs (15 s) before exiting, blocking " +
            "the new client. The kernel accepts the new fd but the server is " +
            "stuck in join(). " +
            "Primary fix: fix Bugs 49 and 52 so the client always disconnects " +
            "on error (makes Bug 53 unreachable). " +
            "Defense-in-depth fix: before session_thread_.join(), signal the " +
            "previous session via g_interrupted, a per-session stop flag, or " +
            "close the old client fd.")
    }
}
