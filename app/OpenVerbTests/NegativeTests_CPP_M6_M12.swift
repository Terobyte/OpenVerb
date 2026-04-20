import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// NegativeTests_CPP_M6_M12 — source-inspection tests for C++ engine bugs.
//
// Every test asserts CORRECT / FIXED behaviour.
// FAILS while the bug exists.  GREEN = bug fixed.
//
// Bugs covered:
//   M6  — g_interrupted global kills entire server (session.cpp)
//   M7  — polish inference runs on dead connection after ConnectionClosed (session.cpp)
//   M8  — reinterpret_cast<int16_t*> no alignment/even-byte guard (session.cpp)
//   M9  — load_thread.join() blocks indefinitely on hung model load (session.cpp)
//   M10 — strip_trailing_punct ASCII-only, drops CJK/Unicode punct (parser.cpp)
//   M11 — empty audio_pcm + no VAD → null bitmap → crash (llama_context.cpp)
//   M12 — fopen failure on rotation silently drops all subsequent logs (log.cpp)
// ---------------------------------------------------------------------------

final class NegativeTests_CPP_M6_M12: XCTestCase {

    // Reads a source file by path relative to the Swift package working
    // directory (i.e., the `app/` folder).  C++ engine paths use `../engine/`.
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
    // Bug M6 — g_interrupted is a process-wide global; a SIGINT kills every
    // active session instead of only the one that was targeted.
    //
    // EXPECTED: The main run-loop condition (session.cpp line ~173) uses the
    //           per-session atomic `stop_requested_` (already present in
    //           stop()) rather than the global `g_interrupted` so that a
    //           per-session cancellation does not bleed into sibling sessions.
    //
    // ACTUAL:   The while condition reads
    //             `!g_interrupted.load(std::memory_order_relaxed)`
    //           making any SIGINT terminate every session simultaneously.
    //
    // Fix: Replace `g_interrupted` in the run() while-condition with
    //      `stop_requested_` so cancellation is scoped to one session.
    // =======================================================================

    func testBugM6_sessionRunLoopUsesPerSessionStopNotGlobalInterrupt() {
        guard let src = readSource("../engine/src/ipc/session.cpp") else {
            XCTFail("Cannot read session.cpp"); return
        }

        // The run() while-condition must NOT gate on g_interrupted alone.
        // After the fix it should use stop_requested_ instead (scoped to
        // one session) or drop the global flag from the loop condition entirely.
        //
        // Current buggy code (session.cpp ~line 172-173):
        //   while (state != State::DESTROYED &&
        //          !g_interrupted.load(std::memory_order_relaxed)) {
        //
        // The two-line pattern is detected by checking that the while-loop block
        // contains `State::DESTROYED` on one line and `g_interrupted` close by.
        let runLoopBlock = extractRunLoopCondition(src)
        let usesGlobalInterruptInRunLoop =
            runLoopBlock.contains("g_interrupted") &&
            runLoopBlock.contains("State::DESTROYED")

        XCTAssertFalse(usesGlobalInterruptInRunLoop,
            "Bug M6 CONFIRMED: session.cpp run() while-condition references " +
            "g_interrupted, a process-wide atomic. A single SIGINT terminates " +
            "every active session. " +
            "Fix: Remove g_interrupted from the run() while-condition; gate " +
            "the loop only on `state != State::DESTROYED` and `!stop_requested_` " +
            "so that per-session cancellation is isolated.")
    }

