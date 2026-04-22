import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// AudioRingBufferTests
//
// Scaffold tests (steps 16-19):
//   testWriteThenReadReturnsChunk    — write once, readNext returns it
//   testReadNextTimesOutWhenNoData   — no write, readNext returns nil
//   testClearInvalidatesHandle       — clear() causes readNext to return nil
//
// Overflow + concurrency tests (step 21):
//   testOverflowDrops                — oldest chunk evicted, metric increments
//   testClearWakesBlocked            — clear() wakes a suspended readNext
//   testConcurrent                   — concurrent writes, single reader, no crash
// ---------------------------------------------------------------------------

final class AudioRingBufferTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Helpers
    // -----------------------------------------------------------------------

    private func makeHandle() -> AudioRingBuffer.Handle {
        AudioRingBuffer.Handle(id: UUID())
    }

    private func makeChunk(byte: UInt8 = 0xAB, size: Int = 4096) -> Data {
        Data(repeating: byte, count: size)
    }

    // -----------------------------------------------------------------------
    // MARK: Scaffold tests — write / read / timeout / invalid-handle
    // -----------------------------------------------------------------------

    /// write() then readNext() returns the written chunk with correct timestamp.
    func testWriteThenReadReturnsChunk() async throws {
        let rb = AudioRingBuffer(capacitySeconds: 300, chunkBytes: 4096, sampleRate: 16_000)
        let h = makeHandle()
        rb.markStart(handle: h, timestamp: 0.0)

        let chunk = makeChunk()
        rb.write(chunk, timestamp: 1.0, handle: h)

        let result = await rb.readNext(handle: h, afterTimestamp: 0.0, maxWait: .seconds(2))
        XCTAssertNotNil(result, "readNext must return the written chunk")
        XCTAssertEqual(result?.0, chunk)
        XCTAssertEqual(result?.1, 1.0)
    }

    /// readNext() returns nil after maxWait when no chunk has been written.
    func testReadNextTimesOutWhenNoData() async throws {
        let rb = AudioRingBuffer(capacitySeconds: 300, chunkBytes: 4096, sampleRate: 16_000)
        let h = makeHandle()
        rb.markStart(handle: h, timestamp: 0.0)

        let result = await rb.readNext(handle: h, afterTimestamp: 0.0, maxWait: .milliseconds(200))
        XCTAssertNil(result, "readNext must return nil when no chunk arrives within maxWait")
    }

    /// clear() on a handle causes readNext to return nil immediately.
    func testClearInvalidatesHandle() async throws {
        let rb = AudioRingBuffer(capacitySeconds: 300, chunkBytes: 4096, sampleRate: 16_000)
        let h = makeHandle()
        rb.markStart(handle: h, timestamp: 0.0)

        Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            rb.clear(handle: h)
        }

        let result = await rb.readNext(handle: h, afterTimestamp: 0.0, maxWait: .seconds(2))
        XCTAssertNil(result, "readNext must return nil after handle is cleared")
    }

    // -----------------------------------------------------------------------
    // MARK: Overflow and concurrent correctness tests (step 21)
    // -----------------------------------------------------------------------

    /// Overflow drops the oldest chunk and increments Metrics.overflowCount.
    ///
    /// Buffer capacity: capacitySeconds=1, chunkBytes=4096, sampleRate=2048
    ///   maxChunks = 1 * 2048 * 2 / 4096 = 1 → only one chunk fits.
    /// Writing a second chunk evicts the first.
    func testOverflowDrops() async throws {
        // 1 s × 2048 Hz × 2 bytes / 4096 bytes/chunk = 1 chunk capacity
        let rb = AudioRingBuffer(capacitySeconds: 1, chunkBytes: 4096, sampleRate: 2048)
        let h = makeHandle()
        rb.markStart(handle: h, timestamp: 0.0)

        let chunk1 = makeChunk(byte: 0x01)
        let chunk2 = makeChunk(byte: 0x02)

        rb.write(chunk1, timestamp: 1.0, handle: h) // fills capacity
        rb.write(chunk2, timestamp: 2.0, handle: h) // overflow: evicts chunk1

        let m = rb.metrics(handle: h)
        XCTAssertGreaterThanOrEqual(m.overflowCount, 1,
            "overflow must increment Metrics.overflowCount")

        // After overflow, readNext must return the surviving chunk (chunk2, not chunk1).
        let result = await rb.readNext(handle: h, afterTimestamp: 0.0, maxWait: .seconds(1))
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, chunk2,
            "after overflow the evicted chunk must not appear; the surviving chunk must be returned")
    }

    /// clear() on a handle that has a suspended readNext wakes it and returns nil.
    func testClearWakesBlocked() async throws {
        let rb = AudioRingBuffer(capacitySeconds: 300, chunkBytes: 4096, sampleRate: 16_000)
        let h = makeHandle()
        rb.markStart(handle: h, timestamp: 0.0)

        let box = ResultBox<(Data, TimeInterval)?>(nil)

        let readTask = Task {
            let r = await rb.readNext(handle: h, afterTimestamp: 0.0, maxWait: .seconds(10))
            await box.set(r)
        }

        // Let the consumer suspend first, then clear.
        try await Task.sleep(for: .milliseconds(100))
        rb.clear(handle: h)

        await readTask.value
        let result = await box.get()
        XCTAssertNil(result, "clear() must wake blocked readNext and return nil")
    }

    /// Concurrent writes from multiple tasks with a single reader: no crash,
    /// all non-evicted chunks are readable in timestamp order.
    func testConcurrent() async throws {
        // Large capacity so no overflow with 20 chunks.
        let rb = AudioRingBuffer(capacitySeconds: 300, chunkBytes: 16, sampleRate: 16_000)
        let h = makeHandle()
        rb.markStart(handle: h, timestamp: 0.0)

        let writeCount = 20

        // Write 20 chunks concurrently (distinct timestamps 1.0 ... 20.0).
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<writeCount {
                group.addTask {
                    let chunk = Data(repeating: UInt8(i), count: 16)
                    rb.write(chunk, timestamp: TimeInterval(i + 1), handle: h)
                }
            }
        }

        // Read chunks until none left.
        var readCount = 0
        var lastTs: TimeInterval = 0.0
        for _ in 0..<writeCount {
            guard let (_, ts) = await rb.readNext(handle: h,
                                                   afterTimestamp: lastTs,
                                                   maxWait: .milliseconds(200))
            else { break }
            lastTs = ts
            readCount += 1
        }

        XCTAssertGreaterThan(readCount, 0,
            "concurrent writes must produce at least one readable chunk")
        // Primary goal: no crash during concurrent writes.
    }
}

// ---------------------------------------------------------------------------
// MARK: - ResultBox — actor-isolated box for test synchronization
// ---------------------------------------------------------------------------

private actor ResultBox<T> {
    private(set) var stored: T
    init(_ initial: T) { stored = initial }
    func set(_ v: T) { stored = v }
    func get() -> T  { stored }
}
