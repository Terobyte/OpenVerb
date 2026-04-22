import Foundation
import os

// ---------------------------------------------------------------------------
// AudioRingBuffer — thread-safe ring buffer of timestamped PCM chunks.
//
// Concurrency: NOT actor-isolated. All methods are safe to call from any
// thread, including the AVAudioEngine realtime audio thread. Internal state
// is protected by a single OSAllocatedUnfairLock; no Swift actor isolation.
//
// Capacity arithmetic (Int16 mono, 16 kHz default):
//   bytes     = capacitySeconds * sampleRate * 2   // 300 * 16_000 * 2 = 9.6 MB
//   maxChunks = bytes / chunkBytes                 // 9_600_000 / 4096 = 2343 chunks
//
// Per-handle isolation: each Handle maintains its own entry queue. Writes and
// reads for handle H cannot see or interfere with handle H2. This replaces the
// drainGeneration / isDraining re-entrancy guards in AppDelegate.
//
// Tail-follow semantics: entries are NOT removed when read. The consumer
// advances its position by passing the last-seen timestamp as afterTimestamp.
// Overflow evicts the oldest entry from each handle independently.
//
// Single-fire timeout Task: readNext suspends via CheckedContinuation and
// schedules a Task that resumes the continuation with nil after maxWait. The
// continuation slot is guarded by the same lock that write/clear use, so only
// one of them can fire it.
// ---------------------------------------------------------------------------

private let bufferLogger = Logger(subsystem: "io.openverb.app", category: "AudioRingBuffer")

final class AudioRingBuffer {

    // -----------------------------------------------------------------------
    // MARK: Public types
    // -----------------------------------------------------------------------

    struct Handle: Hashable {
        let id: UUID
        init(id: UUID = UUID()) { self.id = id }
    }

    struct Metrics {
        let overflowCount: Int
        let peakDepthChunks: Int
    }

    // -----------------------------------------------------------------------
    // MARK: Private state
    // -----------------------------------------------------------------------

    private struct Entry {
        let chunk: Data
        let timestamp: TimeInterval
    }

    /// All mutable state for a single handle.
    private struct HandleState {
        var entries: [Entry] = []
        var overflowCount: Int = 0
        var peakDepth: Int = 0
        var startTimestamp: TimeInterval = 0
        var endTimestamp: TimeInterval? = nil
        /// Set to true by clear() to wake any suspended readNext and reject
        /// new writes without removing the HandleState from the dictionary.
        var isInvalidated: Bool = false
        /// At most one consumer suspends per handle at a time.
        var pendingContinuation: CheckedContinuation<(Data, TimeInterval)?, Never>?
        var pendingAfterTimestamp: TimeInterval = 0
        /// Token matched by the timeout Task to avoid firing a stale slot.
        var pendingToken: UUID = UUID()
    }

    private var handleStates: [Handle: HandleState] = [:]
    private let lock = OSAllocatedUnfairLock()
    private let maxChunks: Int

    // -----------------------------------------------------------------------
    // MARK: Initialiser
    // -----------------------------------------------------------------------

    init(capacitySeconds: Int = 300, chunkBytes: Int = 4096, sampleRate: Int = 16_000) {
        // maxChunks = bytes / chunkBytes, minimum 1 so the buffer can always
        // hold at least one entry even for very small capacities.
        let bytes = capacitySeconds * sampleRate * 2
        self.maxChunks = max(1, bytes / chunkBytes)
    }

    // -----------------------------------------------------------------------
    // MARK: Lifecycle
    // -----------------------------------------------------------------------

    /// Called immediately after AVAudioEngine.start() + tap installed.
    func markStart(handle: Handle, timestamp: TimeInterval) {
        lock.lock()
        if handleStates[handle] == nil {
            handleStates[handle] = HandleState()
        }
        handleStates[handle]!.startTimestamp = timestamp
        handleStates[handle]!.isInvalidated = false
        lock.unlock()
    }

    /// Records the end timestamp for the handle (informational; does not stop writes).
    func markEnd(handle: Handle, timestamp: TimeInterval) {
        lock.lock()
        handleStates[handle]?.endTimestamp = timestamp
        lock.unlock()
    }

    /// Invalidates the handle, clears its entries, and wakes any blocked readNext.
    func clear(handle: Handle) {
        lock.lock()
        guard var state = handleStates[handle] else {
            lock.unlock()
            return
        }
        let cont = state.pendingContinuation
        state.pendingContinuation = nil
        state.entries.removeAll()
        state.isInvalidated = true
        handleStates[handle] = state
        lock.unlock()
        cont?.resume(returning: nil)
    }

    // -----------------------------------------------------------------------
    // MARK: Producer API — called from the AVAudioEngine realtime tap
    // -----------------------------------------------------------------------