    // =======================================================================
    // Bug M7 — polish inference executes even after the client has
    // disconnected (ConnectionClosed thrown from recv_binary_frame).
    //
    // session.cpp lines 341–347: after the worker joins and returns the
    // accumulated transcript, `engine.polish_text()` is called without
    // first verifying that the socket `fd` is still alive.  This wastes
    // GPU time computing a result that can never be delivered.
    //
    // EXPECTED: Before calling `engine.polish_text()` (or `send_polish_started`)
    //           the code checks whether the connection is still live, e.g. by
    //           testing `pipeline_active_`, a liveness flag, or by wrapping
    //           the entire polish block in a try/catch that skips on dead fd.
    //
    // ACTUAL: `send_polish_started(fd)` and `engine.polish_text(...)` are
    //          called unconditionally after the sentinel is received; the only
    //          guard is an outer catch(...) that swallows the ConnectionClosed
    //          exception but still burns GPU for the full polish pass.
    //
    // Fix: Add `if (!pipeline_active_.load(...)) { /* skip polish */ }` or
    //      equivalent liveness check before calling polish_text().
    // =======================================================================

    func testBugM7_polishInferenceGatedOnConnectionLiveness() {
        guard let src = readSource("../engine/src/ipc/session.cpp") else {
            XCTFail("Cannot read session.cpp"); return
        }

        // After the fix, there must be a liveness/connection check immediately
        // before the polish block.  Accepted patterns:
        //   • pipeline_active_ checked before send_polish_started / polish_text
        //   • is_connected() guard
        //   • early return / continue on dead fd before polish
        //
        // The simplest proxy: the fix introduces a conditional expression that
        // mentions pipeline_active_ (or a similar sentinel) *in the same block*
        // where polish_text is called.
        let polishBlock = extractPolishBlock(src)
        let hasLivenessGuard = polishBlock.contains("pipeline_active_") ||
                               polishBlock.contains("is_connected") ||
                               polishBlock.contains("connection_alive") ||
                               polishBlock.contains("fd_valid")

        XCTAssertTrue(hasLivenessGuard,
            "Bug M7 CONFIRMED: session.cpp calls engine.polish_text() after a " +
            "ConnectionClosed path without first checking connection liveness. " +
            "GPU cycles are wasted polishing a result that cannot be sent. " +
            "Fix: Guard the polish block with a liveness check (e.g. " +
            "`if (pipeline_active_.load(std::memory_order_relaxed))`) before " +
            "calling send_polish_started / engine.polish_text.")
    }

    /// Extracts ~200 chars around the run() outer while-loop condition.
    /// The condition is split across two source lines in the current code.
    private func extractRunLoopCondition(_ src: String) -> String {
        // Find the while(state != ...) controlling the main state machine.
        guard let r = src.range(of: "state != State::DESTROYED") else { return "" }
        let start = src.index(r.lowerBound,
                              offsetBy: -30,
                              limitedBy: src.startIndex) ?? src.startIndex
        let end   = src.index(r.upperBound,
                              offsetBy: 120,
                              limitedBy: src.endIndex) ?? src.endIndex
        return String(src[start ..< end])
    }

    /// Extracts the text of the polish inference block from session.cpp.
    /// Looks for the region between `send_polish_started` and `send_polished_result`.
    private func extractPolishBlock(_ src: String) -> String {
        guard let startRange = src.range(of: "send_polish_started"),
              let endRange   = src.range(of: "send_polished_result") else {
            return ""
        }
        // Return a window of ~400 chars before send_polish_started so any
        // preceding guard is included.
        let windowStart = src.index(startRange.lowerBound,
                                    offsetBy: -400,
                                    limitedBy: src.startIndex) ?? src.startIndex
        return String(src[windowStart ..< endRange.upperBound])
    }

    // =======================================================================
    // Bug M8 — raw reinterpret_cast<const int16_t*> on frame bytes with no
    // alignment guarantee and no check that the byte count is even.
    //
    // session.cpp lines 364–366:
    //   const int16_t* samples = reinterpret_cast<const int16_t*>(frame.data());
    //   int n_samples = static_cast<int>(frame.size() / sizeof(int16_t));
    //
    // Two sub-bugs:
    //   a) `frame.data()` (uint8_t*) may not be 2-byte-aligned; UB per C++ std.
    //   b) If `frame.size()` is odd, integer division silently drops the last byte.
    //
    // EXPECTED (after fix):
    //   • byte count evenness is asserted / guarded before the cast, e.g.
    //       `if (frame.size() % 2 != 0) { /* log & skip or truncate */ }`
    //   • OR data is copied into an aligned int16_t buffer via memcpy.
    //
    // ACTUAL: No such guard exists; the division truncates silently.
    //
    // Fix: Add an even-size guard and replace the pointer cast with a memcpy
    //      into `std::vector<int16_t>` so alignment is guaranteed.
    // =======================================================================

