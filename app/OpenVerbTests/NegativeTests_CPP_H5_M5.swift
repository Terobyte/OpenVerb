import XCTest
@testable import OpenVerb

// Negative tests for: H5, H6, M1, M2, M3, M4, M5
// Tests FAIL while the bug exists. GREEN = bug fixed.
//
// Bug H5 — llama_context.cpp: no pre-flight ctx_size overflow check
// Bug H6 — protocol.cpp: send_json has no mutex protecting the shared fd
// Bug M1 — session.cpp: pipeline_active_ stores use memory_order_relaxed
// Bug M2 — ring_buffer.cpp: read_all() holds no mutex — races with reset()
// Bug M3 — resampler.cpp: i1 cast to int — overflows on >~37h of audio
// Bug M4 — capture.cpp: stop() during start() leaves queue orphaned
// Bug M5 — chunk_queue.cpp: audio_ms_ decrement has no lower-bound guard
final class NegativeTests_CPP_H5_M5: XCTestCase {

    // -------------------------------------------------------------------------
    // readSource — resolves a path relative to the Swift test runner CWD (app/).
    // -------------------------------------------------------------------------
    private func readSource(_ relativePath: String) -> String? {
        let direct = URL(fileURLWithPath: relativePath)
        if let content = try? String(contentsOf: direct, encoding: .utf8) { return content }
        if let base = Bundle.main.resourceURL {
            let bundled = base.appendingPathComponent(relativePath)
            if let content = try? String(contentsOf: bundled, encoding: .utf8) { return content }
        }
        return nil
    }

    // =========================================================================
    // Bug H5 — No pre-flight validation: prompt + audio + generation <= ctx_size
    //
    // llama_context.cpp calls mtmd_helper_eval_chunks() and then runs up to
    // MAX_NEW_TOKENS decode steps without first verifying that the combined
    // token count (prompt + audio + max new tokens) fits within ctx_size.
    //
    // Fix: add a guard before mtmd_helper_eval_chunks that computes
    //   n_prompt_tokens + n_audio_tokens + MAX_NEW_TOKENS
    // and returns a clear error if that sum exceeds impl_->ctx_size.
    // =========================================================================
    func testBugH5_NoPreflightContextSizeCheck() throws {
        guard let src = readSource("../engine/src/inference/llama_context.cpp") else {
            XCTFail("Bug H5 CONFIRMED: cannot read llama_context.cpp")
            return
        }

        // The fix must include a comparison against ctx_size (or n_ctx) before
        // the eval/decode path starts. Look for a guard that mentions both a
        // token-count sum and ctx_size / n_ctx in the same logical block.
        //
        // Patterns the fix should introduce:
        //   • a variable holding the total (e.g. n_total_tokens, total_tokens)
        //     OR an inline sum involving n_prompt and MAX_NEW_TOKENS
        //   • compared against ctx_size or impl_->ctx_size or n_ctx
        //   • followed by an error return/throw when the sum exceeds the limit
        //
        // The buggy code has none of this: mtmd_helper_eval_chunks is called
        // immediately after tokenization with no such check present.

        let hasPreflightGuard =
            // A comparison of some token total against ctx_size
            (src.contains("n_ctx") || src.contains("ctx_size"))
            && (src.contains("n_total") || src.contains("total_tokens") ||
                src.contains("n_prompt_tokens") || src.contains("n_prefill"))
            && (src.contains("exceeds") || src.contains("> impl_->ctx_size") ||
                src.contains(">= impl_->ctx_size") || src.contains("context window") ||
                src.contains("ctx overflow") || src.contains("too large for context"))

        XCTAssertTrue(
            hasPreflightGuard,
            "Bug H5 CONFIRMED: llama_context.cpp has no pre-flight check that "
            + "(n_prompt_tokens + n_audio_tokens + MAX_NEW_TOKENS) <= ctx_size. "
            + "Fix: before calling mtmd_helper_eval_chunks, compute total token "
            + "count and return a clear error if it exceeds impl_->ctx_size."
        )
    }

