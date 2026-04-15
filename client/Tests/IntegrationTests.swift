// ---------------------------------------------------------------------------
// IntegrationTests.swift — Swift client integration tests.
//
// Guarded by the OPENVERB_INTEGRATION_TESTS environment variable.
// Run with:
//
//   OPENVERB_INTEGRATION_TESTS=1 swift test
//
// Runtime requirements:
//   OPENVERB_TEST_MODEL  — absolute path to a Gemma audio .gguf model file.
//   OPENVERB_TEST_MMPROJ — absolute path to the matching mmproj file
//                          (optional; omit if the model is a single-file pack).
//
// If OPENVERB_INTEGRATION_TESTS is not set the tests are compiled but each
// test case returns early, so a plain `swift test` never requires an engine.
// ---------------------------------------------------------------------------

import XCTest
import Foundation
@testable import OpenVerbClient

final class IntegrationTests: XCTestCase {

    private var isIntegration: Bool {
        ProcessInfo.processInfo.environment["OPENVERB_INTEGRATION_TESTS"] != nil
    }

    private var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.openverb/test-engine-\(getpid()).sock"
    }

    private var enginePath: String {
        ProcessInfo.processInfo.environment["OPENVERB_ENGINE_PATH"]
            ?? "/usr/local/bin/openverb-engine"
    }

    /// Path to the test model; nil when the env var is unset.
    private var testModelPath: String? {
        ProcessInfo.processInfo.environment["OPENVERB_TEST_MODEL"]
    }

    /// Path to the test mmproj; nil when the env var is unset.
    private var testMmprojPath: String? {
        ProcessInfo.processInfo.environment["OPENVERB_TEST_MMPROJ"]
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private func skipUnlessIntegration() throws {
        try XCTSkipUnless(isIntegration,
                          "Set OPENVERB_INTEGRATION_TESTS=1 to run")
    }

    /// Launch the engine subprocess.
    ///
    /// Always prepends `--listen --socket <path>`.  If `OPENVERB_TEST_MODEL`
    /// is set, also appends `--model <path>` (and `--mmproj <path>` when
    /// `OPENVERB_TEST_MMPROJ` is set) so tests work on machines that have no
    /// default model installed.  Any extra `arguments` are appended last.
    private func launchEngine(arguments: [String] = []) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: enginePath)

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { h in _ = h.availableData }

        var args = ["--listen", "--socket", socketPath]
        if let m = testModelPath  { args += ["--model",  m] }
        if let p = testMmprojPath { args += ["--mmproj", p] }
        args.append(contentsOf: arguments)
        proc.arguments = args

        return proc
    }

    // -----------------------------------------------------------------------
    // Test: connect → ping → pong
    // -----------------------------------------------------------------------

    func testPingPong() async throws {
        try skipUnlessIntegration()

        let proc = launchEngine()
        try proc.run()
        defer {
            proc.terminate()
            proc.waitUntilExit()
        }

        let client = EngineClient()
        defer { client.disconnect() }

        // Wait for engine to start listening.
        let expanded = socketPath.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser.path + socketPath.dropFirst()
            : socketPath

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do {
                try client.connect(path: expanded)
                try client.ping(timeoutMs: 2000)
                return // success
            } catch {
                client.disconnect()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        XCTFail("Engine did not respond to ping within 10s")
    }

    // -----------------------------------------------------------------------
    // Test: session.start → ready → audio → sentinel → non-empty result
    // -----------------------------------------------------------------------

    func testFullSession() async throws {
        try skipUnlessIntegration()

        let proc = launchEngine()
        try proc.run()
        defer {
            proc.terminate()
            proc.waitUntilExit()
        }

        let client = EngineClient()
        defer { client.disconnect() }

        let expanded = socketPath.hasPrefix("~")
            ? FileManager.default.homeDirectoryForCurrentUser.path + socketPath.dropFirst()
            : socketPath

        // Connect + ping to verify engine is alive.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do {
                try client.connect(path: expanded)
                try client.ping(timeoutMs: 2000)
                break
            } catch {
                client.disconnect()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // Start session.
        try client.waitForReady(context: ["app": "IntegrationTests"])
        // waitForReady returns on .ready.

        // Generate synthetic 16kHz 16-bit mono PCM: 1s of 440 Hz sine wave.
        let sampleRate = 16000
        let duration = 1.0
        let numSamples = Int(Double(sampleRate) * duration)
        var pcm = Data()
        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let val = Int16(20000.0 * sin(2.0 * .pi * 440.0 * t))
            var le = val.littleEndian
            pcm.append(Data(bytes: &le, count: 2))
        }

        // Send as 4096-byte frames.
        let chunkSize = 4096
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkSize, pcm.count)
            let frame = pcm[offset..<end]
            try client.sendAudioFrame(Data(frame))
            offset = end
        }
        try client.sendEndOfAudio()

        // Drain progress and wait for result.
        var gotResult = false
        let resultDeadline = Date().addingTimeInterval(120)
        while Date() < resultDeadline {
            let msg = try client.receiveMessage(timeoutMs: 5000)
            switch msg {
            case .result(let text, _):
                XCTAssertFalse(text?.isEmpty ?? true,
                               "Expected non-empty transcription")
                gotResult = true
                break
            case .error(let code, let message):
                XCTFail("Engine error: \(code): \(message)")
                break
            case .progress, .warning:
                continue
            default:
                continue
            }
            if gotResult { break }
        }
        XCTAssertTrue(gotResult, "Did not receive result within timeout")
    }

    // -----------------------------------------------------------------------
    // Test: EngineManager crash recovery (kill engine, verify auto-restart)
    // -----------------------------------------------------------------------

    func testCrashRecovery() async throws {
        try skipUnlessIntegration()

        let manager = EngineManager(
            socketPath: socketPath,
            enginePath: enginePath,
            modelPath: testModelPath,
            mmprojPath: testMmprojPath
        )

        // Launch and verify running.
        try manager.ensureRunning()
        XCTAssertTrue(manager.client.isConnected)

        // Kill the engine.
        let proc = manager.process
        XCTAssertNotNil(proc)
        if let p = proc {
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
        }

        // The client should notice the connection is dead on next I/O.
        Thread.sleep(forTimeInterval: 0.5)

        // Trigger crash recovery.
        do {
            try manager.handleCrash()
        } catch {
            XCTFail("Crash recovery failed: \(error)")
            return
        }

        XCTAssertTrue(manager.client.isConnected)

        // Verify new engine responds to ping.
        try manager.client.sendPing()
        let msg = try manager.client.receiveMessage(timeoutMs: 3000)
        guard case .pong = msg else {
            XCTFail("Expected pong after recovery, got: \(msg)")
            return
        }

        manager.shutdown()
    }
}