    func testBugM8_pcmCastHasAlignmentAndEvenBytesGuard() {
        guard let src = readSource("../engine/src/ipc/session.cpp") else {
            XCTFail("Cannot read session.cpp"); return
        }

        // After the fix one of these patterns must appear near the PCM cast site:
        //   • frame.size() % 2  (even-byte guard)
        //   • memcpy             (safe copy into aligned buffer)
        //   • std::vector<int16_t> samples_buf (or similar aligned buffer)
        let castRegion = extractCastRegion(src)

        let hasEvenGuard  = castRegion.contains("% 2") || castRegion.contains("%2")
        let hasSafeCopy   = castRegion.contains("memcpy") ||
                            castRegion.contains("vector<int16_t>") ||
                            castRegion.contains("aligned")

        XCTAssertTrue(hasEvenGuard || hasSafeCopy,
            "Bug M8 CONFIRMED: session.cpp casts frame.data() to int16_t* via " +
            "reinterpret_cast with no alignment guarantee and no check that " +
            "frame.size() is even. Odd byte counts silently drop the last sample. " +
            "Fix: Add `if (frame.size() % 2 != 0) { /* handle */ }` guard and " +
            "copy into an aligned std::vector<int16_t> via memcpy instead of " +
            "using a raw reinterpret_cast.")
    }

    /// Extracts ~400 chars around the reinterpret_cast<const int16_t*> site.
    private func extractCastRegion(_ src: String) -> String {
        guard let r = src.range(of: "reinterpret_cast<const int16_t*>") else {
            return ""
        }
        let start = src.index(r.lowerBound,
                               offsetBy: -50,
                               limitedBy: src.startIndex) ?? src.startIndex
        let end   = src.index(r.upperBound,
                               offsetBy: 350,
                               limitedBy: src.endIndex) ?? src.endIndex
        return String(src[start ..< end])
    }

    // =======================================================================
    // Bug M9 — load_thread.join() called unconditionally after wait_for()
    // returns `future_status::timeout`, blocking the session thread forever
    // if the model load hangs (e.g. corrupt file, I/O stall).
    //
    // session.cpp lines 241–245:
    //   if (status != std::future_status::ready) {
    //       timed_out = true;
    //       LOG_WARN("session: model load timed out ...");
    //       load_thread.join();   // <-- blocks indefinitely if hung
    //
    // EXPECTED (after fix): The timeout path must NOT call join() when the
    // load thread may be stuck.  Acceptable patterns:
    //   • load_thread.detach() so the session can proceed
    //   • A second watchdog deadline before join()
    //   • Using a std::future with wait_for + detach on second timeout
    //
    // ACTUAL: A hung model load freezes the session thread permanently because
    // join() is called unconditionally in the timeout branch.
    //
    // Fix: Replace `load_thread.join()` in the timed_out branch with
    //      `load_thread.detach()` (accepting the leaked thread as a trade-off)
    //      or add a second timed-join with a short absolute deadline.
    // =======================================================================