    // =========================================================================
    // Bug H6 — protocol.cpp: send_json not thread-safe on a shared fd
    //
    // send_json() does a multi-write loop on the fd with no mutex.
    // Multiple callers (send_partial_result, send_queue_status, send_error, etc.)
    // can reach it concurrently from different threads, interleaving their writes.
    //
    // Fix: declare a std::mutex (e.g. send_mutex) and lock it inside send_json
    // or wrap every call site with that mutex.
    // =========================================================================
    func testBugH6_SendJsonNotThreadSafe() throws {
        guard let src = readSource("../engine/src/ipc/protocol.cpp") else {
            XCTFail("Bug H6 CONFIRMED: cannot read protocol.cpp")
            return
        }

        // The fix must introduce a mutex that guards send_json's write loop.
        // Acceptable patterns:
        //   • a std::mutex / std::lock_guard inside send_json itself
        //   • a static or file-scope mutex locked before the write loop
        let hasSendMutex =
            src.contains("std::mutex") && src.contains("send_json")
            && (src.contains("lock_guard") || src.contains("unique_lock") ||
                src.contains("scoped_lock"))

        XCTAssertTrue(
            hasSendMutex,
            "Bug H6 CONFIRMED: send_json in protocol.cpp performs a multi-write "
            + "loop on a shared fd with no mutex. Concurrent callers from "
            + "different threads can interleave partial writes, producing "
            + "corrupted framing. "
            + "Fix: protect the write loop in send_json with a std::mutex."
        )
    }

    // =========================================================================
    // Bug M1 — session.cpp: pipeline_active_ stores use memory_order_relaxed
    //
    // stop() writes:  pipeline_active_.store(false, std::memory_order_relaxed)
    // The STREAMING_AUDIO sentinel path also uses memory_order_relaxed.
    // The VadScanner callback reads with memory_order_relaxed too.
    // With relaxed ordering the audio callback can observe pipeline_active_==true
    // after the pipeline has been freed, causing a use-after-free.
    //
    // Fix: all stores to pipeline_active_ must use memory_order_release;
    //      all loads must use memory_order_acquire.
    // =========================================================================
    func testBugM1_PipelineActiveRelaxedOrdering() throws {
        guard let src = readSource("../engine/src/ipc/session.cpp") else {
            XCTFail("Bug M1 CONFIRMED: cannot read session.cpp")
            return
        }

        // The bug: at least one store to pipeline_active_ uses memory_order_relaxed.
        // The fix removes ALL relaxed stores/loads of pipeline_active_ and replaces
        // them with release/acquire.

        // Confirm the buggy pattern is gone: no relaxed store to pipeline_active_
        let relaxedStorePattern = "pipeline_active_.store(false, std::memory_order_relaxed)"
        let hasRelaxedStore = src.contains(relaxedStorePattern)

        XCTAssertFalse(
            hasRelaxedStore,
            "Bug M1 CONFIRMED: session.cpp stores pipeline_active_ with "
            + "memory_order_relaxed in stop() and/or the sentinel handler. "
            + "Relaxed ordering allows the audio callback thread to observe "
            + "pipeline_active_==true after teardown, causing use-after-free. "
            + "Fix: use memory_order_release for all stores and "
            + "memory_order_acquire for all loads of pipeline_active_."
        )
    }

    // =========================================================================
    // Bug M2 — ring_buffer.cpp: reset() + concurrent read_all() race
    //
    // read_all() loads read_idx_ with memory_order_relaxed while reset()
    // holds write_mutex_ and zeroes both indices with seq_cst.
    // read_all() holds NO mutex at all, so it can race with reset():
    //   1. read_all reads r = N (old value)
    //   2. reset() sets both indices to 0
    //   3. read_all computes avail = 0 - N → wraps to huge size_t → reads garbage
    //
    // Fix: read_all() must acquire write_mutex_ (or a dedicated read lock)
    //      before loading either index.
    // =========================================================================
    func testBugM2_RingBufferReadAllResetRace() throws {
        guard let src = readSource("../engine/src/audio/ring_buffer.cpp") else {
            XCTFail("Bug M2 CONFIRMED: cannot read ring_buffer.cpp")
            return
        }

        // The buggy read_all loads read_idx_ with no lock held.
        // The fix adds a mutex acquisition at the top of read_all().
        //
        // Detect the fix: read_all() must acquire write_mutex_ or a second mutex
        // before it touches any index. We look for a lock_guard / unique_lock
        // inside read_all's body — i.e., the word "lock" appearing between
        // "read_all" and the next function definition.

        // Extract the read_all function body heuristically.
        let readAllRange = src.range(of: "RingBuffer::read_all()")
        let resetRange   = src.range(of: "RingBuffer::reset()")

        let readAllBodyHasLock: Bool
        if let ra = readAllRange, let rs = resetRange, ra.upperBound < rs.lowerBound {
            let body = String(src[ra.upperBound..<rs.lowerBound])
            readAllBodyHasLock = body.contains("lock_guard") || body.contains("unique_lock")
                              || body.contains("scoped_lock") || body.contains("lock(")
        } else {
            // Cannot extract body — assume not fixed
            readAllBodyHasLock = false
        }

        XCTAssertTrue(
            readAllBodyHasLock,
            "Bug M2 CONFIRMED: ring_buffer.cpp read_all() loads read_idx_ with "
            + "no mutex held while reset() zeroes both indices under write_mutex_. "
            + "Concurrent execution causes read_idx_ to overtake write_idx_, "
            + "producing reads of uninitialized memory. "
            + "Fix: read_all() must acquire write_mutex_ (or equivalent) before "
            + "reading or modifying either index."
        )
    }