    func write(_ chunk: Data, timestamp: TimeInterval, handle: Handle) {
        var didOverflow = false
        var fireCont: CheckedContinuation<(Data, TimeInterval)?, Never>?
        var fireResult: (Data, TimeInterval)?

        lock.lock()
        guard var state = handleStates[handle], !state.isInvalidated else {
            lock.unlock()
            return
        }

        // Overflow: evict oldest entry, increment metric.
        if state.entries.count >= maxChunks {
            state.entries.removeFirst()
            state.overflowCount += 1
            didOverflow = true
        }

        state.entries.append(Entry(chunk: chunk, timestamp: timestamp))
        if state.entries.count > state.peakDepth {
            state.peakDepth = state.entries.count
        }

        // Wake a suspended readNext if this new entry satisfies its request,
        // or if an older buffered entry already satisfies it.
        if let pending = state.pendingContinuation {
            let eligible = state.entries.filter { $0.timestamp > state.pendingAfterTimestamp }
            if let earliest = eligible.min(by: { $0.timestamp < $1.timestamp }) {
                fireCont = pending
                fireResult = (earliest.chunk, earliest.timestamp)
                state.pendingContinuation = nil
            }
        }

        handleStates[handle] = state
        lock.unlock()

        // Deferred WARN log — off the realtime audio thread to avoid priority inversion.
        if didOverflow {
            DispatchQueue.global(qos: .background).async {
                bufferLogger.warning("AudioRingBuffer overflow: evicted oldest chunk (handle \(handle.id))")
            }
        }

        if let c = fireCont, let r = fireResult {
            c.resume(returning: r)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Consumer API — called from AudioPipeline's detached Task
    // -----------------------------------------------------------------------

    /// Returns (chunk, timestamp) for the next chunk whose timestamp >
    /// afterTimestamp for this handle.
    ///
    /// Returns nil when:
    ///   (a) the handle is invalidated (clear called), or
    ///   (b) maxWait elapses with no new chunk arriving.
    func readNext(handle: Handle, afterTimestamp: TimeInterval,
                  maxWait: Duration) async -> (Data, TimeInterval)? {

        // Fast path: entry already available.
        lock.lock()
        guard let state0 = handleStates[handle], !state0.isInvalidated else {
            lock.unlock()
            return nil
        }
        if let entry = earliestEntry(in: state0, after: afterTimestamp) {
            lock.unlock()
            return (entry.chunk, entry.timestamp)
        }
        lock.unlock()

        // Slow path: suspend and wait for write() or clear() to wake us.
        return await withCheckedContinuation { [weak self]
            (cont: CheckedContinuation<(Data, TimeInterval)?, Never>) in
            guard let self else {
                cont.resume(returning: nil)
                return
            }

            let token = UUID()
            self.lock.lock()

            guard var state = self.handleStates[handle] else {
                self.lock.unlock()
                cont.resume(returning: nil)
                return
            }

            if state.isInvalidated {
                self.lock.unlock()
                cont.resume(returning: nil)
                return
            }

            // Double-check: entry may have arrived since the fast path check.
            if let entry = self.earliestEntry(in: state, after: afterTimestamp) {
                self.lock.unlock()
                cont.resume(returning: (entry.chunk, entry.timestamp))
                return
            }

            state.pendingContinuation = cont
            state.pendingAfterTimestamp = afterTimestamp
            state.pendingToken = token
            self.handleStates[handle] = state
            self.lock.unlock()

            // Single-fire timeout Task. Identified by token so a stale timeout
            // Task from a previous readNext call cannot fire the current slot.
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: maxWait)
                self.lock.lock()
                guard var st = self.handleStates[handle],
                      st.pendingToken == token,
                      let pending = st.pendingContinuation
                else {
                    self.lock.unlock()
                    return
                }
                st.pendingContinuation = nil
                self.handleStates[handle] = st
                self.lock.unlock()
                pending.resume(returning: nil)
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Metrics
    // -----------------------------------------------------------------------

    func metrics(handle: Handle) -> Metrics {
        lock.lock()
        defer { lock.unlock() }
        guard let state = handleStates[handle] else {
            return Metrics(overflowCount: 0, peakDepthChunks: 0)
        }
        return Metrics(overflowCount: state.overflowCount, peakDepthChunks: state.peakDepth)
    }

    // -----------------------------------------------------------------------
    // MARK: Private helpers
    // -----------------------------------------------------------------------

    private func earliestEntry(in state: HandleState, after ts: TimeInterval) -> Entry? {
        let eligible = state.entries.filter { $0.timestamp > ts }
        return eligible.min(by: { $0.timestamp < $1.timestamp })
    }
}