    func testBugM9_loadThreadTimeoutPathDoesNotCallBlockingJoin() {
        guard let src = readSource("../engine/src/ipc/session.cpp") else {
            XCTFail("Cannot read session.cpp"); return
        }

        // Locate the timed_out branch.  After the fix, the block between
        // `timed_out = true` and the closing brace must NOT contain a bare
        // `load_thread.join()` — it should use detach() or a second timed wait.
        let timedOutBlock = extractTimedOutBlock(src)

        // Bare join() in the timed_out path is the bug.
        let hasBlockingJoin = timedOutBlock.contains("load_thread.join()")
        // A detach is the preferred fix.
        let hasDetach       = timedOutBlock.contains("load_thread.detach()")

        // The test passes when there is no blocking join OR when detach is used.
        let isFixed = !hasBlockingJoin || hasDetach

        XCTAssertTrue(isFixed,
            "Bug M9 CONFIRMED: session.cpp calls load_thread.join() in the " +
            "timed_out branch of WAITING_READY. If the model load hangs " +
            "(corrupt GGUF, I/O stall) join() blocks the session thread forever. " +
            "Fix: Replace `load_thread.join()` with `load_thread.detach()` in " +
            "the timeout path so the session can return an error to the client " +
            "immediately, or add a second bounded wait before join().")
    }

    /// Extracts the text of the timed_out branch in WAITING_READY (~200 chars
    /// starting from the first `timed_out = true` assignment).
    private func extractTimedOutBlock(_ src: String) -> String {
        guard let r = src.range(of: "timed_out = true") else { return "" }
        let end = src.index(r.upperBound,
                            offsetBy: 300,
                            limitedBy: src.endIndex) ?? src.endIndex
        return String(src[r.lowerBound ..< end])
    }

    // =======================================================================
    // Bug M10 — strip_trailing_punct() in parser.cpp handles only four ASCII
    // punctuation characters (. , ! ?) and ignores the full Unicode punctuation
    // space: CJK fullstop 。(U+3002), enumeration comma 、(U+3001), fullwidth
    // exclamation ！(U+FF01), fullwidth question ？(U+FF1F), right corner bracket
    // 」(U+300D), CJK right parenthesis ）(U+FF09), etc.
    //
    // EXPECTED (after fix): strip_trailing_punct handles at least the common
    // CJK/fullwidth punctuation characters, e.g. via:
    //   • an explicit list of UTF-8 byte sequences for CJK punct, or
    //   • a Unicode category check using a helper function
    //
    // ACTUAL: Only `. , ! ?` are stripped; CJK punct passes through to output.
    //
    // Fix: Extend `strip_trailing_punct` to recognise multi-byte Unicode
    //      punctuation at the string tail (e.g. U+3002, U+FF01, U+FF1F, etc.).
    // =======================================================================

    func testBugM10_stripTrailingPunctHandlesUnicodeCJKPunct() {
        guard let src = readSource("../engine/src/commands/parser.cpp") else {
            XCTFail("Cannot read parser.cpp"); return
        }

        // After the fix, strip_trailing_punct must handle multi-byte (Unicode)
        // punctuation.  Any of these signals a sufficient fix:
        //   • Explicit hex escape for CJK fullstop bytes (0xE3 0x80 0x82 = 。)
        //   • The string literal 。 or ）or ！ inside strip_trailing_punct
        //   • A reference to "unicode" / "fullwidth" / "cjk" in a comment
        //     inside or adjacent to strip_trailing_punct
        //   • A loop that walks backwards over multi-byte sequences
        let strippingFn = extractFunctionBody(src, named: "strip_trailing_punct")

        let handlesUnicode = strippingFn.contains("0xE3") ||       // CJK block lead byte
                             strippingFn.contains("0xFF") ||       // fullwidth lead byte
                             strippingFn.contains("\\u3002") ||
                             strippingFn.contains("\\uFF01") ||
                             strippingFn.contains("unicode") ||
                             strippingFn.contains("Unicode") ||
                             strippingFn.contains("fullwidth") ||
                             strippingFn.contains("cjk") ||
                             strippingFn.contains("CJK") ||
                             strippingFn.contains("\u{3002}") ||   // 。 literal
                             strippingFn.contains("\u{FF01}") ||   // ！ literal
                             strippingFn.contains("\u{FF1F}")       // ？ literal

        XCTAssertTrue(handlesUnicode,
            "Bug M10 CONFIRMED: parser.cpp strip_trailing_punct() only strips " +
            "ASCII `. , ! ?`. CJK/fullwidth punctuation (。！？） etc.) is not " +
            "stripped and leaks into transcription output. " +
            "Fix: Extend strip_trailing_punct to handle Unicode punctuation at " +
            "the string tail by decoding the trailing UTF-8 sequence and checking " +
            "it against a Unicode punctuation set (U+3002, U+FF01, U+FF1F, " +
            "U+FF0C, U+FF09, U+300D, etc.).")
    }

