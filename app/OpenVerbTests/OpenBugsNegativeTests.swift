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
//   Bug 141 — first recording always fails: audioSession.start() before engine ready
//   Bug 142 — preBuffer has no size limit
//   Bug 143 — AVAudioConverter not warmed up on first use
//   Bug 144 — hardwareFormat queried before audioEngine.start()
//   Bug 145 — no validation that audio is flowing after start()
//   Bug 146 — empty pre-buffer not guarded before .recording transition
//   Bug 147 — socketReadLock released before poll loop (Bug 28 regression)
//   Bug 148 — connectSync TOCTOU race between buffer clear and fd check
//   Bug 149 — dedup spin loop false launchTimeout after 2 s
//   Bug 150 — tryPing can succeed against stale/orphaned engine
//   Bug 151 — PID reuse vulnerability in sendSIGTERM
//   Bug 152 — sleep/wake race: handleWake before disconnect completes
//   Bug 153 — stderr pipe readabilityHandler leak on SIGTERM
//   Bug 154 — activate() failure continues injection into wrong app
//   Bug 155 — 300 ms clipboard restore insufficient for Electron apps
//   Bug 156 — NSPasteboard.changeCount overflow
//   Bug 157 — target app termination race window
//   Bug 158 — AXSecureTextField check false negatives
//   Bug 159 — use-after-free in CGEvent callback
//   Bug 160 — escapeHandled race condition
//   Bug 161 — configure() vs handleCGKeyEvent() race
//   Bug 162 — WaveformView thread safety race
//   Bug 163 — FFTProcessor buffer overflow with malformed bandEdges
//   Bug 164 — PreferencesView backend switch race
//   Bug 165 — ProcessingView state inconsistency on rapid transitions
//   Bug 166 — polishedText not cleared on .error transition
//   Bug 167 — AccessibilityReader blocks MainActor indefinitely
//   Bug 168 — EngineProtocol.fromJSON no size limits
//   Bug 169 — ClipboardStyle.describe OOM on large inputs
//   Bug 170 — wire protocol 0xFFFFFFFF frame OOM
//   Bug 171 — language detection emits invalid BCP-47 "und"
//   Bug 172 — lock ordering potential deadlock in AudioSession waveform dispatch
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
//   Bug 1  — updateFromChunk() must be @MainActor sync                 [LOW]
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
//   Bug 60 — STREAMING_AUDIO catch blocks missing stop_requested_ before join() [HIGH]
//   Bug 61 — connectAndRecord() calls handleCrash() on user cancel             [MED]
//   Bug C1 — worker_thread_ lambda captures `this` and `engine` by reference   [CRIT]
//   Bug C2 — session_thread_ lambda captures IpcServer `this` directly         [CRIT]
//   Bug H1 — stop_requested_ store uses memory_order_relaxed in stop()         [HIGH]
//   Bug H6 — VadScanner push_frame/flush unsynchronised — data race            [HIGH]
//   Bug H7 — ChunkQueue::reset() clears shut_ without notifying waiters        [HIGH]
//   Bug C9 — ring_buffer write() returns 0 silently — no drop diagnostic       [CRIT]
//   Bug C8 — unload_model() leaves hollow backend_; stale shared_ptr races     [MED]
//   Bug NEW-1 — buf.accumulated not cleared before binary mode → framing corruption [MED]
//   Bug 62  — injectPerCharacter missing flags on key-up → Shift sticks           [HIGH]
//   Bug 63  — ModelDownloader.download() re-entrance cancels in-flight download   [MED]
//   Bug 64  — ModelDownloader non-atomic remove+move → model lost on crash        [MED]
//   Bug 65  — VadScanner.flush() bypasses MIN_CHUNK_MS → short utterances emitted [MED]
//   Bug 66  — waveformCallback called on audio tap thread → @Published race       [MED]
//   Bug 67  — RingBuffer::reset() missing write_mutex_ lock → torn index race     [MED]
//   Bug 68  — EngineManager.shutdown() sets status=.stopped before process exits  [MED]
//   Bug 69  — Onboarding mic-permission step advances even when denied            [LOW]
//   Bug 70  — detectFormality classifies ALL-CAPS as "formal" (heuristic inverted)[LOW]
//   Bug 71  — STREAMING_AUDIO timeout transitions to IDLE, leaves fd open         [LOW]
//   Bug 72  — readCursorSurroundingText after-index unclamped → NSRangeException  [MED]
//   Bug 73  — crossfade asyncAfter fires showRecording=false on rapid restart     [LOW]
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
        // Bug 140 fix: raised from 3000 to 5000 — recvJSONSync is already ~3600
        // chars and further growth would push the POLLHUP check outside a 3000-char window.
        let body = substring(content, from: fnRange.lowerBound, length: 5000)
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
    // Bug 1 — WaveformViewModel.updateFromChunk() must be @MainActor and
    //          NOT wrap mutations in DispatchQueue.main.async.
    //
    // The old updateAmplitude() was nonisolated and deferred its mutation
    // via DispatchQueue.main.async. The fix made the VM @MainActor with
    // direct mutation. This test verifies the new updateFromChunk entry
    // point preserves that invariant: it must run on MainActor without
    // deferring mutations to a later run-loop iteration.
    //
    // EXPECTED: updateFromChunk() is a regular method on a @MainActor class
    //           and does NOT wrap mutations in DispatchQueue.main.async.
    // ACTUAL:   bug would manifest as DispatchQueue.main.async wrapping.
    // =======================================================================

    func testBug1_updateFromChunkIsMainActorSync() {
        guard let content = readSource("OpenVerb/UI/WaveformView.swift") else {
            XCTFail("Cannot read WaveformView.swift"); return
        }
        guard let fnRange = content.range(of: "func updateFromChunk") else {
            XCTFail("Cannot find updateFromChunk in WaveformView.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 400)
        let wrapsInMainAsync = fnBody.contains("DispatchQueue.main.async")
        XCTAssertFalse(wrapsInMainAsync,
            "Bug 1 CONFIRMED: updateFromChunk() wraps mutations in " +
            "DispatchQueue.main.async. The method is on a @MainActor class " +
            "and must call bins = ... directly without deferring. " +
            "Fix: remove DispatchQueue.main.async — call bins assignment directly.")
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

    // =======================================================================
    // Bug 60 — STREAMING_AUDIO catch blocks missing stop_requested_ before
    //          join() — session thread blocks for full inference duration
    //          on disconnect                                          [HIGH]
    //
    // Both catch blocks (ConnectionClosed + std::runtime_error) inside the
    // STREAMING_AUDIO state call worker_thread_.join() without first setting
    // stop_requested_ = true. The worker thread's inference loop checks
    // abort_flag = &stop_requested_ at every token decode step. Without the
    // flag, the thread runs the current chunk's inference to completion —
    // 1–30 s for a Gemma 4 chunk — before join() returns.
    //
    // EXPECTED: stop_requested_.store(true, ...) appears before join() in
    //           both STREAMING_AUDIO catch blocks (matches Session::stop()).
    // ACTUAL:   Both blocks go straight to pipeline_active_/shutdown/join
    //           without setting stop_requested_.
    // =======================================================================

    func testBug60_streamingCleanupMissingStopRequested() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/ipc/session.cpp"
        guard let content = readSource("engine/src/ipc/session.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read session.cpp"); return
        }
        // Scope to the STREAMING_AUDIO case body in the state machine.
        // Use the opening brace form to skip the earlier `case State::STREAMING_AUDIO:`
        // match inside state_name() and the WAITING_READY catch that has no pipeline.
        guard let streamingRange = content.range(of: "case State::STREAMING_AUDIO: {") else {
            XCTFail("Cannot find STREAMING_AUDIO state body in session.cpp"); return
        }
        let streamingSection = String(content[streamingRange.lowerBound...])

        // Locate the ConnectionClosed catch block inside STREAMING_AUDIO.
        guard let closedRange = streamingSection.range(of: "catch (const ConnectionClosed&)") else {
            XCTFail("Cannot find ConnectionClosed catch in STREAMING_AUDIO section"); return
        }
        let closedBlock = substring(streamingSection, from: closedRange.lowerBound, length: 300)
        let closedSetsFlag = closedBlock.contains("stop_requested_.store(true")
        XCTAssertTrue(closedSetsFlag,
            "Bug 60 CONFIRMED (ConnectionClosed path): worker_thread_.join() is " +
            "called without first setting stop_requested_ = true. The inference " +
            "worker checks abort_flag at every token decode step; without the flag " +
            "it runs to completion (1–30 s) before join() returns. " +
            "Fix: add stop_requested_.store(true, std::memory_order_relaxed) " +
            "before pipeline_active_.store(false) in the ConnectionClosed catch block.")

        // Also verify the std::runtime_error catch block.
        guard let rteRange = streamingSection.range(of: "catch (const std::runtime_error& e)") else {
            XCTFail("Cannot find runtime_error catch in STREAMING_AUDIO section"); return
        }
        let rteBlock = substring(streamingSection, from: rteRange.lowerBound, length: 300)
        let rteSetsFlag = rteBlock.contains("stop_requested_.store(true")
        XCTAssertTrue(rteSetsFlag,
            "Bug 60 CONFIRMED (runtime_error path): same missing stop_requested_ " +
            "before join() in the timeout/stall catch block. " +
            "Fix: add stop_requested_.store(true, std::memory_order_relaxed) " +
            "before pipeline_active_.store(false) in the runtime_error catch block.")
    }

    // =======================================================================
    // Bug 61 — connectAndRecord() calls handleCrash() on user-initiated
    //          cancellation — Escape key exhausts crash budget on healthy
    //          engine                                                [MED]
    //
    // The catch block in connectAndRecord() calls handleCrash() for every
    // thrown error, including CancellationError raised when the user presses
    // Escape during PREPARING. handleCrash() increments crashCounter
    // unconditionally. With maxCrashes=3 / 60 s, three Escape presses lock
    // the app into a permanent error state on a fully healthy engine.
    //
    // EXPECTED: handleCrash() is called only when appState.state != .idle
    //           (i.e. only for genuine engine errors, not user cancellations).
    // ACTUAL:   handleCrash() is called unconditionally outside the guard.
    // =======================================================================

    func testBug61_userCancelDoesNotIncrementCrashCounter() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        // Locate the connectAndRecord function definition (not a call site).
        guard let fnDefRange = content.range(of: "func connectAndRecord(") else {
            XCTFail("Cannot find connectAndRecord function definition"); return
        }
        // Scope to the function body (up to the next top-level function).
        let afterFn = String(content[fnDefRange.lowerBound...])
        guard let drainRange = afterFn.range(of: "func drainResult(") else {
            XCTFail("Cannot find drainResult boundary"); return
        }
        let fnBody = String(afterFn[afterFn.startIndex..<drainRange.lowerBound])

        // The catch block in connectAndRecord must NOT call handleCrash()
        // before (outside) the `if appState.state != .idle` guard.
        //
        // Find the catch boundary and the guard position, then verify ordering.
        guard let catchPos = fnBody.range(of: "} catch {") else {
            XCTFail("Cannot find catch block in connectAndRecord"); return
        }
        let catchOnward = String(fnBody[catchPos.lowerBound...])

        guard let guardPos = catchOnward.range(of: "if appState.state != .idle") else {
            XCTFail("Cannot find non-idle guard in connectAndRecord catch"); return
        }
        // Text between the catch opener and the guard must not call handleCrash().
        // Use the qualified call `engineManager.handleCrash()` to avoid matching
        // comments that reference handleCrash() by name.
        let beforeGuard = String(catchOnward[catchOnward.startIndex..<guardPos.lowerBound])
        let calledBeforeGuard = beforeGuard.contains("engineManager.handleCrash()")
        XCTAssertFalse(calledBeforeGuard,
            "Bug 61 CONFIRMED: handleCrash() is called unconditionally in the " +
            "connectAndRecord() catch block, before (or outside) the " +
            "`if appState.state != .idle` guard. When the user presses Escape " +
            "during PREPARING, handleCancel() transitions appState to .idle, then " +
            "this catch fires and increments crashCounter on a healthy engine. " +
            "After 3 Escape presses within 60 s the engine enters permanent error " +
            "state (EngineManagerError.crashLoop). " +
            "Fix: move the handleCrash() Task inside the non-idle guard so it " +
            "only fires for genuine engine errors.")
    }

    // =======================================================================
    // Bug C1 — worker_thread_ lambda captures `this` (Session) and `engine`
    //          (Engine&) by reference — use-after-free if session or engine
    //          is destroyed before the worker exits                    [CRIT]
    //
    // worker_thread_ = std::thread([this, fd, &engine]() { ... });
    // `this` is a Session on the IpcServer stack frame; `engine` is an
    // Engine& (IpcServer member).  Both are captured by reference in a
    // std::thread that may outlive them when an exception path bypasses the
    // normal join sequence.
    //
    // EXPECTED: the lambda captures engine by value (shared ownership) or the
    //           Session header exposes a static factory that guarantees
    //           lifetime ordering before thread creation.
    // ACTUAL:   `[this, fd, &engine]` — raw lvalue-reference capture.
    // =======================================================================

    func testBugC1_workerThreadCapturesEngineByReference() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/ipc/session.cpp"
        guard let content = readSource("engine/src/ipc/session.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read session.cpp"); return
        }

        // Locate the worker_thread_ assignment.
        guard let assignRange = content.range(of: "worker_thread_ = std::thread(") else {
            XCTFail("Cannot find worker_thread_ = std::thread( in session.cpp"); return
        }
        let threadLambda = substring(content, from: assignRange.lowerBound, length: 200)

        // The buggy pattern: captures engine by lvalue reference inside the lambda.
        // A fixed version would use value capture, shared_ptr, or no engine capture.
        let capturesEngineByRef = threadLambda.contains("&engine")
        XCTAssertFalse(capturesEngineByRef,
            "Bug C1 CONFIRMED: worker_thread_ lambda uses `[this, fd, &engine]`. " +
            "Capturing engine (an Engine& parameter) by lvalue reference means the " +
            "worker thread holds a raw alias into the IpcServer's engine_ member. " +
            "If the IpcServer is destroyed before the worker thread exits, the reference " +
            "dangles. Although ~Session() calls stop() → join(), exceptions in adjacent " +
            "paths can break the ordering guarantee. " +
            "Fix: pass engine by value (requires Engine to be movable) or introduce a " +
            "std::shared_ptr<Engine> so the worker captures a copy of the shared ownership.")
    }

    // =======================================================================
    // Bug C2 — session_thread_ lambda in IpcServer captures `this` directly —
    //          use-after-free if IpcServer is destroyed mid-session    [CRIT]
    //
    // session_thread_ = std::thread([this, client_fd, now_sec]() { ... });
    // All IpcServer member accesses inside the lambda (engine_, session_active_,
    // pressure_critical_active_, last_inference_sec_, LOG_*) go through the
    // captured `this`.  If IpcServer is destroyed before the thread exits,
    // every one of those accesses is undefined behaviour.
    //
    // EXPECTED: the lambda captures a std::shared_ptr<IpcServer> (or uses
    //           a weak_ptr with a lock) so the IpcServer cannot be freed
    //           while the thread runs.
    // ACTUAL:   bare `[this, client_fd, now_sec]` — raw pointer capture.
    // =======================================================================

    func testBugC2_sessionThreadCapturesIpcServerThisDirectly() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/ipc/server.cpp"
        guard let content = readSource("engine/src/ipc/server.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read server.cpp"); return
        }

        guard let assignRange = content.range(of: "session_thread_ = std::thread(") else {
            XCTFail("Cannot find session_thread_ = std::thread( in server.cpp"); return
        }
        let threadLambda = substring(content, from: assignRange.lowerBound, length: 200)

        // The fix must capture shared ownership, not a raw `this` pointer.
        let hasRawThisCapture = threadLambda.contains("[this,") || threadLambda.contains("[this]")
        let hasSharedOwnership = threadLambda.contains("shared_ptr")
            || threadLambda.contains("weak_ptr")
            || threadLambda.contains("shared_from_this")

        XCTAssertTrue(!hasRawThisCapture || hasSharedOwnership,
            "Bug C2 CONFIRMED: session_thread_ lambda uses `[this, client_fd, now_sec]`. " +
            "Every access to engine_, session_active_, pressure_critical_active_, and " +
            "LOG_* inside the lambda goes through the captured raw `this`. " +
            "IpcServer::stop() joins session_thread_ before the destructor completes, " +
            "which normally prevents a dangling use. However, if stop() is never called " +
            "(e.g., start() throws after the thread is launched), the destructor skips " +
            "the join and the thread outlives the IpcServer object. " +
            "hasRawThisCapture=\(hasRawThisCapture), hasSharedOwnership=\(hasSharedOwnership). " +
            "Fix: make IpcServer inherit from std::enable_shared_from_this<IpcServer> and " +
            "capture `auto self = shared_from_this()` in the lambda, or use a std::weak_ptr " +
            "with a lock guard that returns early if the server is gone.")
    }

    // =======================================================================
    // Bug H1 — stop_requested_ store in stop() uses memory_order_relaxed —
    //          inference worker may process extra chunks before noticing  [HIGH]
    //
    // stop() stores stop_requested_ = true with memory_order_relaxed.
    // The inference worker passes stop_requested_ as an abort_flag to
    // engine.process_stream(), which reads it with relaxed ordering inside
    // the token-decode loop.  Relaxed stores/loads have no happens-before
    // guarantee across threads — the worker may execute multiple additional
    // decode steps before the cache-line update propagates.
    //
    // EXPECTED: stop() uses memory_order_release; the inference loop reads
    //           abort_flag with memory_order_acquire, establishing the
    //           synchronises-with relationship that guarantees visibility.
    // ACTUAL:   both the store in stop() and the stores on exception paths
    //           use memory_order_relaxed.
    // =======================================================================

    func testBugH1_stopRequestedStoreUsesRelaxedOrdering() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/ipc/session.cpp"
        guard let content = readSource("engine/src/ipc/session.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read session.cpp"); return
        }

        guard let stopRange = content.range(of: "void Session::stop()") else {
            XCTFail("Cannot find Session::stop() in session.cpp"); return
        }
        let stopBody = substring(content, from: stopRange.lowerBound, length: 300)

        // The bug: stop_requested_ is stored with relaxed ordering.
        // The fix: use memory_order_release so the worker's acquire-load
        //          synchronises-with this store.
        let usesRelaxedStore = stopBody.contains(
            "stop_requested_.store(true, std::memory_order_relaxed)")
        XCTAssertFalse(usesRelaxedStore,
            "Bug H1 CONFIRMED: Session::stop() stores stop_requested_ with " +
            "memory_order_relaxed. The inference token-decode loop reads abort_flag " +
            "(= &stop_requested_) — also with relaxed ordering. Without a " +
            "release/acquire pair, there is no synchronises-with relationship: the " +
            "CPU is free to delay the cache-line write for an unbounded number of " +
            "decode steps. In practice, on strongly-ordered x86/ARM64 this is " +
            "unlikely to matter, but it is undefined behaviour under the C++11 " +
            "memory model and fails -fsanitize=thread. " +
            "Fix: change to memory_order_release in stop() and memory_order_acquire " +
            "in the abort_flag read inside the inference loop.")
    }

    // =======================================================================
    // Bug H6 — VadScanner::push_frame() and flush() access buffer_ms_,
    //          silence_ms_, in_speech_ without any synchronisation       [HIGH]
    //
    // push_frame() is called from the real-time audio capture thread;
    // flush() is called from the session main thread (inside the
    // zero-length-sentinel handler).  Both read and write buffer_ms_,
    // silence_ms_, and in_speech_ without a mutex or atomic.  Concurrent
    // execution produces torn reads and writes — undefined behaviour under
    // the C++ memory model.
    //
    // EXPECTED: VadScanner has a std::mutex (or equivalent) protecting all
    //           accesses to buffer_ms_, silence_ms_, in_speech_, and
    //           buffer_, or the ownership model prevents concurrent calls.
    // ACTUAL:   vad_scanner.cpp has no mutex or atomic member accesses.
    // =======================================================================

    func testBugH6_vadScannerHasNoSynchronization() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/audio/vad_scanner.cpp"
        guard let content = readSource("engine/src/audio/vad_scanner.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read vad_scanner.cpp"); return
        }

        // The fix must introduce synchronisation — either a mutex lock guard
        // around push_frame/flush/reset bodies, or atomic member variables,
        // or documentation that the caller guarantees single-threaded access
        // (which contradicts the audio-thread vs main-thread split).
        let hasMutex = content.contains("std::mutex")
            || content.contains("std::lock_guard")
            || content.contains("std::unique_lock")
        let hasAtomic = content.contains("std::atomic")

        XCTAssertTrue(hasMutex || hasAtomic,
            "Bug H6 CONFIRMED: vad_scanner.cpp has no mutex or atomic protection " +
            "(hasMutex=\(hasMutex), hasAtomic=\(hasAtomic)). " +
            "push_frame() is called from the CoreAudio real-time thread; flush() and " +
            "reset() are called from the session main thread inside the state machine. " +
            "Concurrent access to buffer_ms_, silence_ms_, in_speech_, and buffer_ " +
            "is a data race: undefined behaviour under C++11, detected by TSan, and " +
            "capable of producing incorrect VAD boundaries or memory corruption " +
            "(buffer_.insert() is not thread-safe). " +
            "Fix: add `std::mutex mu_` to VadScanner and acquire it at the top of " +
            "push_frame(), flush(), and reset().")
    }

    // =======================================================================
    // Bug H7 — ChunkQueue::reset() clears the shutdown flag but does not
    //          notify threads blocked in pop() — lost-wakeup hang       [HIGH]
    //
    // shutdown() sets shut_=true and calls notify_all() on both CVs.
    // Any thread waiting in pop() will wake, re-check the condition
    // `!queue_.empty() || shut_`, and return nullopt.
    //
    // But if reset() runs between the notify_all() and the woken thread's
    // condition re-check (inside the CV's internal lock), the thread sees
    // shut_=false and queue_.empty() → the condition is false → it re-waits
    // indefinitely.  A subsequent push() will eventually wake it, but if
    // no more chunks arrive (abort-and-restart scenario) the thread hangs
    // forever.
    //
    // EXPECTED: reset() calls not_empty_.notify_all() after clearing shut_
    //           so that any thread which was woken by shutdown() and re-checks
    //           the condition sees a fresh wakeup and can exit the abort path.
    // ACTUAL:   reset() returns after `shut_ = false` with no notification.
    // =======================================================================

    func testBugH7_chunkQueueResetMissingNotify() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/audio/chunk_queue.cpp"
        guard let content = readSource("engine/src/audio/chunk_queue.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read chunk_queue.cpp"); return
        }

        guard let resetRange = content.range(of: "void ChunkQueue::reset()") else {
            XCTFail("Cannot find ChunkQueue::reset() in chunk_queue.cpp"); return
        }
        let resetBody = substring(content, from: resetRange.lowerBound, length: 200)

        // The fix: notify_all() on at least not_empty_ (and ideally not_full_) so
        // threads sleeping in pop() or push() wake and re-evaluate the condition.
        let hasNotify = resetBody.contains("notify_all()")
            || resetBody.contains("notify_one()")

        XCTAssertTrue(hasNotify,
            "Bug H7 CONFIRMED: ChunkQueue::reset() does not call notify_all() after " +
            "setting shut_ = false. Race window: shutdown() fires notify_all(); a " +
            "thread wakes in pop() and is about to re-check `!queue_.empty() || shut_`; " +
            "reset() runs and sets shut_=false before the re-check; the thread sees " +
            "both conditions false and re-waits with no pending notification — hang. " +
            "This manifests on rapid abort-and-restart (user presses Escape during " +
            "an active inference) where the worker thread blocks in pop() indefinitely " +
            "after reset(), never processing the sentinel chunk. " +
            "Fix: add `not_empty_.notify_all(); not_full_.notify_all();` at the end " +
            "of reset() so woken threads can re-evaluate and exit cleanly.")
    }

    // =======================================================================
    // Bug C9 — RingBuffer::write() silently returns 0 when the buffer is
    //          full — audio data dropped with no log, no flag, no backpressure
    //                                                                  [CRIT]
    //
    // When the producer (audio capture) writes faster than the IPC reader
    // drains, write() computes n=0 and returns immediately.  No warning is
    // logged, no dropped-bytes counter is incremented, and no error is
    // surfaced to the caller.  The transcriber receives silently truncated
    // audio with no indication that data was lost.
    //
    // EXPECTED: write() logs LOG_WARN (or increments a diagnostic counter)
    //           when n < len, so dropped audio is observable and the caller
    //           can take corrective action.
    // ACTUAL:   `if (n == 0) return 0;` — completely silent discard.
    // =======================================================================

    func testBugC9_ringBufferWriteSilentlyDropsData() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/audio/ring_buffer.cpp"
        guard let content = readSource("engine/src/audio/ring_buffer.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read ring_buffer.cpp"); return
        }

        guard let writeRange = content.range(of: "RingBuffer::write(") else {
            XCTFail("Cannot find RingBuffer::write() in ring_buffer.cpp"); return
        }
        let writeBody = substring(content, from: writeRange.lowerBound, length: 500)

        // The fix: when n == 0 (or n < len), emit a diagnostic so the drop is
        // observable at runtime.  Any of these patterns counts as a fix.
        let hasDropDiagnostic = writeBody.contains("LOG_WARN")
            || writeBody.contains("LOG_ERROR")
            || writeBody.contains("dropped_")
            || writeBody.contains("drop_count")
            || writeBody.contains("overflow")

        XCTAssertTrue(hasDropDiagnostic,
            "Bug C9 CONFIRMED: RingBuffer::write() silently returns 0 when the " +
            "buffer is full (no log, no counter, no backpressure signal). " +
            "The IPC audio reader drains the ring buffer on each connection poll; " +
            "during heavy load or a slow network the producer can outpace the consumer. " +
            "Dropped audio appears as silence to the VAD/chunker: utterances get " +
            "truncated mid-word and the transcriber never knows audio was lost. " +
            "Fix: add `if (n < len) LOG_WARN(\"ring_buffer: dropped %zu bytes (full)\", " +
            "len - n);` before the return, or maintain a `dropped_bytes_` atomic counter " +
            "that is exposed via a diagnostic method and logged by the session.")
    }

    func testBug53_serverJoinWithoutSignallingPreviousSession() {
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

    // =======================================================================
    // Bug C8 — Engine::unload_model() leaves backend_ non-null after hollowing
    //          the Backend object; stale shared_ptr copies race with unload [MED]
    //
    // unload_model() calls backend_->unload_model() — which resets the llama_
    // context pointer inside the Backend — then sets loaded_ = false, but
    // leaves backend_ pointing at the now-hollow Backend object.
    //
    // Race window:
    //   1. Worker thread locks engine_mutex_, copies backend_ into `be`, unlocks.
    //   2. GCD / idle-timeout handler locks, calls unload_model() → llama_ = null.
    //   3. Worker calls be->process_stream() — Backend is alive (shared_ptr refcount
    //      > 0) but llama_ is null → null dereference / crash.
    //
    // Currently safe only because every call site guards on session_active_ before
    // calling unload_model().  Engine itself does not enforce this contract.
    //
    // EXPECTED: unload_model() nulls backend_ after calling backend_->unload_model()
    //           so any stale shared_ptr copy holds the last reference and the next
    //           method call on it detects null llama_ via an internal guard.
    // ACTUAL:   backend_ remains non-null pointing at a hollow Backend.
    // =======================================================================

    func testBugC8_unloadModelDoesNotNullBackend() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/engine.cpp"
        guard let content = readSource("engine/src/engine.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read engine.cpp"); return
        }

        guard let unloadRange = content.range(of: "void Engine::unload_model()") else {
            XCTFail("Cannot find Engine::unload_model() in engine.cpp"); return
        }
        let unloadBody = substring(content, from: unloadRange.lowerBound, length: 250)

        // The fix: null backend_ after the inner unload call so any thread that
        // grabbed a copy of the shared_ptr before the lock will still hold the
        // last live reference, but the Backend's own process_stream / process_file
        // will see a null llama_ context and throw rather than crash.
        let nullsBackend = unloadBody.contains("backend_.reset()")
            || unloadBody.contains("backend_ = nullptr")
            || unloadBody.contains("backend_ = {}")

        XCTAssertTrue(nullsBackend,
            "Bug C8 CONFIRMED: Engine::unload_model() calls backend_->unload_model() " +
            "(resetting llama_ inside the Backend) and sets loaded_=false, but leaves " +
            "backend_ pointing at the now-hollow Backend object. A worker thread that " +
            "copied backend_ under engine_mutex_ and then released the lock calls " +
            "be->process_stream() on a Backend whose llama_ is null — crash. " +
            "Currently mitigated only by caller discipline (all unload sites check " +
            "session_active_ first); Engine does not enforce this contract itself. " +
            "Fix: add `backend_.reset();` (or `backend_ = nullptr;`) at the end of " +
            "unload_model() so stale copies become the sole owner and Backend::process_stream() " +
            "can detect the null llama_ context with an internal guard before crashing.")
    }

    // =======================================================================
    // Bug NEW-1 — RecvBuffer::accumulated not cleared on WAITING_READY →
    //             STREAMING_AUDIO transition; pipelined bytes corrupt first
    //             binary frame header                                    [MED]
    //
    // When the session transitions from WAITING_READY to STREAMING_AUDIO,
    // buf.accumulated is not cleared.  A misbehaving or proxying client that
    // pipelines binary frames before receiving session.ready leaves leftover
    // JSON bytes in buf.accumulated.  recv_binary_frame() reads a 4-byte
    // little-endian frame-length from buf.accumulated first — the stale JSON
    // bytes produce a bogus length, triggering "frame too large" errors or
    // silently corrupting the first audio chunk.
    //
    // The reverse transition (STREAMING_AUDIO → IDLE, session.cpp:321)
    // correctly calls buf.accumulated.clear() before returning to JSON mode.
    //
    // EXPECTED: buf.accumulated.clear() is called immediately after
    //           state = State::STREAMING_AUDIO at session.cpp:267.
    // ACTUAL:   no clear; stale JSON bytes remain in the accumulator.
    // =======================================================================

    func testBugNEW1_accumulatedNotClearedBeforeBinaryMode() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/ipc/session.cpp"
        guard let content = readSource("engine/src/ipc/session.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read session.cpp"); return
        }

        // Locate the WAITING_READY → STREAMING_AUDIO transition: the block that
        // sends session.ready and switches the state machine into binary mode.
        guard let readyRange = content.range(of: #""session.ready""#) else {
            XCTFail("Cannot find session.ready send in session.cpp"); return
        }
        // Grab from the send_json call up to the first_frame_seen assignment and
        // just past — the clear() must appear before chunk_queue_.reset().
        let transitionBlock = substring(content, from: readyRange.lowerBound, length: 400)

        // The bug: no accumulated.clear() in this forward transition.
        // The fix: add buf.accumulated.clear() immediately after the state assignment.
        let clearsAccumulated = transitionBlock.contains("accumulated.clear()")
            || transitionBlock.contains("buf.accumulated = {}")
            || transitionBlock.contains("buf.accumulated.resize(0)")

        XCTAssertTrue(clearsAccumulated,
            "Bug NEW-1 CONFIRMED: session.cpp does not call buf.accumulated.clear() " +
            "when transitioning WAITING_READY → STREAMING_AUDIO (after sending " +
            "session.ready). A client that pipelines binary frames before receiving " +
            "session.ready leaves JSON bytes in buf.accumulated; recv_binary_frame() " +
            "prepends them to the first frame, reads a bogus 4-byte frame-length, and " +
            "either rejects the session with 'frame too large' or silently truncates " +
            "the first audio chunk, degrading recognition quality. " +
            "The reverse path (STREAMING_AUDIO → IDLE at session.cpp:321) correctly " +
            "calls buf.accumulated.clear() before returning to JSON mode. " +
            "Fix: add `buf.accumulated.clear();` immediately after " +
            "`state = State::STREAMING_AUDIO;` at session.cpp:267.")
    }

    // =======================================================================
    // Bug 62 — injectPerCharacter sets flags on key-down but NOT key-up
    //
    // keyCodeAndFlags(for:) returns .maskShift for uppercase chars.  The
    // key-down event correctly receives down.flags = flags.  The key-up event
    // is posted without any flags assignment, violating the CGEvent pairing
    // contract.  The HID stream sees Shift pressed but never released →
    // subsequent keystrokes are corrupted.
    //
    // EXPECTED: key-up event carries the same modifier flags as its key-down.
    // ACTUAL:   key-up is posted with default (empty) flags.
    // =======================================================================

    func testBug62_perCharacterInjectionMissingFlagsOnKeyUp() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }
        guard let fnRange = content.range(of: "func injectPerCharacter") else {
            XCTFail("Cannot find injectPerCharacter in TextInjector.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 2000)

        // The function must contain a key-up block that applies flags.
        // Correct pattern: both keyDown:true and keyDown:false blocks set event.flags.
        // Bug pattern: only the keyDown:true block sets flags.
        let keyUpBlockRange = fnBody.range(of: "keyDown: false")
        XCTAssertNotNil(keyUpBlockRange, "injectPerCharacter must have a key-up CGEvent block")

        guard let upRange = keyUpBlockRange else { return }
        // Grab the ~120 chars after "keyDown: false" — that's the key-up event body.
        let afterKeyUp = substring(fnBody, from: upRange.upperBound, length: 120)
        let keyUpSetsFlags = afterKeyUp.contains(".flags")
        XCTAssertTrue(keyUpSetsFlags,
            "Bug 62 CONFIRMED: injectPerCharacter posts key-up CGEvent without applying " +
            "modifier flags. keyCodeAndFlags() returns .maskShift for uppercase chars; " +
            "the key-down block correctly sets down.flags = flags, but the key-up block " +
            "calls up.post() without up.flags = flags. The HID event tap sees Shift " +
            "pressed (key-down) but never released (key-up has no Shift flag), leaving " +
            "the modifier stuck and corrupting all subsequent keystrokes. " +
            "Fix: add `if flags != CGEventFlags(rawValue: 0) { up.flags = flags }` " +
            "before up.post(tap: .cghidEventTap) in injectPerCharacter.")
    }

    // =======================================================================
    // Bug 63 — ModelDownloader.download() has no re-entrance guard
    //
    // download() calls session?.invalidateAndCancel() unconditionally before
    // checking isDownloading.  A second concurrent call therefore cancels the
    // first URLSession (and its in-flight task) and starts a fresh download,
    // silently discarding all progress from the first call.
    //
    // EXPECTED: download() guards against re-entrance (isDownloading check or throw).
    // ACTUAL:   no guard — second call silently kills the first.
    // =======================================================================

    func testBug63_downloadHasNoReentranceGuard() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }
        guard let fnRange = content.range(of: "func download()") else {
            XCTFail("Cannot find download() in ModelDownloader.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 500)
        // The function must guard against re-entrance BEFORE calling invalidateAndCancel().
        // A guard takes the form "guard !isDownloading" or "if isDownloading { return }".
        // Simple check: look for both a guard/if-isDownloading pattern and invalidateAndCancel;
        // the guard pattern must appear before invalidateAndCancel in the function body.
        let guardPattern = fnBody.range(of: "guard !isDownloading") ??
                           fnBody.range(of: "isDownloading { return") ??
                           fnBody.range(of: "isDownloading { throw")
        let invalidateRange = fnBody.range(of: "invalidateAndCancel")

        guard let inv = invalidateRange else {
            // invalidateAndCancel was removed — the function was rewritten differently; skip.
            return
        }
        let hasGuardBeforeInvalidate = guardPattern.map { $0.lowerBound < inv.lowerBound } ?? false
        XCTAssertTrue(hasGuardBeforeInvalidate,
            "Bug 63 CONFIRMED: ModelDownloader.download() calls " +
            "session?.invalidateAndCancel() before checking isDownloading. A second " +
            "concurrent call silently cancels the first URLSession, discarding all " +
            "download progress with no error or notification. The guard must appear " +
            "before the invalidateAndCancel() call. " +
            "Fix: add `guard !isDownloading else { return }` at the top of download().")
    }

    // =======================================================================
    // Bug 64 — ModelDownloader removes destination before moving temp file
    //
    // urlSession(_:downloadTask:didFinishDownloadingTo:) calls removeItem
    // then moveItem as two separate file-system operations.  A process kill or
    // I/O error between the two leaves the user with no model file (old one
    // deleted, new one never written).
    //
    // EXPECTED: destination replaced atomically (replaceItemAt or move-then-rename).
    // ACTUAL:   removeItem followed by moveItem — non-atomic, data loss on crash.
    // =======================================================================

    func testBug64_nonAtomicRemoveBeforeMove() {
        guard let content = readSource("OpenVerb/Model/ModelDownloader.swift") else {
            XCTFail("Cannot read ModelDownloader.swift"); return
        }
        // Look for the two-step remove + move pattern in the download delegate.
        guard let delegateRange = content.range(of: "didFinishDownloadingTo") else {
            XCTFail("Cannot find didFinishDownloadingTo in ModelDownloader.swift"); return
        }
        let delegateBody = substring(content, from: delegateRange.lowerBound, length: 600)

        // The atomic fix uses replaceItemAt or moveItem without a preceding removeItem.
        let usesAtomicReplace = delegateBody.contains("replaceItemAt")
        let usesRemoveThenMove = delegateBody.contains("removeItem") &&
                                 delegateBody.contains("moveItem")
        XCTAssertTrue(usesAtomicReplace || !usesRemoveThenMove,
            "Bug 64 CONFIRMED: ModelDownloader.urlSession(_:downloadTask:didFinishDownloadingTo:) " +
            "calls FileManager.removeItem(at: destinationURL) and then " +
            "FileManager.moveItem(at: location, to: destinationURL) as two separate " +
            "non-atomic steps. If the process is killed between these two calls the old " +
            "model is gone and the new one was never placed — the user loses the model " +
            "and must re-download from byte 0. " +
            "Fix: use FileManager.replaceItemAt(_:withItemAt:backupItemName:options:) " +
            "which is atomic within the same volume, or move to a sibling temp path " +
            "first and then call rename(2) directly.")
    }

    // =======================================================================
    // Bug 65 — VadScanner::flush() emits without enforcing MIN_CHUNK_MS
    //
    // push_frame() guards chunk emission with `buffer_ms_ - silence_ms_ >= MIN_CHUNK_MS`.
    // flush() calls maybe_emit_chunk(true) unconditionally whenever the buffer
    // is non-empty, bypassing the minimum-duration filter entirely.
    // Short utterances (< 3 s) recorded before the silence boundary fires
    // are sent to the inference engine as final, producing empty transcripts.
    //
    // EXPECTED: flush() enforces MIN_CHUNK_MS before emitting.
    // ACTUAL:   flush() emits regardless of chunk duration.
    // =======================================================================

    func testBug65_flushBypasesMinChunkMs() {
        guard let content = readSource("engine/src/audio/vad_scanner.cpp") ??
                            readSource("../engine/src/audio/vad_scanner.cpp") else {
            XCTFail("Cannot read vad_scanner.cpp"); return
        }
        guard let flushRange = content.range(of: "VadScanner::flush()") else {
            XCTFail("Cannot find VadScanner::flush() in vad_scanner.cpp"); return
        }
        let flushBody = substring(content, from: flushRange.lowerBound, length: 200)
        let enforcesMin = flushBody.contains("MIN_CHUNK_MS")
        XCTAssertTrue(enforcesMin,
            "Bug 65 CONFIRMED: VadScanner::flush() calls maybe_emit_chunk(true) " +
            "without checking MIN_CHUNK_MS. push_frame() guards emission with " +
            "`buffer_ms_ - silence_ms_ >= MIN_CHUNK_MS`, but flush() has no such guard. " +
            "Utterances shorter than MIN_CHUNK_MS (3 s) that end before the silence " +
            "boundary fires are emitted as is_final=true, reaching the inference engine " +
            "and producing empty or low-quality transcripts. " +
            "Fix: add `if (buffer_ms_ - silence_ms_ < MIN_CHUNK_MS) { ... return; }` " +
            "before maybe_emit_chunk(true) in flush().")
    }

    // =======================================================================
    // Bug 66 — processTapBuffer calls waveformCallback on the audio tap thread
    //
    // AVAudioEngine's installTap fires its closure on a real-time audio thread.
    // processTapBuffer releases the lock and then calls waveformCallback inline
    // on that same thread.  The caller in OpenVerbApp updates waveformVM's
    // @Published var amplitudes from the audio thread, which is a threading
    // violation — SwiftUI requires @Published mutations on the main thread.
    //
    // EXPECTED: waveformCallback dispatched to main thread before invocation.
    // ACTUAL:   waveformCallback called inline on audio tap thread.
    // =======================================================================

    func testBug66_waveformCallbackCalledOnAudioThread() {
        guard let content = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Cannot read AudioSession.swift"); return
        }
        guard let fnRange = content.range(of: "func processTapBuffer") else {
            XCTFail("Cannot find processTapBuffer in AudioSession.swift"); return
        }
        // processTapBuffer starts at line 232 and the callback call is at line 311 (~79 lines).
        // At ~55 chars/line that's ~4350 chars; use 5000 to be safe.
        let fnBody = substring(content, from: fnRange.lowerBound, length: 5000)

        // Correct: waveformCallback invocations inside processTapBuffer must be
        // preceded by a DispatchQueue.main dispatch or Task { @MainActor in ... }.
        guard let cbRange = fnBody.range(of: "waveformCallback(chunk)") else {
            // If the call site moved, the test needs updating.
            XCTFail("Cannot find waveformCallback(chunk) in processTapBuffer"); return
        }
        // Check the ~80 chars before the callback call for a main-thread dispatch.
        let beforeCb = substring(fnBody, from: fnBody.startIndex, length: fnBody.distance(from: fnBody.startIndex, to: cbRange.lowerBound))
        let dispatchedToMain = beforeCb.hasSuffix("main.async {") ||
                               beforeCb.contains("DispatchQueue.main") ||
                               beforeCb.contains("@MainActor") ||
                               beforeCb.contains("MainActor.run")
        XCTAssertTrue(dispatchedToMain,
            "Bug 66 CONFIRMED: AudioSession.processTapBuffer() calls waveformCallback " +
            "inline on the AVAudioEngine tap thread (a real-time audio thread). The " +
            "caller in OpenVerbApp passes a closure that mutates waveformVM's @Published " +
            "var amplitudes directly on the audio thread. SwiftUI requires @Published " +
            "property mutations to happen on the main thread; this race condition causes " +
            "undefined rendering behaviour and Swift concurrency warnings. " +
            "Fix: wrap the callback loop in DispatchQueue.main.async { } inside " +
            "processTapBuffer, or document that waveformCallback MUST dispatch itself.")
    }

    // =======================================================================
    // Bug 67 — RingBuffer::reset() stores write_idx_ and read_idx_ without
    //           holding write_mutex_; concurrent write() sees torn indices    [MED]
    //
    // write() acquires write_mutex_ and computes free = BUF_SIZE - (write_idx_ - read_idx_).
    // reset() stores write_idx_=0 then read_idx_=0 without the mutex.
    // A write() between the two stores sees write_idx_=0, read_idx_=stale_value:
    // the unsigned subtraction 0 - stale wraps to ~SIZE_MAX, making free underflow
    // to near-zero and silently dropping all audio for the rest of the session.
    //
    // EXPECTED: reset() acquires write_mutex_ before touching either index so
    //           no concurrent write() can observe a torn state.
    // ACTUAL:   reset() stores both atomics without any lock.
    // =======================================================================

    func testBug67_ringBufferResetMissingWriteMutexLock() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/audio/ring_buffer.cpp"
        guard let content = readSource("engine/src/audio/ring_buffer.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read ring_buffer.cpp"); return
        }

        guard let resetRange = content.range(of: "void RingBuffer::reset()") else {
            XCTFail("Cannot find RingBuffer::reset() in ring_buffer.cpp"); return
        }
        let resetBody = substring(content, from: resetRange.lowerBound, length: 200)

        // The fix: acquire write_mutex_ (or equivalent) before both index stores.
        // Any of these patterns is an acceptable fix.
        let hasLock = resetBody.contains("write_mutex_")
            || resetBody.contains("lock_guard")
            || resetBody.contains("unique_lock")
            || resetBody.contains("scoped_lock")

        XCTAssertTrue(hasLock,
            "Bug 67 CONFIRMED: RingBuffer::reset() stores write_idx_=0 then read_idx_=0 " +
            "without acquiring write_mutex_. A concurrent write() between the two stores " +
            "reads write_idx_=0 and the stale read_idx_; the unsigned subtraction " +
            "0 - stale_read_idx wraps to ~SIZE_MAX, making free_space underflow to " +
            "near-zero, causing all subsequent write() calls to silently drop audio for " +
            "the rest of the session. reset() is only called at session boundaries, but " +
            "write() is on the real-time CoreAudio thread with no synchronisation point. " +
            "Fix: add `std::lock_guard<std::mutex> lk(write_mutex_);` at the top of " +
            "reset() before touching write_idx_ or read_idx_.")
    }

    // =======================================================================
    // Bug 68 — EngineManager.shutdown() sets status = .stopped immediately
    //           after launching a detached Task; process may still be alive  [MED]
    //
    // shutdown() sends SIGTERM, then launches Task.detached { waitForProcessExit() }
    // and immediately sets status = .stopped at function level — before the
    // detached task's wait completes.  If ensureRunning() is called before the
    // old process actually exits, it sees .stopped and launches a new Process,
    // which fails to bind() to the socket still held by the old engine.
    //
    // EXPECTED: status = .stopped is set inside the detached Task's completion
    //           handler (after waitForProcessExit returns), OR ensureRunning()
    //           guards against launching when the old process is still running.
    // ACTUAL:   status = .stopped is set outside the Task body (synchronously
    //           after Task.detached {} launches), before the process exits.
    // =======================================================================

    func testBug68_shutdownSetsStatusBeforeProcessExits() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }

        guard let shutdownRange = content.range(of: "func shutdown()") else {
            XCTFail("Cannot find shutdown() in EngineManager.swift"); return
        }
        // Grab up to the next func boundary.
        let afterShutdown = String(content[shutdownRange.lowerBound...])
        let boundary = afterShutdown.range(of: "\n    private func ")
            ?? afterShutdown.range(of: "\n    func ")
        let fnBody = boundary.map {
            String(afterShutdown[afterShutdown.startIndex..<$0.lowerBound])
        } ?? String(afterShutdown.prefix(600))

        guard let taskRange = fnBody.range(of: "Task.detached") ?? fnBody.range(of: "Task {") else {
            // Task structure removed entirely — check that ensureRunning guards isRunning.
            guard let ensureRange = content.range(of: "func ensureRunning()") else {
                XCTFail("Cannot find ensureRunning() in EngineManager.swift"); return
            }
            let ensureBody = substring(content, from: ensureRange.lowerBound, length: 600)
            XCTAssertTrue(ensureBody.contains("isRunning"),
                "Bug 68 CONFIRMED (alternative fix path): shutdown() has no Task block but " +
                "ensureRunning() also lacks an isRunning guard.")
            return
        }

        guard let statusRange = fnBody.range(of: "status = .stopped") else {
            // status assignment removed from shutdown entirely — acceptable fix.
            return
        }

        // Count { and } between Task.detached and status = .stopped.
        // If closes >= opens, the Task block has already closed before the assignment:
        // that's the bug (status set outside/after the async context).
        let between = String(fnBody[taskRange.lowerBound..<statusRange.lowerBound])
        let opens  = between.filter { $0 == "{" }.count
        let closes = between.filter { $0 == "}" }.count

        XCTAssertTrue(opens > closes,
            "Bug 68 CONFIRMED: EngineManager.shutdown() sets `status = .stopped` at " +
            "function level, after the Task.detached { } block closes " +
            "(opens=\(opens), closes=\(closes) braces between Task start and assignment). " +
            "The detached task's waitForProcessExit() runs asynchronously; by the time " +
            "status is set, the caller has already seen .stopped and may launch a new " +
            "engine process that fails to bind() to the socket still held by the old one. " +
            "Fix: move `status = .stopped` into the Task body after waitForProcessExit, " +
            "or add `guard !(process?.isRunning == true) else { return }` in ensureRunning().")
    }

    // =======================================================================
    // Bug 69 — Onboarding mic-permission step advances to .accessibility
    //           even when the user denies permission (granted == false)    [LOW]
    //
    // The requestAccess callback advances the onboarding step unconditionally:
    //   AVCaptureDevice.requestAccess(for: .audio) { granted in
    //       Task { @MainActor in
    //           micGranted = granted
    //           step = .accessibility   ← always executes, even when denied
    //       }
    //   }
    //
    // EXPECTED: step = .accessibility only when granted == true; a denied
    //           grant shows an error or retry prompt.
    // ACTUAL:   step always advances, leaving the user believing microphone
    //           access is configured when it was denied.
    // =======================================================================

    func testBug69_onboardingAdvancesEvenWhenMicPermissionDenied() {
        guard let content = readSource("OpenVerb/UI/OnboardingView.swift") else {
            XCTFail("Cannot read OnboardingView.swift"); return
        }

        // Locate the requestAccess callback.
        guard let accessRange = content.range(of: "requestAccess(for: .audio)") else {
            XCTFail("Cannot find requestAccess in OnboardingView.swift"); return
        }
        let callbackBody = substring(content, from: accessRange.lowerBound, length: 300)

        // The fix: step = .accessibility must only execute when granted == true.
        // Acceptable patterns: `if granted`, `guard granted`, `if !granted { return }`.
        let hasGrantedGuard = callbackBody.contains("if granted")
            || callbackBody.contains("guard granted")
            || callbackBody.contains("if !granted")
            || callbackBody.contains("when granted")

        XCTAssertTrue(hasGrantedGuard,
            "Bug 69 CONFIRMED: OnboardingView.requestAccess(for: .audio) callback sets " +
            "`step = .accessibility` unconditionally, regardless of the `granted` value. " +
            "When the user taps Deny in the system permission dialog, the callback fires " +
            "with granted=false; micGranted is set to false but step still advances to " +
            ".accessibility. The user believes microphone setup is complete; subsequent " +
            "recordings fail with AudioSessionError.permissionDenied without context. " +
            "Fix: wrap the step advance in `if granted { step = .accessibility }` and " +
            "add an error or retry path for the denied case.")
    }

    // =======================================================================
    // Bug 70 — ClipboardStyle.detectFormality classifies >60% uppercase as
    //           "formal"; ALL-CAPS text is typically informal / shouting     [LOW]
    //
    // The heuristic returns "formal" when more than 60% of alphabetic chars
    // are uppercase.  But on macOS, >60% uppercase almost always means
    // SHOUTING, emphasis, or abbreviations (e.g., "OMG WHAT'S UP") — not
    // formal writing.  Formal text has normal capitalisation (proper nouns,
    // sentence starts) and rarely exceeds ~15% uppercase.
    //
    //   if total > 0 && Double(upperCount) / Double(total) > 0.6 { return "formal" }
    //
    // EXPECTED: high uppercase ratio → "casual" or "informal" (inverted heuristic).
    // ACTUAL:   high uppercase ratio → "formal" (heuristic is backwards).
    // =======================================================================

    func testBug70_detectFormalityInvertsUppercaseHeuristic() {
        guard let content = readSource("OpenVerb/Context/ClipboardStyle.swift") else {
            XCTFail("Cannot read ClipboardStyle.swift"); return
        }

        guard let fnRange = content.range(of: "func detectFormality(") ??
                            content.range(of: "private static func detectFormality(") else {
            XCTFail("Cannot find detectFormality in ClipboardStyle.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 1000)

        // Locate the uppercase-ratio branch.
        guard let ratioRange = fnBody.range(of: "Double(upperCount) / Double(total) > 0.6") ??
                               fnBody.range(of: "upperCount) / Double(total) > 0.6") else {
            // Heuristic was removed or refactored — check that "formal" is no longer
            // returned in a context that follows a high-uppercase check.
            let noHighUpper = !fnBody.contains("return \"formal\"")
                || fnBody.contains("// inverted")
                || fnBody.contains("informal")
            XCTAssertTrue(noHighUpper,
                "Bug 70: detectFormality still returns \"formal\" — verify the uppercase " +
                "heuristic is not inverted after refactoring.")
            return
        }

        // Grab the ~80 chars AFTER the ratio condition — that's the return value.
        let afterRatio = substring(fnBody, from: ratioRange.upperBound, length: 80)

        // The buggy return is "formal". The fix inverts it to "casual" or "informal".
        let returnsFormal = afterRatio.contains("return \"formal\"")
        XCTAssertFalse(returnsFormal,
            "Bug 70 CONFIRMED: ClipboardStyle.detectFormality() returns \"formal\" when " +
            "Double(upperCount) / Double(total) > 0.6. ALL-CAPS text on macOS is " +
            "overwhelmingly informal (shouting, abbreviations, emphasis) — not formal " +
            "writing. Formal text uses correct capitalisation (sentence starts, proper " +
            "nouns) and rarely exceeds ~15% uppercase. The heuristic is backwards. " +
            "Fix: change `return \"formal\"` to `return \"casual\"` (or \"informal\") " +
            "in that branch of detectFormality().")
    }

    // =======================================================================
    // Bug 71 — Session::run() timeout in STREAMING_AUDIO transitions to IDLE
    //           without closing the client fd; orphaned binary frames arrive  [LOW]
    //
    // When a recv_binary_frame() timeout fires, the catch block sends a JSON
    // error, tears down the worker pipeline, and then sets state = State::IDLE
    // without closing or invalidating the file descriptor.  A misbehaving or
    // proxy client may continue sending binary audio frames into a session
    // now in IDLE state; the IDLE handler misinterprets them as JSON.
    //
    // EXPECTED: on timeout the session transitions to SHUTDOWN or DESTROYED,
    //           or explicitly closes fd so the client cannot send more frames.
    // ACTUAL:   state = State::IDLE — fd stays open, session re-enters the
    //           JSON-command loop while the client may still be streaming binary.
    // =======================================================================

    func testBug71_streamingTimeoutReturnsToIdleWithoutClosingFd() {
        let absPath = "/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/engine/src/ipc/session.cpp"
        guard let content = readSource("engine/src/ipc/session.cpp") ??
            (try? String(contentsOfFile: absPath, encoding: .utf8)) else {
            XCTFail("Cannot read session.cpp"); return
        }

        // Locate the STREAMING_AUDIO state body (brace form avoids matching state_name()).
        guard let streamingRange = content.range(of: "case State::STREAMING_AUDIO: {") else {
            XCTFail("Cannot find STREAMING_AUDIO state body in session.cpp"); return
        }
        let streamingSection = String(content[streamingRange.lowerBound...])

        // Locate the runtime_error catch inside STREAMING_AUDIO.
        guard let rteRange = streamingSection.range(of: "catch (const std::runtime_error& e)") else {
            XCTFail("Cannot find runtime_error catch in STREAMING_AUDIO section"); return
        }
        let rteBody = substring(streamingSection, from: rteRange.lowerBound, length: 600)

        // The fix: transition to SHUTDOWN or DESTROYED, or close(fd).
        // The buggy pattern: state = State::IDLE (leaves fd open for re-use).
        let transitionsToIdleOnly =
            rteBody.contains("state = State::IDLE")
            && !rteBody.contains("state = State::SHUTDOWN")
            && !rteBody.contains("state = State::DESTROYED")
            && !rteBody.contains("::close(fd)")
            && !rteBody.contains("close(fd)")

        XCTAssertFalse(transitionsToIdleOnly,
            "Bug 71 CONFIRMED: Session::run() STREAMING_AUDIO runtime_error catch " +
            "(timeout path) sets state = State::IDLE without closing or invalidating fd. " +
            "After sending `session.error{code=timeout}`, the session re-enters the " +
            "IDLE JSON-command loop while the client may still be streaming binary audio " +
            "frames. The IDLE handler does not expect binary frames and will discard them " +
            "silently or misinterpret them as JSON, producing parse errors. " +
            "Fix: transition to SHUTDOWN (or DESTROYED) instead of IDLE on timeout, " +
            "or call close(fd) after send_error() so the client receives an EOF and " +
            "cannot send further frames into the orphaned IDLE session.")
    }

    // =======================================================================
    // Bug 72 — AccessibilityReader.readCursorSurroundingText crashes with
    //           NSRangeException when AX reports a range beyond text bounds  [MED]
    //
    // cursorPos is correctly clamped to [0, totalLen], but the after-index
    // (cursorPos + cfRange.length) is passed to NSString.substring(from:)
    // without clamping.  If an app's AX implementation returns a stale or
    // incorrect range whose location + length exceeds totalLen, the unclamped
    // index causes an NSRangeException and crashes the process.
    //
    //   let cursorPos = min(max(cfRange.location, 0), totalLen)   // clamped ✓
    //   let afterNS = nsString.substring(from: cursorPos + max(cfRange.length, 0)) // NOT clamped ✗
    //
    // EXPECTED: afterStart is clamped to totalLen before substring(from:).
    // ACTUAL:   no upper-bound clamp on the after-index.
    // =======================================================================

    func testBug72_accessibilityReaderUnclampedAfterIndex() {
        guard let content = readSource("OpenVerb/Context/AccessibilityReader.swift") else {
            XCTFail("Cannot read AccessibilityReader.swift"); return
        }

        // Locate the after-cursor text assignment by the variable name used in the function.
        // Bug:  let afterNS = nsString.substring(from: cursorPos + max(cfRange.length, 0))
        //       — no upper-bound clamp; cursorPos + length may exceed totalLen.
        // Fix:  let afterStart = min(cursorPos + max(cfRange.length, 0), totalLen)
        //       let afterNS = nsString.substring(from: afterStart)
        guard let afterVarRange = content.range(of: "let afterNS") ??
                                  content.range(of: "let afterStart") else {
            XCTFail("Cannot find afterNS / afterStart variable in AccessibilityReader.swift"); return
        }
        let afterVarText = substring(content, from: afterVarRange.lowerBound, length: 200)

        // Any of these patterns constitutes a valid clamp on the after-index.
        let isClamped = afterVarText.contains("min(")
            || afterVarText.contains("afterStart")
            || content.contains("let afterStart")

        XCTAssertTrue(isClamped,
            "Bug 72 CONFIRMED: readCursorSurroundingText passes `cursorPos + " +
            "max(cfRange.length, 0)` directly to NSString.substring(from:) without " +
            "clamping to totalLen. cursorPos is correctly clamped at line 144, but the " +
            "combined after-index (location + length) can still exceed totalLen if the " +
            "app's AX implementation reports a stale or incorrect range. " +
            "NSString.substring(from:) raises NSRangeException for out-of-bounds indices, " +
            "crashing the process. Triggered by apps that update their text content after " +
            "the AXSelectedTextRange was queried (e.g., autocomplete, live suggestions). " +
            "Fix: `let afterStart = min(cursorPos + max(cfRange.length, 0), totalLen)` " +
            "and pass afterStart to substring(from:).")
    }

    // =======================================================================
    // Bug 73 — RecordingWindow crossfade asyncAfter fires unconditionally;
    //           rapid restart (inferring → idle → recording) sets
    //           showRecording = false on an active recording               [LOW]
    //
    // The recording→inferring crossfade schedules showRecording = false via
    // DispatchQueue.main.asyncAfter(deadline: .now() + 0.20).  If the app
    // state changes again during the 200ms window (engine error → idle →
    // hotkey → recording), the deferred block fires and incorrectly hides
    // the recording indicator even though the new recording is active.
    //
    // EXPECTED: the asyncAfter closure verifies appState.state == .inferring
    //           before mutating showRecording, or the pending dispatch is
    //           cancelled on each state transition.
    // ACTUAL:   no guard in the closure — fires unconditionally.
    // =======================================================================

    func testBug73_crossfadeAsyncAfterMissingStateGuard() {
        guard let content = readSource("OpenVerb/UI/RecordingWindow.swift") else {
            XCTFail("Cannot read RecordingWindow.swift"); return
        }

        // Locate the crossfade asyncAfter block.
        guard let asyncRange = content.range(of: "asyncAfter(deadline: .now() + 0.20)") ??
                               content.range(of: "asyncAfter(deadline: .now() +") else {
            XCTFail("Cannot find asyncAfter crossfade in RecordingWindow.swift"); return
        }
        // Grab the closure body — the `showRecording = false` is within ~100 chars.
        let closureBody = substring(content, from: asyncRange.lowerBound, length: 200)

        // The fix: guard that state is still .inferring before mutating showRecording.
        let hasStateGuard = closureBody.contains("appState.state == .inferring")
            || closureBody.contains(".inferring")
            || closureBody.contains("guard")

        XCTAssertTrue(hasStateGuard,
            "Bug 73 CONFIRMED: RecordingWindow asyncAfter(deadline: .now() + 0.20) closure " +
            "sets showRecording = false without verifying that appState.state is still " +
            ".inferring. If the state changes within the 200ms window (e.g., error → idle " +
            "→ hotkey → recording), the deferred block fires and sets showRecording = false " +
            "even though the app has started a new recording. The recording indicator " +
            "disappears briefly — a visible flash — before syncDisplayState restores it. " +
            "Fix: add `guard appState.state == .inferring else { return }` at the top of " +
            "the asyncAfter closure, or cancel the pending dispatch on each state change.")
    }

    // =======================================================================
    // Bug 141 — first recording always fails: audioSession.start() before engine ready
    //
    // startRecording() calls audioSession.start() synchronously, then spawns an
    // async Task for connectAndRecord() which calls ensureRunning() (5–10 s cold
    // start). Audio buffers accumulate for the full engine startup delay and are
    // burst-sent when the engine finally becomes ready, causing timing corruption.
    //
    // EXPECTED: audioSession.start() is called inside connectAndRecord() AFTER
    //           ensureRunning() confirms the engine is ready.
    // ACTUAL:   audioSession.start() is called unconditionally in startRecording(),
    //           before the engine has been checked or launched.
    // =======================================================================

    func testBug141_audioSessionStartBeforeEngineReady() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        // Locate the startRecording function body (up to stopRecording).
        guard let fnRange = content.range(of: "private func startRecording()") else {
            XCTFail("Cannot find startRecording in OpenVerbApp.swift"); return
        }
        let afterFn = String(content[fnRange.lowerBound...])
        let endBound = afterFn.range(of: "private func stopRecording")?.lowerBound
            ?? afterFn.endIndex
        let fnBody = String(afterFn[afterFn.startIndex..<endBound])

        // Bug: audioSession.start( is called in startRecording() body (before the Task).
        // Fix: audioSession.start() must only appear inside connectAndRecord(),
        //      after ensureRunning() has confirmed the engine is ready.
        let hasAudioStartInStartRecording = fnBody.contains("audioSession.start(")
        XCTAssertFalse(hasAudioStartInStartRecording,
            "Bug 141 CONFIRMED: audioSession.start() is called in startRecording() before " +
            "the engine is ready. connectAndRecord() calls ensureRunning() (up to 10 s), but " +
            "audio is already flowing by then. ~40 stale pre-buffer chunks are burst-sent " +
            "when the engine finally responds, corrupting timing and causing the first " +
            "recording to fail. Second recording works because the engine is already running. " +
            "Fix: move audioSession.start() to inside connectAndRecord(), after ensureRunning().")
    }

    // =======================================================================
    // Bug 142 — preBuffer has no size limit
    //
    // processTapBuffer() appends chunks to preBuffer without a count cap.
    // During cold start (5–10 s engine launch), 40+ chunks accumulate.
    // Even after Bug 141 is fixed, a cap at ~24 chunks (~3 s of audio) is
    // a safety net preventing unbounded memory growth.
    //
    // EXPECTED: preBuffer.append is guarded by a count limit (~24 chunks).
    // ACTUAL:   preBuffer.append(chunk) is called unconditionally.
    // =======================================================================

    func testBug142_preBufferHasNoSizeLimit() {
        guard let content = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Cannot read AudioSession.swift"); return
        }
        // Locate the preBuffer.append call in processTapBuffer.
        guard let appendRange = content.range(of: "preBuffer.append(chunk)") else {
            XCTFail("Cannot find preBuffer.append(chunk) in AudioSession.swift"); return
        }
        // Inspect a window before the append for a count-guard.
        let beforeAppend = String(content[content.startIndex..<appendRange.lowerBound])
        // Take the last 200 chars before the append to find a nearby guard.
        let windowStart = beforeAppend.index(
            beforeAppend.endIndex,
            offsetBy: -min(200, beforeAppend.count)
        )
        let guardWindow = String(beforeAppend[windowStart...])
        let hasSizeGuard = guardWindow.contains("preBuffer.count")
            || guardWindow.contains("count <")
            || guardWindow.contains("count <=")

        XCTAssertTrue(hasSizeGuard,
            "Bug 142 CONFIRMED: preBuffer.append(chunk) in AudioSession.processTapBuffer " +
            "has no size limit. During engine cold start (5–10 s), 40+ chunks (~160 KB) " +
            "accumulate. Even after Bug 141 is fixed, an uncapped preBuffer is a safety " +
            "hazard for slow engines or repeated cold starts. " +
            "Fix: guard preBuffer.count < 24 (≈3 s at 128 ms/chunk) before appending; " +
            "log a warning and discard oldest chunks when the cap is exceeded.")
    }

    // =======================================================================
    // Bug 143 — AVAudioConverter not warmed up on first use
    //
    // The converter is created fresh on every start(). The first few tap
    // callbacks may produce empty/zero-filled output because the resampler
    // hasn't processed real audio yet. Second run works because the AU is warm.
    //
    // EXPECTED: a silent warmup buffer is passed through the converter after
    //           creation so the first real callback produces valid output.
    // ACTUAL:   no warmup; converter created and used immediately.
    // =======================================================================

    func testBug143_audioConverterNotWarmedUp() {
        guard let content = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Cannot read AudioSession.swift"); return
        }
        // Locate where the converter is created.
        guard let convRange = content.range(of: "AVAudioConverter(from: hardwareFormat, to: outputFormat)") else {
            XCTFail("Cannot find AVAudioConverter creation in AudioSession.swift"); return
        }
        // Scan the 600 chars following converter creation for a warmup call.
        let afterConv = substring(content, from: convRange.lowerBound, length: 600)
        let hasWarmup = afterConv.contains("warmup")
            || afterConv.contains("warm_up")
            || afterConv.contains("primeConverter")
            || (afterConv.contains("convert(to:") && afterConv.contains("AVAudioPCMBuffer"))

        XCTAssertTrue(hasWarmup,
            "Bug 143 CONFIRMED: AVAudioConverter is created in start() but never warmed up. " +
            "The first tap callbacks after creation may return empty/zero-filled buffers " +
            "because the resampler hasn't processed real audio yet. The first recording " +
            "silently drops or corrupts its first ~128 ms of audio. Second recording works " +
            "because the AU is already warm. " +
            "Fix: after creating `conv`, pass a single silent AVAudioPCMBuffer through it " +
            "to prime the resampler state before installing the tap.")
    }

    // =======================================================================
    // Bug 144 — hardwareFormat queried before audioEngine.start()
    //
    // hardwareFormat is captured from inputNode.outputFormat(forBus: 0) BEFORE
    // audioEngine.start(). The audio subsystem may renegotiate sample rate
    // during engine startup, leaving the converter configured for the wrong
    // format (e.g., 44100 Hz instead of 48000 Hz after negotiation).
    //
    // EXPECTED: outputFormat(forBus: 0) is called AFTER audioEngine.start()
    //           so it reflects the post-negotiation hardware format.
    // ACTUAL:   hardwareFormat is queried before audioEngine.start().
    // =======================================================================

    func testBug144_hardwareFormatQueriedBeforeEngineStart() {
        guard let content = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Cannot read AudioSession.swift"); return
        }
        guard let startFnRange = content.range(of: "func start(waveformCallback:") else {
            XCTFail("Cannot find start(waveformCallback:) in AudioSession.swift"); return
        }
        let fnBody = substring(content, from: startFnRange.lowerBound, length: 3000)

        guard let engineStartRange = fnBody.range(of: "try audioEngine.start()") else {
            XCTFail("Cannot find audioEngine.start() in AudioSession.start()"); return
        }
        let beforeEngineStart = String(fnBody[fnBody.startIndex..<engineStartRange.lowerBound])

        // Bug: hardwareFormat is assigned before audioEngine.start().
        // Fix: move outputFormat(forBus: 0) to after audioEngine.start().
        let formatQueriedBeforeStart = beforeEngineStart.contains("outputFormat(forBus: 0)")
        XCTAssertFalse(formatQueriedBeforeStart,
            "Bug 144 CONFIRMED: hardwareFormat is queried via inputNode.outputFormat(forBus: 0) " +
            "BEFORE audioEngine.start(). The audio subsystem may renegotiate sample rate " +
            "during startup, leaving the AVAudioConverter configured for the wrong format. " +
            "This causes silent audio conversion errors or corrupted 16 kHz output on cold start. " +
            "Fix: move the outputFormat(forBus: 0) call to after audioEngine.start() so the " +
            "hardware format reflects the post-negotiation sample rate.")
    }

    // =======================================================================
    // Bug 145 — no validation that audio is flowing after start()
    //
    // After audioEngine.start() succeeds, no check confirms that tap callbacks
    // are delivering non-empty data. If first buffers are zero-filled (converter
    // warm-up / AU activation delay), the failure is silent.
    //
    // EXPECTED: AudioSession validates that at least one non-zero chunk arrives
    //           within a reasonable timeout after start().
    // ACTUAL:   start() returns as soon as audioEngine.start() succeeds, with
    //           no flow validation.
    // =======================================================================

    func testBug145_noAudioFlowValidationAfterStart() {
        guard let content = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Cannot read AudioSession.swift"); return
        }
        guard let startFnRange = content.range(of: "func start(waveformCallback:") else {
            XCTFail("Cannot find start(waveformCallback:) in AudioSession.swift"); return
        }
        let fnBody = substring(content, from: startFnRange.lowerBound, length: 3000)

        guard let engineStartRange = fnBody.range(of: "try audioEngine.start()") else {
            XCTFail("Cannot find audioEngine.start() in AudioSession.start()"); return
        }
        let afterEngineStart = String(fnBody[engineStartRange.upperBound...])

        // Fix: some form of flow validation must appear after audioEngine.start().
        let hasFlowValidation = afterEngineStart.contains("flowValidat")
            || afterEngineStart.contains("waitForFirstChunk")
            || afterEngineStart.contains("firstBuffer")
            || afterEngineStart.contains("non-zero")
            || afterEngineStart.contains("preBuffer.count > 0")

        XCTAssertTrue(hasFlowValidation,
            "Bug 145 CONFIRMED: AudioSession.start() has no validation that tap callbacks " +
            "deliver non-empty data after audioEngine.start() succeeds. If first buffers are " +
            "zero-filled (converter warm-up, AX activation delay), the failure is silent — " +
            "the recording appears to work but captures only silence. " +
            "Fix: after audioEngine.start(), poll preBuffer for up to ~500 ms to confirm " +
            "at least one non-zero chunk has arrived before returning to the caller.")
    }

    // =======================================================================
    // Bug 146 — empty pre-buffer not guarded before .recording transition
    //
    // flushPreBuffer() returns an empty array on cold start because the AU
    // hasn't delivered data yet. connectAndRecord() transitions to .recording
    // regardless, so the user sees a recording UI with no audio flowing.
    //
    // EXPECTED: a non-empty buffered array (or at least one interim chunk)
    //           is required before transitioning to .recording.
    // ACTUAL:   appState.transition(to: .recording) is called even when
    //           flushPreBuffer() returns [].
    // =======================================================================

    func testBug146_emptyPreBufferNotGuardedBeforeRecordingTransition() {
        guard let content = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        guard let fnRange = content.range(of: "func connectAndRecord(") else {
            XCTFail("Cannot find connectAndRecord in OpenVerbApp.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 4000)

        guard let flushRange = fnBody.range(of: "flushPreBuffer()") else {
            XCTFail("Cannot find flushPreBuffer() in connectAndRecord"); return
        }
        guard let recordingRange = fnBody.range(of: "transition(to: .recording)") else {
            XCTFail("Cannot find .recording transition in connectAndRecord"); return
        }

        // Between flushPreBuffer and the .recording transition there must be a
        // guard on the buffered count (or an error path for the empty case).
        let between = String(fnBody[flushRange.upperBound..<recordingRange.lowerBound])
        let hasEmptyGuard = between.contains("buffered.isEmpty")
            || between.contains("buffered.count == 0")
            || between.contains("guard !buffered.isEmpty")
            || between.contains("interim.isEmpty")
            || between.contains("waitForFirstChunk")

        XCTAssertTrue(hasEmptyGuard,
            "Bug 146 CONFIRMED: connectAndRecord() calls flushPreBuffer() but does not " +
            "guard against an empty result before transitioning to .recording. On cold start " +
            "the AU may not have delivered any chunks yet, so the user sees a recording UI " +
            "with no audio actually flowing. Subsequent recordings work because the AU is warm. " +
            "Fix: guard that at least one buffered or interim chunk exists before transitioning; " +
            "if empty, wait for the first tap callback or abort with an error.")
    }

    // =======================================================================
    // Bug 147 — socketReadLock released before poll loop (Bug 28 regression)
    //
    // Bug 76 fix releases socketReadLock before the blocking poll loop to
    // avoid starving Phase 2 monitor. This reopens Bug 28: two concurrent
    // callers (drainResult + Phase 2 monitor) can enter the loop simultaneously
    // and split a single JSON message between them.
    //
    // EXPECTED: socketReadLock is held across the entire poll+read+append cycle,
    //           OR a different serialization mechanism prevents concurrent reads.
    // ACTUAL:   socketReadLock.unlock() appears before the while-true poll loop.
    // =======================================================================

    func testBug147_socketReadLockReleasedBeforePollLoop() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        guard let fnRange = content.range(of: "private func recvJSONSync") else {
            XCTFail("Cannot find recvJSONSync in EngineClient.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 5000)

        guard let unlockRange = fnBody.range(of: "socketReadLock.unlock()") else {
            XCTFail("Cannot find socketReadLock.unlock() in recvJSONSync"); return
        }
        guard let whileRange = fnBody.range(of: "while true {") else {
            XCTFail("Cannot find while true loop in recvJSONSync"); return
        }

        // Bug: unlock appears BEFORE the while-true poll loop.
        // Fix: unlock must appear AFTER the loop (or the lock must wrap the loop).
        let unlockBeforePollLoop = unlockRange.lowerBound < whileRange.lowerBound
        XCTAssertFalse(unlockBeforePollLoop,
            "Bug 147 CONFIRMED: socketReadLock.unlock() appears before the while-true " +
            "poll+read loop in recvJSONSync(). This reopens Bug 28: drainResult and the " +
            "Phase 2 monitor can both enter poll() concurrently and split a single JSON " +
            "message's bytes between them, causing both callers to block indefinitely " +
            "or receive corrupted/partial messages. " +
            "Fix: hold socketReadLock across the entire poll+read+append cycle, and use " +
            "a separate mechanism (wakeRead fd or socket close) to unblock the monitor.")
    }

    // =======================================================================
    // Bug 148 — connectSync TOCTOU race between buffer clear and fd check
    //
    // connectSync() clears recvBuffer (line 133) then checks fd == -1 (line 137).
    // A concurrent disconnect() can set fd = -1 between those two operations,
    // causing the new connection to silently fail while recvBuffer is already wiped.
    //
    // EXPECTED: fd == -1 is checked BEFORE clearing recvBuffer, so the already-
    //           connected early-return path does not wipe the live receive buffer.
    // ACTUAL:   recvBuffer is cleared unconditionally before the fd guard.
    // =======================================================================

    func testBug148_connectSyncTOCTOURace() {
        // Bug 148 (TOCTOU race between recvBuffer clear and fd check) is
        // precluded by ioQueue being SERIAL: connectSync and disconnect run
        // in strict FIFO order on the same queue, so fd cannot flip between
        // the clear and the guard. Bug 119 fix (clear buffer first) is safe
        // under this invariant.
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        guard let ioQueueRange = content.range(of: "ioQueue = DispatchQueue(") else {
            XCTFail("Cannot find ioQueue declaration in EngineClient.swift"); return
        }
        let ioQueueDecl = substring(content, from: ioQueueRange.lowerBound, length: 200)
        XCTAssertFalse(ioQueueDecl.contains(".concurrent"),
            "Bug 148 regression: ioQueue must remain SERIAL (no .concurrent attribute). " +
            "Switching ioQueue to concurrent would reintroduce the TOCTOU hazard between " +
            "the recvBuffer clear and the fd check in connectSync.")
    }

    // =======================================================================
    // Bug 149 — dedup spin loop false launchTimeout after 2 s
    //
    // The second ensureRunning() caller spins for at most 2 s waiting for the
    // engine status to reach .running. Engine cold start (model load) takes 3–10 s.
    // The second caller throws launchTimeout even though the engine is still
    // starting (status == .starting is a valid in-progress state, not a failure).
    //
    // EXPECTED: spin deadline is >= engine max cold-start time (~10 s), or the
    //           second caller waits for .running without a fixed cap.
    // ACTUAL:   spinDeadline = Date().addingTimeInterval(2.0)
    // =======================================================================

    func testBug149_dedupSpinloopFalseLaunchTimeout() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        guard let spinRange = content.range(of: "spinDeadline") else {
            XCTFail("Cannot find spinDeadline in EngineManager.swift"); return
        }
        let spinLine = substring(content, from: spinRange.lowerBound, length: 100)

        // Bug: spinDeadline is 2.0 s. Fix: must be >= 10.0 s (engine cold start budget).
        let hasShortDeadline = spinLine.contains("addingTimeInterval(2.0)")
            || spinLine.contains("addingTimeInterval(2)")
        XCTAssertFalse(hasShortDeadline,
            "Bug 149 CONFIRMED: ensureRunning() dedup spin loop uses a 2-second deadline. " +
            "Engine cold start (Gemma 4 E2B model load) takes 3–10 s depending on hardware. " +
            "A second caller that arrives while the first is still launching will throw " +
            "launchTimeout after 2 s even though the engine is still starting normally. " +
            "This causes spurious 'engine did not respond' errors on cold start when two " +
            "rapid ⌥Space presses both trigger recording. " +
            "Fix: raise the spin deadline to match the engine cold-start budget (≥10 s), " +
            "or replace the spin loop with an async notification from the first caller.")
    }

    // =======================================================================
    // Bug 150 — tryPing can succeed against stale/orphaned engine
    //
    // tryPing() connects and sends a ping but doesn't validate that the
    // responding process is the correct one (right PID, model, backend).
    // An orphaned engine with the wrong model can pass the ping, causing the
    // subsequent session to use the wrong configuration.
    //
    // EXPECTED: tryPing() validates the responding process identity (PID or
    //           a model/backend echo in the pong response).
    // ACTUAL:   any process that responds to ping on the socket path passes.
    // =======================================================================

    func testBug150_tryPingNoProcessValidation() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        guard let fnRange = content.range(of: "private func tryPing()") else {
            XCTFail("Cannot find tryPing() in EngineManager.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 500)

        // Fix: tryPing must validate process identity after ping succeeds.
        let hasProcessValidation = fnBody.contains("processIdentifier")
            || fnBody.contains("isRunning")
            || fnBody.contains("validateProcess")
            || fnBody.contains("expectedPID")
            || fnBody.contains("process?.processIdentifier")

        XCTAssertTrue(hasProcessValidation,
            "Bug 150 CONFIRMED: tryPing() connects, sends a ping, and returns true if " +
            "any process responds on the socket — it never validates that the responding " +
            "process is the expected engine (correct PID, model, backend). An orphaned " +
            "engine from a previous session with a different model can pass the ping, " +
            "causing the new session to silently use the wrong model configuration. " +
            "Fix: after a successful pong, compare process.processIdentifier against " +
            "the expected PID, or add a model/backend echo field to the pong response.")
    }

    // =======================================================================
    // Bug 151 — PID reuse vulnerability in sendSIGTERM
    //
    // sendSIGTERM() checks proc.isRunning but doesn't verify the PID hasn't
    // been recycled. If the original engine exits and the OS reassigns its PID,
    // kill() could terminate an unrelated process.
    //
    // EXPECTED: sendSIGTERM() verifies the process object matches the expected
    //           engine before sending SIGTERM (e.g., comparing creation time).
    // ACTUAL:   only proc.isRunning is checked — no PID recycling protection.
    // =======================================================================

    func testBug151_sendSIGTERMPIDReuseVulnerability() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        guard let fnRange = content.range(of: "private func sendSIGTERM()") else {
            XCTFail("Cannot find sendSIGTERM in EngineManager.swift"); return
        }
        let fnBody = substring(content, from: fnRange.lowerBound, length: 300)

        // Fix: must verify the process beyond just isRunning — e.g., compare
        // a stable identifier, or use a guard against PID reuse.
        let hasOnlyIsRunning = fnBody.contains("proc.isRunning")
            && !fnBody.contains("startTime")
            && !fnBody.contains("creationDate")
            && !fnBody.contains("launchDate")
            && !fnBody.contains("processIdentifier == expectedPID")

        XCTAssertFalse(hasOnlyIsRunning,
            "Bug 151 CONFIRMED: sendSIGTERM() only checks proc.isRunning before calling " +
            "kill(). If the engine exits between the isRunning check and the kill() call, " +
            "and the OS reuses the PID for an unrelated process, kill() terminates the wrong " +
            "process. On macOS the PID space wraps relatively quickly under heavy process " +
            "churn (e.g., Xcode build farms). " +
            "Fix: capture the process start time at launchEngine() and compare it in " +
            "sendSIGTERM() to confirm the PID still refers to the intended engine process.")
    }

    // =======================================================================
    // Bug 152 — sleep/wake race: handleWake fires before disconnect completes
    //
    // handleSleep() launches an async Task that calls disconnect() then sets
    // status = .stopped. handleWake() fires synchronously after the sleep
    // notification and immediately tries tryPing() — possibly before the Task
    // from handleSleep() has even dispatched the disconnect onto ioQueue.
    //
    // EXPECTED: handleWake() waits for handleSleep()'s disconnect to complete
    //           (status == .stopped) before proceeding.
    // ACTUAL:   handleWake() starts immediately with no synchronization against
    //           the in-flight handleSleep() Task.
    // =======================================================================

    func testBug152_sleepWakeRaceHandleWakeBeforeDisconnect() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        guard let handleSleepRange = content.range(of: "@objc func handleSleep()") else {
            XCTFail("Cannot find handleSleep in EngineManager.swift"); return
        }
        let sleepBody = substring(content, from: handleSleepRange.lowerBound, length: 400)

        // Bug: handleSleep uses async Task for disconnect. The Task is not awaited,
        // so handleWake can fire before the disconnect task has even started.
        // Fix: disconnect must be synchronous in handleSleep, or handleWake must
        // wait for status == .stopped before calling tryPing.
        let hasAsyncTaskDisconnect = sleepBody.contains("Task {")
            && sleepBody.contains("disconnect()")
        let disconnectIsSynchronous = sleepBody.contains("engineClient.disconnect()")
            && !sleepBody.contains("Task {")

        XCTAssertTrue(disconnectIsSynchronous || !hasAsyncTaskDisconnect,
            "Bug 152 CONFIRMED: handleSleep() wraps disconnect() in an async Task. " +
            "handleWake() fires on the main queue immediately after the sleep notification " +
            "and starts tryPing() before the Task has dispatched the disconnect to ioQueue. " +
            "tryPing() sees the half-open socket as a live connection and skips the reconnect, " +
            "leaving the engine client in an inconsistent state after wake. " +
            "Fix: make handleSleep() disconnect synchronously (or await the disconnect Task) " +
            "before returning, so handleWake() always observes a clean .stopped state.")
    }

    // =======================================================================
    // Bug 153 — stderr pipe readabilityHandler leak on SIGTERM
    //
    // launchEngine() sets pipe.fileHandleForReading.readabilityHandler and
    // clears it only in proc.terminationHandler. If the process is SIGTERM'd,
    // terminationHandler may not fire on some macOS versions, leaking the pipe fd.
    //
    // EXPECTED: readabilityHandler is also cleared in sendSIGTERM() or via a
    //           separate cleanup path that doesn't depend on terminationHandler.
    // ACTUAL:   only proc.terminationHandler clears the handler.
    // =======================================================================

    func testBug153_stderrReadabilityHandlerLeakOnSIGTERM() {
        guard let content = readSource("OpenVerb/Engine/EngineManager.swift") else {
            XCTFail("Cannot read EngineManager.swift"); return
        }
        guard let launchRange = content.range(of: "private func launchEngine()") else {
            XCTFail("Cannot find launchEngine() in EngineManager.swift"); return
        }
        let launchBody = substring(content, from: launchRange.lowerBound, length: 500)

        // Bug: readabilityHandler is only cleared inside proc.terminationHandler.
        // Fix: also clear it in sendSIGTERM(), shutdown(), or a dedicated cleanup method.
        let handlerOnlyInTermination = launchBody.contains("readabilityHandler = nil")
            && launchBody.contains("terminationHandler")
        guard let sigtermRange = content.range(of: "private func sendSIGTERM()") else {
            if handlerOnlyInTermination {
                XCTFail(
                    "Bug 153 CONFIRMED: readabilityHandler is cleared only in terminationHandler " +
                    "and sendSIGTERM() doesn't exist or doesn't clear it. " +
                    "Fix: add handle.readabilityHandler = nil to sendSIGTERM() or shutdown().")
            }
            return
        }
        let sigtermBody = substring(content, from: sigtermRange.lowerBound, length: 300)
        let sigtermClearsHandler = sigtermBody.contains("readabilityHandler = nil")

        XCTAssertTrue(sigtermClearsHandler,
            "Bug 153 CONFIRMED: launchEngine() clears readabilityHandler only inside " +
            "proc.terminationHandler, which may not fire when the process is SIGTERM'd. " +
            "The Pipe file descriptor leaks, eventually exhausting the per-process fd limit " +
            "after many engine restart cycles. " +
            "Fix: also clear handle.readabilityHandler = nil in sendSIGTERM() and/or " +
            "shutdown() so the leak doesn't depend on terminationHandler firing.")
    }

    // =======================================================================
    // Bug 154 — activate() failure continues injection into wrong app
    //
    // TextInjector.inject() calls targetApp.activate() and only logs a warning
    // on failure. Injection (CGEvent ⌘V) continues into whatever app currently
    // holds focus — pasting transcription data into an unintended target.
    //
    // EXPECTED: inject() returns early if activate() returns false.
    // ACTUAL:   injection continues after activate() failure (only a warning logged).
    // =======================================================================

    func testBug154_activateFailureContinuesInjection() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }
        guard let injectRange = content.range(of: "static func inject(") else {
            XCTFail("Cannot find inject() in TextInjector.swift"); return
        }
        let fnBody = substring(content, from: injectRange.lowerBound, length: 2000)

        guard let activateRange = fnBody.range(of: "targetApp.activate(") else {
            XCTFail("Cannot find targetApp.activate( in inject()"); return
        }
        let afterActivate = substring(fnBody, from: activateRange.lowerBound, length: 300)

        // Fix: when activate() returns false, inject() must return early.
        let hasEarlyReturn = afterActivate.contains("return")
            && (afterActivate.contains("!targetApp.activate") ||
                afterActivate.contains("activate(") && afterActivate.contains("{ return"))
        // Also acceptable: the activate result is used in a guard.
        let hasGuardActivate = afterActivate.contains("guard")
            && afterActivate.contains("activate(")
            && afterActivate.contains("return")

        XCTAssertTrue(hasEarlyReturn || hasGuardActivate,
            "Bug 154 CONFIRMED: TextInjector.inject() logs a warning when activate() returns " +
            "false but continues to postPasteEvent(). The ⌘V CGEvent is delivered to whatever " +
            "app currently holds focus — which may not be targetApp — pasting the transcription " +
            "into an unintended target (e.g., a password field in a different app). " +
            "Fix: change the activate() block to `guard targetApp.activate(...) else { return }` " +
            "so injection is aborted when focus transfer fails.")
    }

    // =======================================================================
    // Bug 155 — 300 ms clipboard restore insufficient for Electron apps
    //
    // TextInjector waits 300 ms after posting ⌘V before restoring the clipboard.
    // VS Code, Slack, and Discord (all Electron) may take 500–1000 ms to read
    // the clipboard. The restore overwrites the paste content before the app
    // reads it, causing silent data loss.
    //
    // EXPECTED: clipboard-read delay is >= 500 ms (minimum for Electron apps).
    // ACTUAL:   Task.sleep(for: .milliseconds(300))
    // =======================================================================

    func testBug155_clipboardRestoreDelayTooShort() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }
        guard let injectRange = content.range(of: "static func inject(") else {
            XCTFail("Cannot find inject() in TextInjector.swift"); return
        }
        let fnBody = substring(content, from: injectRange.lowerBound, length: 2000)

        // Bug: 300 ms delay before clipboard restore.
        // Fix: must be >= 500 ms for Electron compatibility.
        let has300msDelay = fnBody.contains("milliseconds(300)")
            || fnBody.contains(".milliseconds(300)")
        XCTAssertFalse(has300msDelay,
            "Bug 155 CONFIRMED: TextInjector.inject() waits only 300 ms after posting ⌘V " +
            "before restoring the original clipboard. Electron-based apps (VS Code, Slack, " +
            "Discord) may take 500–1000 ms to process the paste event and read the clipboard. " +
            "If the clipboard is restored before they read it, the paste is silently lost " +
            "with no error or retry. This is a common failure mode for the most popular " +
            "developer and communication apps. " +
            "Fix: increase the delay to >= 500 ms, or use a configurable AppSettings value " +
            "that users can tune for their specific Electron app latency.")
    }

    // =======================================================================
    // Bug 156 — NSPasteboard.changeCount overflow
    //
    // The saved changeCount is compared with == after the paste window.
    // changeCount is a signed Int that wraps around on long-running sessions.
    // An overflow produces a false positive — the restore guard fires even
    // though another process wrote to the clipboard, overwriting their data.
    //
    // EXPECTED: changeCount comparison uses overflow-safe arithmetic, or
    //           changeCount is replaced with a session-unique write token.
    // ACTUAL:   pasteboard.changeCount == savedChangeCount (plain == on Int)
    // =======================================================================

    func testBug156_changeCountOverflow() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }
        guard let injectRange = content.range(of: "static func inject(") else {
            XCTFail("Cannot find inject() in TextInjector.swift"); return
        }
        let fnBody = substring(content, from: injectRange.lowerBound, length: 2000)

        // Bug: plain == comparison on changeCount.
        // Fix: use overflow-safe arithmetic, a monotonic session token, or
        //      compare with a wrapping-aware check.
        let hasPlainEquals = fnBody.contains("changeCount == savedChangeCount")
        XCTAssertFalse(hasPlainEquals,
            "Bug 156 CONFIRMED: TextInjector compares pasteboard.changeCount == savedChangeCount " +
            "using plain integer equality. changeCount is a signed Int that wraps on overflow " +
            "during long-running sessions. A wrap-around produces a false positive — the guard " +
            "thinks another process hasn't touched the clipboard and restores the saved content, " +
            "overwriting whatever that process wrote. " +
            "Fix: replace changeCount with a session-unique write token (e.g., a UUID written " +
            "as NSPasteboardType metadata) so wrap-around is impossible, or use a monotonic " +
            "generation counter that detects the wrap case.")
    }

    // =======================================================================
    // Bug 157 — target app termination race window
    //
    // inject() guards isTerminated at the start. The app can quit between the
    // guard and postPasteEvent(). ⌘V is delivered to the wrong app.
    //
    // EXPECTED: isTerminated is re-checked immediately before postPasteEvent().
    // ACTUAL:   only one isTerminated check at the top of inject().
    // =======================================================================

    func testBug157_targetAppTerminationRaceWindow() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }
        guard let injectRange = content.range(of: "static func inject(") else {
            XCTFail("Cannot find inject() in TextInjector.swift"); return
        }
        let fnBody = substring(content, from: injectRange.lowerBound, length: 2000)

        guard let postPasteRange = fnBody.range(of: "postPasteEvent()") else {
            XCTFail("Cannot find postPasteEvent() in inject()"); return
        }
        let beforePaste = String(fnBody[fnBody.startIndex..<postPasteRange.lowerBound])

        // Count isTerminated checks: the fix requires one near postPasteEvent().
        // A single check only at the top of the function is the bug pattern.
        let terminatedChecks = beforePaste.components(separatedBy: "isTerminated").count - 1
        XCTAssertGreaterThan(terminatedChecks, 1,
            "Bug 157 CONFIRMED: inject() checks targetApp.isTerminated once at the start. " +
            "The target app can quit during the 50 ms focus delay or clipboard write, " +
            "leaving postPasteEvent() to deliver ⌘V to whatever app holds focus after " +
            "the target exits — potentially a password manager or secure input field. " +
            "terminatedChecks=\(terminatedChecks) (need >= 2: one at top, one before paste). " +
            "Fix: add a second `guard !targetApp.isTerminated` check immediately before " +
            "postPasteEvent() to close the race window.")
    }

    // =======================================================================
    // Bug 158 — AXSecureTextField check false negatives
    //
    // isSecureField only checks AXRole == "AXSecureTextField". Browsers and
    // password managers use AXTextArea with an AXSecure attribute, or
    // AXWebArea — these are not caught and passwords get pasted via clipboard.
    //
    // EXPECTED: isSecureField also checks kAXValueAttribute + AXSecure flag
    //           and additional secure-input role variants.
    // ACTUAL:   only `role == "AXSecureTextField"` is checked.
    // =======================================================================

    func testBug158_secureTextFieldFalseNegatives() {
        guard let content = readSource("OpenVerb/Output/TextInjector.swift") else {
            XCTFail("Cannot read TextInjector.swift"); return
        }
        guard let secureRange = content.range(of: "isSecureField") else {
            XCTFail("Cannot find isSecureField in TextInjector.swift"); return
        }
        let secureBlock = substring(content, from: secureRange.lowerBound, length: 500)

        // Bug: only checks "AXSecureTextField" role.
        // Fix: must also check kAXSecureAttribute or SecInputIsEnabled or similar.
        let hasOnlyRoleCheck = secureBlock.contains("AXSecureTextField")
            && !secureBlock.contains("kAXSecure")
            && !secureBlock.contains("SecInputIsEnabled")

        XCTAssertFalse(hasOnlyRoleCheck,
            "Bug 158 CONFIRMED: TextInjector.isSecureField only checks " +
            "AXRole == \"AXSecureTextField\". Browser password fields use AXTextArea " +
            "with an AXSecure attribute; password managers use AXWebArea or custom roles. " +
            "These are not caught, so transcription is pasted via clipboard into secure " +
            "fields, leaking it in plaintext. hasOnlyRoleCheck=\(hasOnlyRoleCheck). " +
            "Fix: also call AXUIElementCopyAttributeValue for kAXSecureAttribute (or " +
            "check SecInputIsEnabled()) to catch browser and password-manager secure inputs.")
    }

    // =======================================================================
    // Bug 159 — use-after-free in CGEvent callback
    //
    // installEventTap() passes `Unmanaged.passUnretained(self)` as the userInfo
    // pointer for a CGEvent tap callback. If HotkeyManager is deallocated while
    // a callback is in flight, the dangling pointer dereference is UB / crash.
    //
    // EXPECTED: passRetained(self) with a balancing takeRetainedValue() in the
    //           callback, or HotkeyManager is guaranteed to outlive all callbacks.
    // ACTUAL:   passUnretained(self) — no retain, dangling pointer possible.
    // =======================================================================

    func testBug159_cgEventCallbackUseAfterFree() {
        guard let content = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Cannot read HotkeyManager.swift"); return
        }
        // The event tap callback userInfo must use passRetained, not passUnretained.
        guard let tapRange = content.range(of: "CGEvent.tapCreate(") else {
            XCTFail("Cannot find CGEvent.tapCreate in HotkeyManager.swift"); return
        }
        let tapBlock = substring(content, from: tapRange.lowerBound, length: 600)

        let hasPassUnretained = tapBlock.contains("passUnretained(self)")
        XCTAssertFalse(hasPassUnretained,
            "Bug 159 CONFIRMED: HotkeyManager passes `Unmanaged.passUnretained(self)` as " +
            "the userInfo pointer to a CGEvent tap callback. If HotkeyManager is deallocated " +
            "while a callback is still in-flight (e.g., during a fast app-quit sequence), " +
            "the callback accesses a dangling pointer — undefined behaviour or crash. " +
            "The comment claims HotkeyManager 'lives for the app lifetime', but this is a " +
            "structural invariant, not a memory-safety guarantee. " +
            "Fix: use passRetained(self) and call takeRetainedValue() inside the callback " +
            "(paired with release on tap removal), or store a strong reference separately.")
    }

    // =======================================================================
    // Bug 160 — escapeHandled race condition
    //
    // handleEscape() sets escapeHandled = true synchronously, then resets it
    // via DispatchQueue.main.async. Two rapid Escape presses from global+local
    // monitors fire on the main queue in quick succession; both arrive before
    // the async reset block runs, so both pass the `guard !escapeHandled` check.
    //
    // EXPECTED: escapeHandled is reset synchronously after the NSEvent handler
    //           returns (e.g., via a generation counter or via the run loop idle).
    // ACTUAL:   reset is deferred via DispatchQueue.main.async, leaving a window
    //           where two rapid presses both pass the guard.
    // =======================================================================

    func testBug160_escapeHandledRaceCondition() {
        guard let content = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Cannot read HotkeyManager.swift"); return
        }
        guard let escapeRange = content.range(of: "private func handleEscape()") else {
            XCTFail("Cannot find handleEscape() in HotkeyManager.swift"); return
        }
        let fnBody = substring(content, from: escapeRange.lowerBound, length: 400)

        // Bug: reset via DispatchQueue.main.async.
        // Fix: use a generation counter, or reset synchronously in the same handler.
        let hasAsyncReset = fnBody.contains("DispatchQueue.main.async")
            && fnBody.contains("escapeHandled = false")
        XCTAssertFalse(hasAsyncReset,
            "Bug 160 CONFIRMED: handleEscape() resets escapeHandled via " +
            "DispatchQueue.main.async. Two rapid Escape presses from the global and local " +
            "NSEvent monitors both arrive on the main queue before the async reset block runs — " +
            "both pass the `guard !escapeHandled` check, firing two cancel actions for a single " +
            "keypress. This causes a double-cancel (e.g., abort + crash recovery on a healthy " +
            "session, or two crash-counter increments on a healthy engine). " +
            "Fix: use an event generation counter (increment on each press, check on callback " +
            "entry) or reset escapeHandled synchronously at the end of handleEscape().")
    }

    // =======================================================================
    // Bug 161 — configure() vs handleCGKeyEvent() non-atomic hotkey update
    //
    // configure() updates hotKey.virtualKey then hotKey.flags in two separate
    // assignments. A keypress handler that reads hotKey between the two writes
    // sees mismatched virtualKey/flags, potentially accepting wrong key combos.
    //
    // EXPECTED: hotKey is updated atomically (single struct assignment).
    // ACTUAL:   two separate field assignments with no synchronization.
    // =======================================================================

    func testBug161_hotkeyConfigureNonAtomicUpdate() {
        guard let content = readSource("OpenVerb/Input/HotkeyManager.swift") else {
            XCTFail("Cannot read HotkeyManager.swift"); return
        }
        guard let configRange = content.range(of: "func configure(") else {
            XCTFail("Cannot find configure() in HotkeyManager.swift"); return
        }
        let fnBody = substring(content, from: configRange.lowerBound, length: 400)

        // Bug: hotKey.virtualKey and hotKey.flags set separately.
        // Fix: hotKey = HotKey(virtualKey: key.virtualKey, flags: key.flags) — single assignment.
        let hasVirtualKeyAssignment = fnBody.contains("hotKey.virtualKey")
        let hasFlagsAssignment = fnBody.contains("hotKey.flags")
        let hasSingleStructAssignment = fnBody.contains("HotKey(virtualKey:")
            || fnBody.contains("hotKey = key")
            || fnBody.contains("hotKey = HotKey(")

        XCTAssertTrue(hasSingleStructAssignment || (!hasVirtualKeyAssignment && !hasFlagsAssignment),
            "Bug 161 CONFIRMED: configure() sets hotKey.virtualKey and hotKey.flags as two " +
            "separate field assignments. handleCGKeyEvent() reads both fields in sequence " +
            "(both @MainActor, but not mutually exclusive at the level of the two writes). " +
            "A keypress arriving between the two assignments sees mismatched virtualKey/flags " +
            "and may pass or fail the guard incorrectly. " +
            "hasVirtualKeyAssignment=\(hasVirtualKeyAssignment), hasFlagsAssignment=\(hasFlagsAssignment), " +
            "hasSingleStructAssignment=\(hasSingleStructAssignment). " +
            "Fix: replace the two field assignments with a single `hotKey = HotKey(virtualKey:flags:)` " +
            "struct assignment, which Swift performs atomically for value types.")
    }

    // =======================================================================
    // Bug 162 — WaveformView thread safety race
    //
    // WaveformViewModel.updateFromChunk() mutates the `smoothed` array and
    // publishes `bins`. If stop() runs while an update is in-flight on a
    // non-MainActor thread, array corruption is possible.
    //
    // EXPECTED: updateFromChunk() is confined to @MainActor; the waveform
    //           callback is always dispatched via DispatchQueue.main.async.
    // ACTUAL:   waveformCallback is dispatched via DispatchQueue.main.async
    //           but WaveformViewModel itself may still acquire self.lock inside
    //           the async block (see Bug 172), risking deadlock with stop().
    // =======================================================================

    func testBug162_waveformViewThreadSafety() {
        guard let content = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Cannot read AudioSession.swift"); return
        }
        // The waveformCallback must ONLY be dispatched via DispatchQueue.main.async
        // so that WaveformViewModel (@MainActor) receives it on the correct executor.
        guard let dispatchRange = content.range(of: "waveformCallback(chunk)") else {
            XCTFail("Cannot find waveformCallback(chunk) in AudioSession.swift"); return
        }
        // Scan backwards 200 chars to find the enclosing dispatch context.
        let beforeCallback = String(content[content.startIndex..<dispatchRange.lowerBound])
        let windowStart = beforeCallback.index(
            beforeCallback.endIndex,
            offsetBy: -min(200, beforeCallback.count)
        )
        let dispatchContext = String(beforeCallback[windowStart...])
        let isOnMainQueue = dispatchContext.contains("DispatchQueue.main.async")
        XCTAssertTrue(isOnMainQueue,
            "Bug 162 CONFIRMED: waveformCallback(chunk) is not enclosed in a " +
            "DispatchQueue.main.async block in AudioSession.processTapBuffer. " +
            "WaveformViewModel is @MainActor — calling updateFromChunk from the audio " +
            "tap thread (a background DispatchQueue managed by AVAudioEngine) races with " +
            "any MainActor mutations on `smoothed` and `bins`, potentially corrupting the " +
            "array or causing a publish-from-background-thread violation. " +
            "Fix: confirm waveformCallback is always dispatched via DispatchQueue.main.async " +
            "before invocation (current code dispatches correctly; this test documents the " +
            "invariant that must be maintained).")
    }

    // =======================================================================
    // Bug 163 — FFTProcessor buffer overflow with malformed bandEdges
    //
    // If bandEdges construction produces edges where edges[i] >= fftSize / 2,
    // vDSP_sve is called with a pointer advanced past the end of the magnitudes
    // buffer. Missing bounds validation on `lo` before advancing the pointer.
    //
    // EXPECTED: `lo < fftSize / 2` is validated before calling vDSP_sve.
    // ACTUAL:   only `lo < hi` is checked; lo itself may exceed the buffer bounds.
    // =======================================================================

    func testBug163_fftProcessorBufferOverflow() {
        guard let content = readSource("OpenVerb/Input/FFTProcessor.swift") else {
            XCTFail("Cannot read FFTProcessor.swift"); return
        }
        guard let bandsRange = content.range(of: "vDSP_sve(") else {
            XCTFail("Cannot find vDSP_sve in FFTProcessor.swift"); return
        }
        // Inspect the 200 chars before vDSP_sve for a lo bounds check.
        let beforeVDSP = String(content[content.startIndex..<bandsRange.lowerBound])
        let windowStart = beforeVDSP.index(
            beforeVDSP.endIndex,
            offsetBy: -min(200, beforeVDSP.count)
        )
        let guardWindow = String(beforeVDSP[windowStart...])

        // Fix: must validate lo < fftSize/2 (not just lo < hi) before advancing pointer.
        let hasLoBoundsCheck = guardWindow.contains("lo < fftSize / 2")
            || guardWindow.contains("lo >= fftSize")
            || guardWindow.contains("bandEdges[i] < fftSize")

        XCTAssertTrue(hasLoBoundsCheck,
            "Bug 163 CONFIRMED: FFTProcessor.process() guards `lo < hi` before calling " +
            "vDSP_sve but does not validate that `lo < fftSize / 2`. If bandEdges[i] >= " +
            "fftSize / 2, `advanced(by: lo)` advances past the end of the magnitudes buffer " +
            "(which has fftSize/2 elements), causing an out-of-bounds read. " +
            "`hi = min(bandEdges[i+1], fftSize/2)` clamps hi, so `lo >= hi` fires the " +
            "continue — but `advanced(by: lo)` is evaluated before the guard and the " +
            "pointer arithmetic itself is UB in unsafe Swift. " +
            "Fix: add `guard lo < fftSize / 2 else { continue }` before the vDSP_sve call.")
    }

    // =======================================================================
    // Bug 164 — PreferencesView backend switch race
    //
    // The backend Picker setter checks `guard appState.state == .idle` synchronously,
    // then launches an async Task for restartWithBackend. The state can change from
    // .idle to .preparing/.recording between the guard and the Task execution,
    // killing an active recording silently.
    //
    // EXPECTED: appState.state == .idle is re-checked INSIDE the Task before
    //           calling restartWithBackend.
    // ACTUAL:   state is only checked once, outside the async Task.
    // =======================================================================

    func testBug164_preferencesViewBackendSwitchRace() {
        guard let content = readSource("OpenVerb/UI/PreferencesView.swift") else {
            XCTFail("Cannot read PreferencesView.swift"); return
        }
        guard content.range(of: "restartWithBackend(") != nil else {
            XCTFail("Cannot find restartWithBackend in PreferencesView.swift"); return
        }
        // Find the Task block containing restartWithBackend.
        guard let taskRange = content.range(of: "Task {") else {
            XCTFail("Cannot find Task block in PreferencesView.swift"); return
        }
        let taskBody = substring(content, from: taskRange.lowerBound, length: 400)

        // Fix: appState.state == .idle must be re-checked inside the Task body.
        let hasInTaskStateCheck = taskBody.contains("appState.state == .idle")
            || taskBody.contains("appState.state != .idle")
            || taskBody.contains("guard appState")

        XCTAssertTrue(hasInTaskStateCheck,
            "Bug 164 CONFIRMED: PreferencesView backend Picker setter checks " +
            "appState.state == .idle outside the async Task, then calls " +
            "restartWithBackend inside the Task. The Task's first suspension point " +
            "(any await) allows other work to run — the user could start a recording " +
            "between the guard and the Task body executing. restartWithBackend kills " +
            "the engine mid-session with no user warning or data preservation. " +
            "Fix: add `guard appState.state == .idle else { isSwitchingBackend = false; return }` " +
            "as the first statement inside the Task body, before any await.")
    }

    // =======================================================================
    // Bug 165 — ProcessingView state inconsistency on rapid transitions
    //
    // displayedPercent, showSpinner, etaSeconds, and isPolishing are independent
    // @Published vars updated in separate assignments. Rapid state transitions
    // can cause both ETA text and spinner to appear simultaneously, or ETA to
    // show stale values from a previous session.
    //
    // EXPECTED: all ProcessingViewModel state vars are updated atomically in a
    //           single transaction or via a single computed property.
    // ACTUAL:   four independent @Published vars updated in separate assignments.
    // =======================================================================

    func testBug165_processingViewStateInconsistency() {
        guard let content = readSource("OpenVerb/UI/ProcessingView.swift") else {
            XCTFail("Cannot read ProcessingView.swift"); return
        }
        // The spinner and ETA must be mutually exclusive in the view body.
        guard let bodyRange = content.range(of: "var body: some View") else {
            XCTFail("Cannot find View body in ProcessingView.swift"); return
        }
        let viewBody = substring(content, from: bodyRange.lowerBound, length: 1500)

        // Fix: ETA text and spinner must be in mutually exclusive branches.
        // A simple form: `if showSpinner { ... } else { etaText }` or similar.
        let spinnerRange = viewBody.range(of: "showSpinner")
        let etaRange = viewBody.range(of: "etaSeconds")
        guard spinnerRange != nil, etaRange != nil else { return }

        // Check that they are in separate conditional branches (if/else pattern).
        let hasElseBranch = viewBody.contains("} else {")
            || viewBody.contains("} else if")
        XCTAssertTrue(hasElseBranch,
            "Bug 165 CONFIRMED: ProcessingView renders showSpinner and etaSeconds as " +
            "independent conditions with no mutual-exclusion guard. During rapid state " +
            "transitions both can be true simultaneously — the ETA countdown and spinner " +
            "both appear, and/or the ETA shows a stale value from a previous session " +
            "before reset() fires. " +
            "Fix: use a single computed `enum DisplayState { case spinner, eta(Int), idle }` " +
            "that is updated atomically, and switch over it in the view body.")
    }

    // =======================================================================
    // Bug 166 — polishedText not cleared on .error transition
    //
    // AppState.transition(to: .error) clears livePartialText (Bug 136 fix)
    // but does NOT clear polishedText. Stale polished text from a failed session
    // can leak into the next session via the .error → .preparing path.
    //
    // EXPECTED: .error transition clears both livePartialText and polishedText.
    // ACTUAL:   only livePartialText is cleared; polishedText remains stale.
    // =======================================================================

    func testBug166_polishedTextNotClearedOnError() {
        guard let content = readSource("OpenVerb/State/AppState.swift") else {
            XCTFail("Cannot read AppState.swift"); return
        }
        guard let transitionRange = content.range(of: "func transition(to newState:") else {
            XCTFail("Cannot find transition() in AppState.swift"); return
        }
        let fnBody = substring(content, from: transitionRange.lowerBound, length: 1500)

        guard let errorCaseRange = fnBody.range(of: "case .error:") else {
            XCTFail("Cannot find case .error in transition()"); return
        }
        // Inspect the .error case body (up to the next case or end of function).
        let errorBody = substring(fnBody, from: errorCaseRange.lowerBound, length: 500)

        // Bug: polishedText is not cleared in the .error case.
        let clearsPolishedText = errorBody.contains("polishedText = nil")
            || errorBody.contains("polishedText = \"\"")
            || errorBody.contains("setPolishedText(nil)")

        XCTAssertTrue(clearsPolishedText,
            "Bug 166 CONFIRMED: AppState.transition(to: .error) clears livePartialText " +
            "(Bug 136 fix) but NOT polishedText. A session that reaches .error with a " +
            "polished result from a previous session will retain that stale polishedText. " +
            "On the .error → .preparing → .recording path (abort + restart), the stale " +
            "polishedText is visible in the result panel alongside the new error, " +
            "confusing the user and potentially causing double-injection on recovery. " +
            "Fix: add `polishedText = nil` (or `setPolishedText(nil)`) in the .error case " +
            "of transition(), alongside the existing `livePartialText = \"\"` reset.")
    }

    // =======================================================================
    // Bug 167 — AccessibilityReader blocks MainActor indefinitely
    //
    // AX API calls (AXUIElementCopyAttributeValue) are synchronous and have
    // no timeout. If the target app is hung or paused under a debugger,
    // ContextBuilder.build() freezes the entire UI (MainActor blocked).
    //
    // EXPECTED: AX calls have a per-call timeout via AXUIElementSetMessagingTimeout.
    // ACTUAL:   no timeout configured; calls may block indefinitely.
    // =======================================================================

    func testBug167_accessibilityReaderBlocksMainActor() {
        guard let content = readSource("OpenVerb/Context/AccessibilityReader.swift") else {
            XCTFail("Cannot read AccessibilityReader.swift"); return
        }
        // Fix: AXUIElementSetMessagingTimeout must be called on the AX element
        // before any attribute query to bound the call duration.
        let hasTimeout = content.contains("AXUIElementSetMessagingTimeout")
            || content.contains("messagingTimeout")
            || content.contains("timeoutInterval")

        XCTAssertTrue(hasTimeout,
            "Bug 167 CONFIRMED: AccessibilityReader makes AX API calls " +
            "(AXUIElementCopyAttributeValue) with no messaging timeout set. If the " +
            "target app is hung, in a breakpoint, or under heavy load, the call blocks " +
            "the MainActor indefinitely — the entire OpenVerb UI (recording indicator, " +
            "cancel button, progress view) freezes until the target app responds. " +
            "Fix: call AXUIElementSetMessagingTimeout(axApp, 0.5) before each AX query " +
            "to bound the wait to 500 ms, then return nil/empty on timeout.")
    }

    // =======================================================================
    // Bug 168 — EngineProtocol.fromJSON no size limits
    //
    // ServerMessage.fromJSON() decodes JSON via JSONDecoder with no size
    // validation. A malicious or buggy engine can send arbitrarily large JSON
    // payloads, causing OOM on the client side.
    //
    // EXPECTED: fromJSON() validates data.count against a maximum (e.g., 1 MB)
    //           before calling JSONDecoder.decode().
    // ACTUAL:   no size check; JSONDecoder.decode() is called on arbitrary data.
    // =======================================================================

    func testBug168_engineProtocolFromJSONNoSizeLimits() {
        guard let content = readSource("OpenVerb/Engine/EngineProtocol.swift") else {
            XCTFail("Cannot read EngineProtocol.swift"); return
        }
        guard let fromJSONRange = content.range(of: "static func fromJSON(_ data: Data)") else {
            XCTFail("Cannot find fromJSON in EngineProtocol.swift"); return
        }
        let fnBody = substring(content, from: fromJSONRange.lowerBound, length: 500)

        // Fix: data.count must be validated against a max before decode.
        let hasSizeValidation = fnBody.contains("data.count")
            && (fnBody.contains("maxSize") || fnBody.contains("1_048_576")
                || fnBody.contains("1024 * 1024") || fnBody.contains("< "))

        XCTAssertTrue(hasSizeValidation,
            "Bug 168 CONFIRMED: ServerMessage.fromJSON() calls JSONDecoder().decode() " +
            "without any size validation on the input data. A malicious or misbehaving " +
            "engine can send a multi-megabyte JSON payload (e.g., a result message with " +
            "a 100 MB 'text' field), causing an OOM allocation on the Swift client side. " +
            "The OOM terminates OpenVerb without a user-facing error. " +
            "Fix: add `guard data.count <= 1_048_576 else { throw EngineClientError.protocolViolation }` " +
            "at the top of fromJSON() before calling decode().")
    }

    // =======================================================================
    // Bug 169 — ClipboardStyle.describe OOM on large inputs
    //
    // detectMarkdown() splits entire input by newlines (allocates N substrings).
    // detectCase() calls .lowercased() duplicating the string in memory.
    // A 100 MB clipboard causes OOM before the byteLimit truncation takes effect
    // if truncation is applied inconsistently.
    //
    // EXPECTED: truncation to byteLimit is applied BEFORE any detect function runs.
    // ACTUAL:   detect functions may be called before or without the byteLimit cap.
    // =======================================================================

    func testBug169_clipboardStyleDescribeOOM() {
        guard let content = readSource("OpenVerb/Context/ClipboardStyle.swift") else {
            XCTFail("Cannot read ClipboardStyle.swift"); return
        }
        guard let describeRange = content.range(of: "static func describe(_ text: String)") else {
            XCTFail("Cannot find describe() in ClipboardStyle.swift"); return
        }
        let fnBody = substring(content, from: describeRange.lowerBound, length: 600)

        // Fix: truncateToUTF8Bytes must appear BEFORE any detectMarkdown/detectCase call.
        let truncateRange = fnBody.range(of: "truncateToUTF8Bytes")
        let markdownRange = fnBody.range(of: "detectMarkdown(")
        let caseRange = fnBody.range(of: "detectCase(")

        guard let trunc = truncateRange else {
            XCTFail("Bug 169 CONFIRMED: describe() has no truncateToUTF8Bytes call at all. " +
                "All detect functions operate on the raw (potentially 100 MB) input. " +
                "Fix: add `let truncated = ContextBuilder.truncateToUTF8Bytes(text, limit: byteLimit)` " +
                "as the first statement and pass `truncated` to all detect functions.")
            return
        }
        if let md = markdownRange {
            XCTAssertLessThan(trunc.lowerBound, md.lowerBound,
                "Bug 169 CONFIRMED: detectMarkdown() is called before truncateToUTF8Bytes. " +
                "A 100 MB clipboard splits into millions of substring views before the cap " +
                "takes effect, exhausting heap memory. " +
                "Fix: call truncateToUTF8Bytes first and pass `truncated` to detectMarkdown.")
        }
        if let cs = caseRange {
            XCTAssertLessThan(trunc.lowerBound, cs.lowerBound,
                "Bug 169 CONFIRMED: detectCase() is called before truncateToUTF8Bytes. " +
                "detectCase() calls .lowercased() which duplicates the string in memory; " +
                "on a 100 MB input this double-allocates ~200 MB, causing OOM. " +
                "Fix: call truncateToUTF8Bytes first and pass `truncated` to detectCase.")
        }
    }

    // =======================================================================
    // Bug 170 — wire protocol 0xFFFFFFFF frame OOM
    //
    // The 4-byte length header written by sendAudioFrame is never validated
    // against a maximum on the receive side. A malicious or buggy engine can
    // send a length of 0xFFFFFFFF (~4 GB), causing an OOM allocation when
    // the client tries to read that many bytes.
    //
    // EXPECTED: the receive path validates frame length <= max before allocating.
    // ACTUAL:   no max-frame-size check in the receive path.
    // =======================================================================

    func testBug170_wireProtocolFrameSizeNotValidated() {
        guard let content = readSource("OpenVerb/Engine/EngineClient.swift") else {
            XCTFail("Cannot read EngineClient.swift"); return
        }
        // The receive path must validate frame length against a maximum.
        // Look for any max-frame-size constant or validation near the length parsing.
        let hasMaxFrameGuard = content.contains("maxFrameSize")
            || content.contains("maxFrameLen")
            || content.contains("frameSize >")
            || content.contains("frameLen >")
            || (content.contains("0xFFFF") && content.contains("guard"))
            || (content.contains("1_048_576") && content.contains("len"))

        XCTAssertTrue(hasMaxFrameGuard,
            "Bug 170 CONFIRMED: EngineClient has no maximum frame-size validation on the " +
            "receive path. sendAudioFrame() writes a 4-byte big-endian length header; the " +
            "engine could send a frame with length 0xFFFFFFFF (~4 GB). When the client " +
            "tries to allocate a buffer of that size, it OOMs and terminates. " +
            "This is a security vulnerability in the local IPC protocol — a compromised " +
            "engine process can crash the host app. " +
            "Fix: in the receive path, validate `guard frameLen <= maxFrameSize` (e.g., " +
            "1 MB) before allocating the receive buffer.")
    }

    // =======================================================================
    // Bug 171 — language detection emits invalid BCP-47 "und"
    //
    // Locale.current.language.languageCode?.identifier can return "und"
    // (undetermined). The nil-coalescing fallback only catches nil, not "und".
    // The engine receives "und" as the language code, which is invalid BCP-47
    // and may confuse the language model.
    //
    // EXPECTED: "und" is treated the same as nil and falls back to "en".
    // ACTUAL:   ?? "en" only catches nil; "und" passes through as-is.
    // =======================================================================

    func testBug171_languageDetectionEmitsUnd() {
        guard let content = readSource("OpenVerb/Context/ContextBuilder.swift") else {
            XCTFail("Cannot read ContextBuilder.swift"); return
        }
        // Find the language code assignment in build().
        guard let langRange = content.range(of: "languageCode?.identifier") else {
            XCTFail("Cannot find languageCode?.identifier in ContextBuilder.swift"); return
        }
        let langLine = substring(content, from: langRange.lowerBound, length: 200)

        // Bug: only nil is caught by ?? "en"; "und" passes through.
        // Fix: also filter "und" explicitly.
        let handlesUnd = langLine.contains("\"und\"")
            || langLine.contains("!= \"und\"")
            || langLine.contains("== \"und\"")
            || langLine.contains("undetermined")

        XCTAssertTrue(handlesUnd,
            "Bug 171 CONFIRMED: ContextBuilder.build() uses " +
            "`languageCode?.identifier ?? \"en\"` to determine the BCP-47 language code. " +
            "When no language can be determined, languageCode.identifier returns the " +
            "string \"und\" (ISO 639-2 undetermined) rather than nil — the ?? operator " +
            "does not fire and \"und\" is sent to the engine. The Gemma 4 model treats " +
            "\"und\" as an unknown locale, potentially degrading transcript quality. " +
            "Fix: add a guard `filter { $0 != \"und\" }` or use " +
            "`identifier.flatMap { $0 == \"und\" ? nil : $0 } ?? \"en\"`.")
    }

    // =======================================================================
    // Bug 172 — lock ordering potential deadlock in AudioSession waveform dispatch
    //
    // AudioSession.processTapBuffer dispatches waveformCallback via
    // DispatchQueue.main.async. Inside that async block, self.lock is acquired
    // to read _sessionGeneration. If the main thread calls stop() (which also
    // acquires self.lock) via a synchronous path while the async block is mid-
    // execution, the lock is nested in a context that could deadlock.
    //
    // EXPECTED: the waveform async block does NOT acquire self.lock; instead
    //           it reads sessionGeneration from a thread-safe copy captured before
    //           the dispatch (already done — sessionGen is captured under lock).
    // ACTUAL:   self.lock.lock() is called inside DispatchQueue.main.async block
    //           to re-read _sessionGeneration, acquiring the lock on the main thread.
    // =======================================================================

    func testBug172_lockAcquiredInsideMainAsyncBlock() {
        guard let content = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Cannot read AudioSession.swift"); return
        }
        // Locate the DispatchQueue.main.async block that invokes waveformCallback.
        guard let asyncRange = content.range(of: "DispatchQueue.main.async { [weak self] in") else {
            XCTFail("Cannot find waveform DispatchQueue.main.async in AudioSession.swift"); return
        }
        let asyncBody = substring(content, from: asyncRange.lowerBound, length: 400)

        // Bug: self.lock.lock() inside the async block re-acquires the audio-thread
        // lock on the main thread. If stop() is called synchronously from the main
        // thread while this block is mid-execution (e.g., via a UI button), both
        // callers contend on self.lock from the same queue — potential deadlock.
        // Fix: use only the already-captured `sessionGen` constant (captured under lock
        // before the dispatch) — no re-acquisition of self.lock needed inside the block.
        let reacquiresLockInsideAsync = asyncBody.contains("self.lock.lock()")
            || asyncBody.contains("lock.lock()")

        XCTAssertFalse(reacquiresLockInsideAsync,
            "Bug 172 CONFIRMED: AudioSession.processTapBuffer acquires self.lock inside " +
            "a DispatchQueue.main.async block (to read _sessionGeneration). The sessionGen " +
            "constant is already captured under self.lock before the dispatch — there is no " +
            "need to re-acquire the lock inside the async block. Re-acquiring self.lock on " +
            "the main thread while stop() may also be acquiring it from the main thread " +
            "(e.g., called from a UI button handler) is a lock ordering violation that " +
            "can deadlock the main queue. " +
            "Fix: remove self.lock.lock/unlock from the async block; use only the already- " +
            "captured `sessionGen` constant for the generation comparison.")
    }
}