    // =========================================================================
    // Bug M3 — resampler.cpp: integer overflow in resample_channel after >12h
    //
    // In resample_channel(), the left-neighbour index i1 is computed as:
    //   const auto i1 = static_cast<int>(pos);
    // where pos = i * ratio and i is std::size_t.
    // For 12+ hours of audio at 16 kHz, i can exceed 2^31-1 (~2.1 B samples),
    // causing i1 (int) to overflow — producing negative indices and
    // silent data corruption.
    //
    // Fix: use int64_t or ptrdiff_t for i1 instead of int.
    // =========================================================================
    func testBugM3_ResamplerInt32OverflowOnLongAudio() throws {
        guard let src = readSource("../engine/src/audio/resampler.cpp") else {
            XCTFail("Bug M3 CONFIRMED: cannot read resampler.cpp")
            return
        }

        // The buggy line:  const auto i1  = static_cast<int>(pos);
        // The fix changes the cast to int64_t, ptrdiff_t, or ssize_t.

        let buggyPattern = "static_cast<int>(pos)"
        let hasBuggyPattern = src.contains(buggyPattern)

        XCTAssertFalse(
            hasBuggyPattern,
            "Bug M3 CONFIRMED: resample_channel() in resampler.cpp computes the "
            + "left-neighbour index as `static_cast<int>(pos)`. For recordings "
            + "longer than ~37 hours at 16 kHz, `pos` exceeds INT_MAX, overflowing "
            + "i1 (int) to a negative value — producing out-of-bounds access and "
            + "silent audio corruption. Even at 12 h with 44.1 kHz source the "
            + "intermediate sample index hits ~1.9B, dangerously close to overflow. "
            + "Fix: declare i1 as int64_t (or ptrdiff_t) instead of int."
        )
    }

    // =========================================================================
    // Bug M4 — capture.cpp: stop() during start() leaves audio queue orphaned
    //
    // stop() has an unconditional early-return on line 88:
    //   if (!impl_->capturing.load(std::memory_order_acquire)) return;
    // start() sets capturing=true only AFTER AudioQueueStart() succeeds (line 84).
    // If stop() is called while start() is between AudioQueueNewInput (which
    // stores a non-null impl_->queue) and the final capturing.store(true),
    // stop() sees capturing==false, returns immediately, and leaves the queue
    // running with no owner — an orphaned AudioQueue that can never be disposed.
    //
    // Fix: remove the unconditional early-return in stop() and instead handle
    // the case where impl_->queue != nullptr even when capturing is false, OR
    // have start() check a cancellation flag before calling AudioQueueStart.
    // =========================================================================
    func testBugM4_StopDuringStartOrphansQueue() throws {
        guard let src = readSource("../engine/src/audio/capture.cpp") else {
            XCTFail("Bug M4 CONFIRMED: cannot read capture.cpp")
            return
        }

        // The buggy stop() body (verbatim):
        //   if (!impl_->capturing.load(std::memory_order_acquire)) return;
        //   impl_->capturing.store(false, ...);
        //   if (impl_->queue) { AudioQueueStop/Dispose... }
        //
        // The unconditional early-return means the queue-disposal block on the
        // lines below it is unreachable when stop() races with start().
        //
        // The fix must ensure stop() handles a partially-initialised queue.
        // One canonical fix: remove the early-return so stop() always reaches
        // the impl_->queue check. Another: add a dedicated cancellation flag that
        // start() checks before AudioQueueStart.
        //
        // Detect the bug: the early-return guard is still the FIRST statement in
        // stop(). If the fix is applied, either:
        //   (a) that exact early-return line is gone, or
        //   (b) a cancellation flag (stop_requested_, cancel_, etc.) was added
        //       to start() so it abandons before AudioQueueStart when racing.

        // Extract stop() body (between "AudioCapture::stop()" and the next fn).
        let earlyReturnPattern = "if (!impl_->capturing.load(std::memory_order_acquire)) return;"

        let stopBodyHasEarlyReturn: Bool = {
            guard let stopRange = src.range(of: "AudioCapture::stop()") else { return false }
            let afterStop = String(src[stopRange.upperBound...])
            // Only inspect up to the next function definition.
            let nextFn = afterStop.range(of: "\nbool AudioCapture::")
                      ?? afterStop.range(of: "\nvoid AudioCapture::")
                      ?? afterStop.endIndex..<afterStop.endIndex
            let body = String(afterStop[..<nextFn.lowerBound])
            return body.contains(earlyReturnPattern)
        }()

        // Pattern B: start() has been fixed with a cancellation flag check.
        let startChecksCancellation: Bool = {
            guard let startRange = src.range(of: "AudioCapture::start(") else { return false }
            let startBody = String(src[startRange.upperBound...])
            let nextFn = startBody.range(of: "\nvoid AudioCapture::stop")
                      ?? startBody.range(of: "\nbool AudioCapture::")
            let body = nextFn.map { String(startBody[..<$0.lowerBound]) } ?? startBody
            return (body.contains("stop_requested_") || body.contains("cancelled_") ||
                    body.contains("cancel_") || body.contains("should_stop"))
                && body.contains("AudioQueueStart")
        }()

        // The bug is present when the early-return guard is still there AND no
        // cancellation-flag fix exists in start().
        let bugIsPresent = stopBodyHasEarlyReturn && !startChecksCancellation

        XCTAssertFalse(
            bugIsPresent,
            "Bug M4 CONFIRMED: capture.cpp stop() has an unconditional early-return "
            + "`if (!capturing) return` before the queue-disposal block. When stop() "
            + "is called while start() has created impl_->queue but not yet set "
            + "capturing=true, stop() returns without disposing the queue — leaving "
            + "an orphaned, running AudioQueue with no owner. "
            + "Fix: remove the early-return so stop() always reaches the "
            + "`if (impl_->queue)` disposal path, or add a cancellation flag that "
            + "start() checks before calling AudioQueueStart."
        )
    }

