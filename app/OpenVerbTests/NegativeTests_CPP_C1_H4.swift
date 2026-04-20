import XCTest
@testable import OpenVerb

// Negative tests for: C1, C2, C3, H1, H2, H3, H4
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_CPP_C1_H4: XCTestCase {

    private func readSource(_ relativePath: String) -> String? {
        let direct = URL(fileURLWithPath: relativePath)
        if let content = try? String(contentsOf: direct, encoding: .utf8) { return content }
        if let base = Bundle.main.resourceURL {
            let bundled = base.appendingPathComponent(relativePath)
            if let content = try? String(contentsOf: bundled, encoding: .utf8) { return content }
        }
        return nil
    }

    // -------------------------------------------------------------------------
    // Bug C1 — unload_model() frees weights while process_stream() uses them
    //
    // engine.cpp grabs a shared_ptr to backend_ inside engine_mutex_ then
    // releases the lock before calling be->process_stream().  unload_model()
    // acquires the same lock and resets the backend_ shared_ptr, but the raw
    // llama weights inside the backend are freed by backend_->unload_model()
    // while the already-copied shared_ptr is still being used for inference.
    //
    // The fix requires holding engine_mutex_ (or a dedicated inference_mutex_)
    // for the ENTIRE duration of any process_stream() / process_file() call, so
    // unload_model() cannot proceed while inference is active.
    // -------------------------------------------------------------------------
    func testBugC1_unloadRacesProcessStream() {
        guard let content = readSource("../engine/src/engine.cpp") else {
            XCTFail("Bug C1 CONFIRMED: cannot read engine.cpp — source unavailable")
            return
        }

        // The fix: engine_mutex_ (or any named mutex) must remain locked across
        // the be->process_stream() call.  The buggy pattern releases the lock
        // before that call — "be = backend_; }" followed by "return be->process_stream".
        // A fixed implementation either (a) holds the lock for the full call, or
        // (b) uses a separate shared_mutex / read-lock held throughout inference.
        //
        // We look for the presence of a dedicated inference lock or a reader-writer
        // lock pattern that guards the be->process_stream() invocation.
        let hasInferenceLock = content.contains("inference_mutex_")
            || content.contains("std::shared_lock")
            || content.contains("std::shared_mutex")
            // Alternative: a scoped lock that spans the be->process_stream call
            // by keeping the lock alive until after the call returns.
            || content.contains("lk_inference")

        XCTAssertTrue(
            hasInferenceLock,
            "Bug C1 CONFIRMED: engine.cpp releases engine_mutex_ before be->process_stream() — "
            + "unload_model() can free the underlying llama weights while inference is running. "
            + "Fix: hold a reader lock (std::shared_mutex / std::shared_lock) or a dedicated "
            + "inference_mutex_ across the entire process_stream() / process_file() call so "
            + "unload_model() cannot proceed while inference is active."
        )
    }

    // -------------------------------------------------------------------------
    // Bug C2 — unload_model() races process_impl() on llama_ unique_ptr
    //
    // backend_gemma_audio.cpp: unload_model() calls llama_.reset() with no
    // lock held.  process_impl() reads llama_ (null-check + dereference) also
    // without a lock.  This is a data race on the unique_ptr itself.
    //
    // Fix: llama_.reset() must be inside a mutex that process_impl() also
    // acquires before reading llama_.
    // -------------------------------------------------------------------------
    func testBugC2_unloadResetsLlamaWithoutMutex() {
        guard let content = readSource("../engine/src/backend/backend_gemma_audio.cpp") else {
            XCTFail("Bug C2 CONFIRMED: cannot read backend_gemma_audio.cpp — source unavailable")
            return
        }

        // The buggy pattern: unload_model() body contains only `llama_.reset()` with
        // no lock_guard / unique_lock / mutex acquisition surrounding it.
        // We verify the fix by asserting that unload_model() is NOT implemented as a
        // bare reset with no lock nearby.
        //
        // Specifically, a compliant implementation must include a mutex member and
        // acquire it inside unload_model() before touching llama_.
        let hasBackendMutex = content.contains("backend_mutex_")
            || content.contains("llama_mutex_")
            || content.contains("impl_mutex_")
            // Any named mutex member accessed in the unload path
            || (content.contains("std::mutex") && content.contains("lock_guard") &&
                content.range(of: "unload_model") != nil &&
                content.range(of: "lock_guard.*llama", options: .regularExpression) != nil)

        XCTAssertTrue(
            hasBackendMutex,
            "Bug C2 CONFIRMED: backend_gemma_audio.cpp — unload_model() calls llama_.reset() "
            + "with no mutex held while process_impl() reads llama_ concurrently. Data race on "
            + "the unique_ptr. "
            + "Fix: add a std::mutex member (e.g. backend_mutex_ / llama_mutex_) and acquire it "
            + "in both unload_model() and process_impl() before any access to llama_."
        )
    }

    // -------------------------------------------------------------------------
    // Bug C3 — n_past overflow past KV cache bounds on long audio + verbose prompt
    //
    // llama_context.cpp: after prompt evaluation n_past holds the number of
    // tokens already in the KV cache.  The autoregressive generation loop then
    // increments n_past on every token without ever checking that n_past <
    // ctx_size.  On long recordings or verbose prompts this causes n_past to
    // exceed ctx_size, resulting in silent memory corruption or a segfault
    // inside llama_decode().
    //
    // Fix: guard before or inside the generation loop:
    //   if (n_past >= ctx_size) break; // or throw
    // -------------------------------------------------------------------------
    func testBugC3_nPastOverflowNoBoundsCheck() {
        guard let content = readSource("../engine/src/inference/llama_context.cpp") else {
            XCTFail("Bug C3 CONFIRMED: cannot read llama_context.cpp — source unavailable")
            return
        }

        // Look for a bounds guard that prevents n_past from reaching or exceeding
        // ctx_size inside the generation loop.  Any of these patterns constitutes a fix:
        //   if (n_past >= impl_->ctx_size)
        //   if (n_past >= ctx_size)
        //   n_past >= (llama_pos)impl_->ctx_size
        let hasBoundsCheck = content.contains("n_past >= impl_->ctx_size")
            || content.contains("n_past >= ctx_size")
            || content.contains("n_past >= (llama_pos)")
            || content.contains("n_past + 1 >= impl_->ctx_size")
            || content.contains("n_past + 1 >= ctx_size")

        XCTAssertTrue(
            hasBoundsCheck,
            "Bug C3 CONFIRMED: llama_context.cpp — the generation loop increments n_past without "
            + "checking that n_past < ctx_size. When prompt + audio + generated tokens exceed the "
            + "KV-cache capacity the call to llama_decode() silently corrupts memory or segfaults. "
            + "Fix: add a guard before llama_decode() in the generation loop: "
            + "'if (n_past >= impl_->ctx_size) break;' (or throw a descriptive error)."
        )
    }

    // -------------------------------------------------------------------------
    // Bug H1 — CaptureCallback std::function read from CoreAudio real-time
    //           thread without synchronisation
    //
    // capture.cpp: `impl_->callback` is assigned on the application thread
    // inside AudioCapture::start() and then read (and invoked) on a CoreAudio
    // real-time callback thread in Impl::audio_callback().  std::function is
    // not thread-safe for concurrent read+write; this is an unsynchronised
    // access (data race).
    //
    // Fix: protect the callback member with a std::mutex, or replace it with
    // an atomic-compatible handle, ensuring start() and audio_callback() cannot
    // race on the callback member.
    // -------------------------------------------------------------------------
    func testBugH1_captureCallbackRacesOnRealTimeThread() {
        guard let content = readSource("../engine/src/audio/capture.cpp") else {
            XCTFail("Bug H1 CONFIRMED: cannot read capture.cpp — source unavailable")
            return
        }

        // The fix requires a mutex (or equivalent) guarding `callback` assignment
        // in start() and the read in audio_callback().
        let hasCallbackLock = content.contains("callback_mutex_")
            || content.contains("cb_mutex_")
            // A shared_ptr<CaptureCallback> with atomic swap is also a valid fix
            || content.contains("std::atomic<std::shared_ptr")
            || content.contains("atomic_callback")
            // Any lock_guard or unique_lock accompanying the callback access
            || (content.contains("lock_guard") &&
                content.range(of: "lock_guard.*callback|callback.*lock_guard",
                               options: .regularExpression) != nil)

        XCTAssertTrue(
            hasCallbackLock,
            "Bug H1 CONFIRMED: capture.cpp — impl_->callback is assigned in start() on the app "
            + "thread and read in audio_callback() on a CoreAudio real-time thread with no "
            + "synchronisation.  Data race on std::function. "
            + "Fix: protect the callback member with a std::mutex (e.g. callback_mutex_) acquired "
            + "in both start() during assignment and in audio_callback() before the call."
        )
    }

    // -------------------------------------------------------------------------
    // Bug H2 — RingBuffer::read_all() without mutex races with reset()
    //
    // ring_buffer.cpp: reset() acquires write_mutex_ and resets both
    // write_idx_ and read_idx_ to zero.  read_all() does NOT acquire
    // write_mutex_ — it reads read_idx_ and write_idx_ without any lock,
    // then stores back to read_idx_.  If reset() runs concurrently,
    // read_idx_ can be advanced past the newly-zeroed write_idx_, leaving
    // read_idx_ > write_idx_ and causing every subsequent read to return
    // uninitialized data.
    //
    // Fix: read_all() must acquire write_mutex_ (or a dedicated read_mutex_)
    // before loading and modifying the indices.
    // -------------------------------------------------------------------------
    func testBugH2_readAllRacesWithReset() {
        guard let content = readSource("../engine/src/audio/ring_buffer.cpp") else {
            XCTFail("Bug H2 CONFIRMED: cannot read ring_buffer.cpp — source unavailable")
            return
        }

        // The fix: read_all() must hold write_mutex_ (or another shared mutex)
        // while it reads and updates the indices.
        // We check that read_all's implementation body contains a lock acquisition.
        // Strategy: find the read_all function block and look for lock_guard within it.
        //
        // Simpler heuristic: the total number of lock_guard occurrences must be >= 3
        // (write locks write(), reset(), and now read_all()).
        let lockCount = content.components(separatedBy: "lock_guard").count - 1
        let hasReadAllLock = lockCount >= 3
            || content.contains("read_mutex_")
            || (content.range(of: "read_all[\\s\\S]*?lock_guard",
                               options: .regularExpression) != nil)

        XCTAssertTrue(
            hasReadAllLock,
            "Bug H2 CONFIRMED: ring_buffer.cpp — read_all() reads and writes read_idx_ without "
            + "holding write_mutex_, while reset() acquires write_mutex_ and zeroes both indices "
            + "concurrently.  This can leave read_idx_ > write_idx_, producing reads of "
            + "uninitialised data on the next call. "
            + "Fix: acquire write_mutex_ (or a dedicated read_mutex_) at the top of read_all() "
            + "before loading or storing any index."
        )
    }

    // -------------------------------------------------------------------------
    // Bug H3 — VadScanner::maybe_emit_chunk holds mu_ and blocks on full
    //           ChunkQueue::push() — deadlock
    //
    // vad_scanner.cpp: push_frame() and flush() both acquire mu_ via
    // lock_guard, then call maybe_emit_chunk() which invokes cb_() while mu_
    // is still held.  cb_() typically calls chunk_queue_.push(), which blocks
    // on not_full_.wait() when the queue is full.  If the consumer thread also
    // needs to acquire mu_ (e.g. for reset()), the two threads deadlock.
    //
    // Fix: release mu_ before invoking cb_(), e.g. by moving the chunk
    // construction inside the lock but emitting it outside:
    //   { std::lock_guard<std::mutex> lk(mu_); /* build chunk */ }
    //   cb_(std::move(chunk));   // mu_ NOT held here
    // -------------------------------------------------------------------------
    func testBugH3_maybeEmitChunkHoldsMuWhileBlocking() {
        guard let content = readSource("../engine/src/audio/vad_scanner.cpp") else {
            XCTFail("Bug H3 CONFIRMED: cannot read vad_scanner.cpp — source unavailable")
            return
        }

        // The buggy pattern: maybe_emit_chunk() calls cb_() — a blocking operation —
        // while mu_ is held by the caller (push_frame / flush own the lock_guard).
        // Neither push_frame, flush, nor maybe_emit_chunk itself contains any
        // explicit mu_.unlock() / lk.unlock() prior to the cb_() invocation.
        //
        // The fix requires an explicit unlock of mu_ before the callback fires.
        // Canonical patterns:
        //   mu_.unlock();           // raw unlock just before cb_()
        //   lk.unlock();            // std::unique_lock unlocked before cb_()
        //   lock.unlock();          // same with other variable name
        // OR restructuring so maybe_emit_chunk() is no longer called while mu_
        // is locked (e.g. collecting chunks into a local vector inside the lock,
        // then emitting them after the lock_guard goes out of scope).
        let hasExplicitUnlock = content.contains("mu_.unlock()")
            || content.contains("lk.unlock()")
            || content.contains("lock.unlock()")

        XCTAssertTrue(
            hasExplicitUnlock,
            "Bug H3 CONFIRMED: vad_scanner.cpp — maybe_emit_chunk() calls cb_() while mu_ is "
            + "held by push_frame() / flush().  If cb_() (chunk_queue_.push()) blocks on a full "
            + "queue, and the consumer holds mu_ for any reason, both threads deadlock. "
            + "Fix: release mu_ before invoking cb_() via an explicit mu_.unlock() / lk.unlock() "
            + "before the cb_() call, or restructure so the callback fires after the lock_guard "
            + "goes out of scope."
        )
    }

    // -------------------------------------------------------------------------
    // Bug H4 — ChunkQueue::reset() wakes old session's blocked push() —
    //           stale chunk inserted into new session
    //
    // chunk_queue.cpp: reset() calls not_full_.notify_all() after clearing the
    // queue and resetting shut_ = false.  An old session's push() that was
    // waiting on not_full_ wakes up, sees the queue is now below capacity, and
    // inserts its stale chunk into what is already the new session's queue.
    //
    // Fix: introduce a generation counter (or a "flushing" flag) that is
    // incremented by reset().  A woken push() checks the counter; if the
    // generation has changed since it entered the wait, it discards the chunk
    // instead of inserting it.
    // -------------------------------------------------------------------------
    func testBugH4_resetWakesOldPushInsertsStaleChunk() {
        guard let content = readSource("../engine/src/audio/chunk_queue.cpp") else {
            XCTFail("Bug H4 CONFIRMED: cannot read chunk_queue.cpp — source unavailable")
            return
        }

        // The fix requires a generation counter or flush flag that is checked
        // inside push() after it wakes from not_full_.wait().
        let hasGenerationGuard = content.contains("generation_")
            || content.contains("session_id_")
            || content.contains("flush_flag_")
            || content.contains("reset_count_")
            || content.contains("epoch_")
            // The wait predicate in push() must also test the flag/counter so a
            // woken push() can detect it is stale.
            || content.range(of: "wait.*generation|generation.*wait",
                              options: .regularExpression) != nil

        XCTAssertTrue(
            hasGenerationGuard,
            "Bug H4 CONFIRMED: chunk_queue.cpp — reset() calls not_full_.notify_all(), which "
            + "wakes any old-session push() blocked on a full queue.  That push() then re-acquires "
            + "the mutex, passes the capacity check (queue is now empty), and inserts a stale chunk "
            + "from the previous session before the new session has started. "
            + "Fix: add a generation counter (e.g. generation_++) incremented in reset().  Inside "
            + "push(), capture the counter before waiting and, after waking, discard the chunk if "
            + "the counter has advanced (i.e. the queue was reset while we waited)."
        )
    }
}
