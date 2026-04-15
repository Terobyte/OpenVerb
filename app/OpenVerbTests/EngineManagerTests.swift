import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// EngineManagerTests — unit tests for crash recovery, exponential backoff,
// and model existence check (plan step 8).
//
// NOTE: Process spawning, socket connection, and ensureRunning() call actual
// OS resources and are integration-test territory (human verification steps).
// These tests exercise the pure logic paths via @testable access.
// ---------------------------------------------------------------------------

@MainActor
final class EngineManagerTests: XCTestCase {

    private var sut: EngineManager!

    override func setUp() async throws {
        // Use a disposable socket path and a guaranteed-absent engine binary so
        // any accidental ensureRunning() call fails fast instead of hanging.
        sut = EngineManager(
            socketPath: "/tmp/openverb_test_\(UUID().uuidString).sock",
            enginePath: "/usr/bin/false",
            client: EngineClient()
        )
    }

    override func tearDown() async throws {
        sut = nil
    }

    // -----------------------------------------------------------------------
    // MARK: Exponential backoff — attempt N → min(2^(N-1), 4) seconds
    // -----------------------------------------------------------------------

    func testBackoffAttempt1Is1Second() {
        XCTAssertEqual(sut.backoffDelay(attempt: 1), 1.0, accuracy: 1e-9)
    }

    func testBackoffAttempt2Is2Seconds() {
        XCTAssertEqual(sut.backoffDelay(attempt: 2), 2.0, accuracy: 1e-9)
    }

    func testBackoffAttempt3Is4Seconds() {
        XCTAssertEqual(sut.backoffDelay(attempt: 3), 4.0, accuracy: 1e-9)
    }

    func testBackoffCappedAt4Seconds() {
        // 2^3 = 8 → capped at 4
        XCTAssertEqual(sut.backoffDelay(attempt: 4), 4.0, accuracy: 1e-9)
        // 2^9 = 512 → still 4
        XCTAssertEqual(sut.backoffDelay(attempt: 10), 4.0, accuracy: 1e-9)
    }

    // -----------------------------------------------------------------------
    // MARK: Crash counter — 3 crashes within 60s → crash loop detected
    // -----------------------------------------------------------------------

    func testThreeCrashesInWindowActivatesCrashLoop() {
        XCTAssertFalse(sut.isCrashLoopActive)

        let now = Date()
        sut.simulateCrash(at: now)
        sut.simulateCrash(at: now.addingTimeInterval(1))
        sut.simulateCrash(at: now.addingTimeInterval(2))

        XCTAssertTrue(sut.isCrashLoopActive,
                      "3 crashes within 60 s must be detected as a crash loop")
    }

    func testTwoCrashesDoNotActivateCrashLoop() {
        let now = Date()
        sut.simulateCrash(at: now)
        sut.simulateCrash(at: now.addingTimeInterval(1))

        XCTAssertFalse(sut.isCrashLoopActive,
                       "Only 2 crashes must not trigger crash loop (threshold is 3)")
    }

    // -----------------------------------------------------------------------
    // MARK: Crash counter reset — crash outside 60s window is discarded
    // -----------------------------------------------------------------------

    func testOldCrashOutsideWindowIsDiscarded() {
        // Simulate a crash that happened 70s ago (outside the 60s window).
        let oldCrash = Date().addingTimeInterval(-70)
        sut.simulateCrash(at: oldCrash)

        // Simulate another crash right now.  The 70s gap exceeds the 60s window
        // anchored on firstCrashTime → counter resets to 1.
        let now = Date()
        sut.simulateCrash(at: now)

        // Verify the counter is exactly 1 (not 2) via behavioral proof:
        //   • If the old crash was NOT reset (counter == 2), then adding one
        //     more recent crash would reach the threshold of 3 and activate the
        //     crash loop here.
        //   • With the correct count of 1, one additional crash gives 2 total —
        //     still below the threshold.
        sut.simulateCrash(at: now.addingTimeInterval(1))
        XCTAssertFalse(sut.isCrashLoopActive,
                       "Counter must be 1 after window reset: two recent crashes must not trigger crash loop")

        // Final confirmation: a third recent crash does activate the loop,
        // proving the count was exactly 1 (not 2) before this line.
        sut.simulateCrash(at: now.addingTimeInterval(2))
        XCTAssertTrue(sut.isCrashLoopActive,
                      "Three recent crashes must activate crash loop (proves counter was 1, not 2, before last crash)")
    }

    func testResetCrashCounterClearsAll() {
        let now = Date()
        sut.simulateCrash(at: now)
        sut.simulateCrash(at: now.addingTimeInterval(1))
        sut.simulateCrash(at: now.addingTimeInterval(2))
        XCTAssertTrue(sut.isCrashLoopActive)

        sut.resetCrashCounter()
        XCTAssertFalse(sut.isCrashLoopActive,
                       "resetCrashCounter() must clear crash counter and firstCrashTime")
    }

    // -----------------------------------------------------------------------
    // MARK: Crash-loop status — 3 crashes must surface .error on EngineManager.status
    // -----------------------------------------------------------------------