    // =========================================================================
    // Bug M5 — chunk_queue.cpp: audio_ms_ can go negative
    //
    // pop() decrements audio_ms_ unconditionally:
    //   audio_ms_ -= c.duration_ms;
    // If a chunk's duration_ms is larger than the running total (e.g. due to a
    // buggy caller or a reset() race), audio_ms_ wraps below zero.
    // queued_audio_ms() then returns a negative value, which is fed back to the
    // ETA calculation and queue-status heartbeat — corrupting latency estimates.
    //
    // Fix: audio_ms_ = std::max(0, audio_ms_ - c.duration_ms)
    //      or an explicit if-guard: if (audio_ms_ > c.duration_ms) ...
    // =========================================================================
    func testBugM5_AudioMsCanGoNegative() throws {
        guard let src = readSource("../engine/src/audio/chunk_queue.cpp") else {
            XCTFail("Bug M5 CONFIRMED: cannot read chunk_queue.cpp")
            return
        }

        // The buggy line:  audio_ms_ -= c.duration_ms;
        // with no guard before or after.
        //
        // The fix adds std::max(0, ...) or an if-guard.
        // Detect the bug: bare subtract with no adjacent max/clamp/if guard.

        let bareDecrement = "audio_ms_ -= c.duration_ms;"

        // Check if the subtraction line exists but is NOT paired with a lower-bound guard.
        let hasBareDecrement: Bool
        if let range = src.range(of: bareDecrement) {
            // Inspect the ±3 lines around the decrement for a guard.
            let contextStart = src.index(range.lowerBound,
                                          offsetBy: -120,
                                          limitedBy: src.startIndex) ?? src.startIndex
            let contextEnd   = src.index(range.upperBound,
                                          offsetBy: 120,
                                          limitedBy: src.endIndex) ?? src.endIndex
            let context = String(src[contextStart..<contextEnd])

            let hasGuard = context.contains("std::max") || context.contains("max(0")
                        || context.contains("max(0,") || context.contains("if (audio_ms_")
                        || context.contains("audio_ms_ < ") || context.contains("audio_ms_ > ")
                        || context.contains("clamp")
            hasBareDecrement = !hasGuard
        } else {
            // Subtract gone → the expression was rewritten (which is a valid fix too).
            hasBareDecrement = false
        }

        XCTAssertFalse(
            hasBareDecrement,
            "Bug M5 CONFIRMED: chunk_queue.cpp pop() decrements audio_ms_ with "
            + "`audio_ms_ -= c.duration_ms` and no lower-bound guard. When "
            + "duration_ms exceeds the running total (e.g. after a reset() race "
            + "or an out-of-order pop), audio_ms_ underflows to a negative value. "
            + "queued_audio_ms() then returns a negative ETA, corrupting queue "
            + "status heartbeats. "
            + "Fix: audio_ms_ = std::max(0, audio_ms_ - c.duration_ms)."
        )
    }
}