    /// Extracts the body of a named C++ static function (heuristic: from the
    /// line containing `functionName` to the first standalone `}` at col 0).
    private func extractFunctionBody(_ src: String, named name: String) -> String {
        guard let fnRange = src.range(of: name) else { return "" }
        // Take up to 600 chars after the function name declaration.
        let end = src.index(fnRange.lowerBound,
                            offsetBy: 600,
                            limitedBy: src.endIndex) ?? src.endIndex
        return String(src[fnRange.lowerBound ..< end])
    }

    // =======================================================================
    // Bug M11 — LlamaContext::infer() called with empty audio_pcm and no VAD
    // pre-filter creates an mtmd_bitmap from a zero-length float array.
    // mtmd_bitmap_init_from_audio(0, ptr) may return nullptr; the existing
    // null-check throws, but the real hazard is that some mtmd builds accept
    // n_samples=0 and return a non-null-but-invalid bitmap that causes a
    // null-pointer dereference deep inside the feature extraction path.
    //
    // llama_context.cpp lines 373–377: the guard only checks `!audio_bmp`
    // after the call; there is no early-return before calling
    // mtmd_bitmap_init_from_audio when audio_pcm is empty.
    //
    // EXPECTED (after fix): infer() returns early (or throws) at the top if
    // audio_pcm is empty, before any mtmd call is made.
    //
    // ACTUAL: Zero-length audio reaches mtmd_bitmap_init_from_audio; some
    // builds crash inside feature extraction.
    //
    // Fix: Add at the top of infer() (after the sample_rate check):
    //   `if (audio_pcm.empty()) throw std::invalid_argument("empty audio");`
    //   or return an empty string early.
    // =======================================================================

    func testBugM11_inferGuardsAgainstEmptyAudioPcm() {
        guard let src = readSource("../engine/src/inference/llama_context.cpp") else {
            XCTFail("Cannot read llama_context.cpp"); return
        }

        // After the fix, there must be an early guard for empty audio_pcm
        // BEFORE the call to mtmd_bitmap_init_from_audio.
        // Acceptable patterns:
        //   • audio_pcm.empty() check that returns or throws
        //   • audio_pcm.size() == 0 equivalent
        //   • A comment referencing the empty-audio guard

        // Locate the infer() function body (starts after its signature).
        let inferBody = extractInferBody(src)

        // Find position of mtmd_bitmap_init_from_audio call.
        guard let bitmapCallRange = inferBody.range(of: "mtmd_bitmap_init_from_audio") else {
            // If the call doesn't exist at all the function was rewritten — pass.
            return
        }

        // Everything before the bitmap call must contain an empty-audio guard.
        let beforeBitmapCall = String(inferBody[inferBody.startIndex ..< bitmapCallRange.lowerBound])

        let hasEmptyGuard = beforeBitmapCall.contains("audio_pcm.empty()") ||
                            beforeBitmapCall.contains("audio_pcm.size() == 0") ||
                            beforeBitmapCall.contains("audio_f32.empty()")

        XCTAssertTrue(hasEmptyGuard,
            "Bug M11 CONFIRMED: llama_context.cpp infer() passes a zero-length " +
            "float array to mtmd_bitmap_init_from_audio when audio_pcm is empty " +
            "and no VAD pre-filters the call. Some mtmd builds accept n_samples=0 " +
            "and return an invalid bitmap that crashes inside feature extraction. " +
            "Fix: Add `if (audio_pcm.empty()) return \"\";` (or throw) at the top " +
            "of infer() — before any mtmd call — to short-circuit the empty case.")
    }