    /// Verifies the *observable* behaviour: after the third crash within 60 s the
    /// published `status` transitions to `.error("Engine keeps crashing…")` so
    /// that the status-bar icon and any Combine subscriber reflects the failure.
    ///
    /// This is distinct from `testThreeCrashesInWindowActivatesCrashLoop` which
    /// only exercises the internal `isCrashLoopActive` predicate.
    func testThreeCrashesInWindowSurfacesErrorStatus() async {
        // Pre-seed two crashes close in time (well within the 60 s window).
        let now = Date()
        sut.simulateCrash(at: now)
        sut.simulateCrash(at: now.addingTimeInterval(1))

        // handleCrash() records the third crash internally, detects the crash loop,
        // sets status = .error(msg), and throws EngineManagerError.crashLoop.
        // It must NOT proceed to ensureRunning() / Task.sleep on the crash-loop path.
        do {
            try await sut.handleCrash()
            XCTFail("handleCrash() must throw .crashLoop when 3 crashes occur within 60 s")
        } catch EngineManagerError.crashLoop {
            // expected — fall through to status assertion
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let expected = EngineManager.EngineStatus.error(
            "Engine keeps crashing — try reducing --ctx-size or closing memory-intensive apps"
        )
        XCTAssertEqual(sut.status, expected,
                       "EngineManager.status must surface crash-loop error message for UI observers")
    }

    // -----------------------------------------------------------------------
    // MARK: Model existence check
    // -----------------------------------------------------------------------

    func testCheckModelExistsReturnsFalseForMissingDirectory() {
        let mgr = EngineManager(
            socketPath: "/tmp/x.sock",
            enginePath: "/usr/bin/false",
            modelDirOverride: "/tmp/openverb_no_models_\(UUID().uuidString)/"
        )
        XCTAssertFalse(mgr.ggufModelExists(),
                       "Non-existent directory must return false")
    }

    func testCheckModelExistsReturnsFalseForEmptyDirectory() throws {
        let dir = NSTemporaryDirectory() + "openverb_empty_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let mgr = EngineManager(
            socketPath: "/tmp/x.sock",
            enginePath: "/usr/bin/false",
            modelDirOverride: dir
        )
        XCTAssertFalse(mgr.ggufModelExists(),
                       "Directory with no .gguf files must return false")
    }

    func testCheckModelExistsReturnsTrueWhenGGUFPresent() throws {
        let dir = NSTemporaryDirectory() + "openverb_models_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: dir + "gemma.gguf", contents: nil)

        let mgr = EngineManager(
            socketPath: "/tmp/x.sock",
            enginePath: "/usr/bin/false",
            modelDirOverride: dir
        )
        XCTAssertTrue(mgr.ggufModelExists(),
                      ".gguf file present must return true")
    }

    func testCheckModelExistsIgnoresNonGGUFFiles() throws {
        let dir = NSTemporaryDirectory() + "openverb_nonguf_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        FileManager.default.createFile(atPath: dir + "README.txt", contents: nil)
        FileManager.default.createFile(atPath: dir + "model.bin", contents: nil)

        let mgr = EngineManager(
            socketPath: "/tmp/x.sock",
            enginePath: "/usr/bin/false",
            modelDirOverride: dir
        )
        XCTAssertFalse(mgr.ggufModelExists(),
                       "Non-.gguf files must not satisfy model existence check")
    }

    // -----------------------------------------------------------------------
    // MARK: Model existence check — mocked FileManager seam
    //
    // Exercises ggufModelExists() via a stub FileManager subclass so that
    // the failure paths (directory not found, empty listing, mixed files)
    // are testable without touching the real filesystem.
    // -----------------------------------------------------------------------

    func testCheckModelExistsViaMock_throwingFileManager_returnsFalse() {
        // FileManager that always throws — simulates a missing / inaccessible dir.
        let mock = ThrowingFileManager()
        let mgr = EngineManager(
            socketPath: "/tmp/x.sock",
            enginePath: "/usr/bin/false",
            modelDirOverride: "/no/such/path",
            fileManager: mock
        )
        XCTAssertFalse(mgr.ggufModelExists(),
                       "Inaccessible directory (throws) must return false")
    }

    func testCheckModelExistsViaMock_emptyListing_returnsFalse() {
        let mock = StubFileManager(files: [])
        let mgr = EngineManager(
            socketPath: "/tmp/x.sock",
            enginePath: "/usr/bin/false",
            modelDirOverride: "/stub/path",
            fileManager: mock
        )
        XCTAssertFalse(mgr.ggufModelExists(),
                       "Empty listing must return false")
    }

    func testCheckModelExistsViaMock_ggufPresent_returnsTrue() {
        let mock = StubFileManager(files: ["model.gguf", "notes.txt"])
        let mgr = EngineManager(
            socketPath: "/tmp/x.sock",
            enginePath: "/usr/bin/false",
            modelDirOverride: "/stub/path",
            fileManager: mock
        )
        XCTAssertTrue(mgr.ggufModelExists(),
                      "Listing with a .gguf file must return true")
    }

    func testCheckModelExistsViaMock_onlyNonGGUF_returnsFalse() {
        let mock = StubFileManager(files: ["README.md", "config.yaml"])
        let mgr = EngineManager(
            socketPath: "/tmp/x.sock",
            enginePath: "/usr/bin/false",
            modelDirOverride: "/stub/path",
            fileManager: mock
        )
        XCTAssertFalse(mgr.ggufModelExists(),
                       "Listing with no .gguf files must return false")
    }
}

// ---------------------------------------------------------------------------
// MARK: FileManager stubs
// ---------------------------------------------------------------------------

/// Returns a fixed file listing regardless of path — no real I/O.
private final class StubFileManager: FileManager {
    private let files: [String]
    init(files: [String]) { self.files = files }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        return files
    }
}

/// Always throws — simulates a missing or inaccessible directory.
private final class ThrowingFileManager: FileManager {
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        throw CocoaError(.fileNoSuchFile)
    }
}