    /// Extracts the body of LlamaContext::infer() — from its opening `{` to
    /// roughly 3000 chars in (enough to cover the bitmap call site).
    private func extractInferBody(_ src: String) -> String {
        guard let sigRange = src.range(of: "LlamaContext::infer(") else { return src }
        // Find the opening brace after the signature.
        guard let braceRange = src.range(of: "{", range: sigRange.upperBound ..< src.endIndex) else {
            return String(src[sigRange.lowerBound...])
        }
        let end = src.index(braceRange.upperBound,
                            offsetBy: 3000,
                            limitedBy: src.endIndex) ?? src.endIndex
        return String(src[braceRange.upperBound ..< end])
    }

    // =======================================================================
    // Bug M12 — log.cpp rotate_log(): when fopen() fails after rotating the
    // files, s_log_file is left as nullptr.  All subsequent calls to
    // log_detail::write() silently skip the `if (s_log_file)` branch, so
    // every log line after a rotation failure is silently discarded.
    //
    // log.cpp lines 52–55:
    //   s_log_file = std::fopen(s_log_path.c_str(), "a");
    //   if (!s_log_file) {
    //       std::fprintf(stderr, "[log] rotate: fopen failed: ...\n");
    //   }
    //   // falls through — s_log_file stays null; further writes silently lost
    //
    // EXPECTED (after fix): On fopen failure the code falls back to stderr for
    // subsequent writes, OR sets an error flag that callers can query, OR retries
    // the open, so that log output is not silently dropped.
    //
    // ACTUAL: s_log_file is nullptr after failed rotation; write() silently
    //         skips the file branch for every subsequent call.
    //
    // Fix: In rotate_log(), on fopen failure assign s_log_file = stderr (so
    // future writes still reach stderr) or set a global error flag and
    // propagate it to callers.
    // =======================================================================

    func testBugM12_logRotationFopenFailureFallsBackToStderr() {
        guard let src = readSource("../engine/src/config/log.cpp") else {
            XCTFail("Cannot read log.cpp"); return
        }

        // Extract the rotate_log() function body.
        let rotateBody = extractFunctionBody(src, named: "rotate_log")

        // After the fix, the fopen-failure branch in rotate_log must do one of:
        //   a) assign s_log_file = stderr   (fallback to stderr)
        //   b) set a persistent error flag  (e.g. s_rotate_failed = true)
        //   c) retry the open (another fopen call inside the if-block)
        //
        // The plain `fprintf(stderr, ...)` + fall-through that currently exists
        // is NOT sufficient — it does not prevent silent log loss.

        let hasFallbackToStderr = rotateBody.contains("s_log_file = stderr") ||
                                  rotateBody.contains("s_log_file=stderr")

        let hasFallbackFlag     = rotateBody.contains("s_rotate_failed") ||
                                  rotateBody.contains("s_log_error") ||
                                  rotateBody.contains("s_fallback")

        let hasRetryOpen        = {
            // Two fopen calls inside rotate_log (original + retry)
            let count = rotateBody.components(separatedBy: "fopen").count - 1
            return count >= 2
        }()

        XCTAssertTrue(hasFallbackToStderr || hasFallbackFlag || hasRetryOpen,
            "Bug M12 CONFIRMED: log.cpp rotate_log() sets s_log_file = nullptr " +
            "when fopen() fails, then only prints a one-time stderr warning. " +
            "All subsequent log_detail::write() calls silently skip the file " +
            "branch because `if (s_log_file)` is false. " +
            "Fix: On fopen failure, set `s_log_file = stderr` so future writes " +
            "still reach stderr, OR set a persistent flag and propagate the " +
            "error so callers know logging is degraded.")
    }
}
