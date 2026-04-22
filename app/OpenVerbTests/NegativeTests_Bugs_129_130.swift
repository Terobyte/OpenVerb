import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 129, 130
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_129_130: XCTestCase {

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
    // Bug 129 — commitSendCallback + interim-frame ordering race —
    //           out-of-order frame to engine
    //
    // OpenVerbApp.swift (lines ~732–742):
    //   let interim = audioSession.commitSendCallback(liveCallback)
    //   for chunk in interim {
    //       engineManager.engineClient.sendAudioFrame(chunk)   // ioQueue.async
    //   }
    //   engineManager.engineClient.syncOnIOQueue()
    //
    // commitSendCallback() atomically installs the live callback.  The audio
    // thread can call send(chunk) → sendAudioFrame → ioQueue.async immediately
    // after the lock in commitSendCallback() is released — BEFORE the caller's
    // for-loop has dispatched even the first interim frame to ioQueue.  Because
    // sendAudioFrame always uses ioQueue.async, a live frame dispatched by the
    // audio thread can land in the ioQueue *before* an older interim frame
    // dispatched by the main thread, violating chronological ordering.
    //
    // EXPECTED: interim frames are sent to the engine before any live frame
    //   can race ahead of them.  This requires one of:
    //   (a) The interim loop uses ioQueue.sync (or a dedicated sync fence) so
    //       each interim frame is fully enqueued before the audio thread can
    //       interleave.
    //   (b) commitSendCallback() internally dispatches the interim frames onto
    //       ioQueue itself (before returning) so ordering is guaranteed inside
    //       the critical section.
    //   (c) The live callback dispatches to ioQueue.sync instead of ioQueue.async
    //       (not viable without audio stutter — the real fix is (a) or (b)).
    // ACTUAL:   sendAudioFrame uses ioQueue.async unconditionally; the interim
    //           for-loop on the main thread races against live audio-thread
    //           dispatches on the same serial queue, and a live frame can arrive
    //           at the engine before an earlier interim frame.
    // =======================================================================

    func testBug129_InterimFramesEnqueuedBeforeLiveCallbackCanRace() {
        guard let appSrc = readSource("OpenVerb/App/OpenVerbApp.swift") else {
            XCTFail("Cannot read OpenVerbApp.swift"); return
        }
        // Phase 8: commitSendCallback + interim-frame ordering replaced by AudioRingBuffer.
        // Frames are written to the ring buffer by the audio tap with monotonically
        // increasing timestamps (_ringBufferTimestamp), and consumed by
        // AudioPipeline.streamLive via afterTimestamp: lastSentTimestamp. Both write and
        // read paths are strictly ordered — no concurrent main-thread/audio-thread race.
        //
        // Verify Phase 8 design: commitSendCallback is gone; ring buffer timestamps provide ordering.
        let stillHasCommitSendCallback = appSrc.contains("commitSendCallback")
        XCTAssertFalse(stillHasCommitSendCallback,
            "Bug 129 CONFIRMED: commitSendCallback still present in OpenVerbApp.swift. " +
            "Phase 8 should replace this with ring buffer writes from AudioSession.")

        guard let audioSrc = readSource("OpenVerb/Input/AudioSession.swift") else {
            XCTFail("Cannot read AudioSession.swift"); return
        }
        let hasTimestampOrdering = audioSrc.contains("_ringBufferTimestamp")
        XCTAssertTrue(hasTimestampOrdering,
            "Bug 129 CONFIRMED (Phase 8): AudioSession ring buffer path lacks monotonic " +
            "timestamp writes (_ringBufferTimestamp). Frame ordering is not guaranteed. " +
            "Fix: write each chunk with an incrementing timestamp so the consumer reads " +
            "frames in strict chronological order via afterTimestamp: lastSentTimestamp.")
    }

    // =======================================================================
    // Bug 130 — testSetAndGetCustomHotkey never tests UserDefaults round-trip
    //
    // AppSettingsTests.swift (lines ~38–43):
    //   let settings = AppSettings(defaults: UserDefaults(suiteName: "io.openverb.test")!)
    //   settings.hotkeyKeyCode = 0x32
    //   settings.hotkeyModifiers = .maskAlternate
    //   XCTAssertEqual(settings.hotkeyKeyCode, 0x32)
    //
    // The test creates ONE AppSettings instance, sets a value, then reads it
    // back from the SAME in-memory instance.  This only proves that the
    // property setter and getter work — it does NOT verify that the value was
    // written to UserDefaults and survives loading a fresh AppSettings instance.
    // A broken persistence implementation (e.g. a bare stored property that
    // ignores UserDefaults entirely) would pass this test trivially.
    //
    // EXPECTED: testSetAndGetCustomHotkey creates a SECOND AppSettings instance
    //   backed by the same UserDefaults suite (or explicitly reloads from
    //   UserDefaults after the set) and asserts the persisted value matches —
    //   proving the round-trip through UserDefaults works.
    // ACTUAL:   only one AppSettings instance is created; the assertion reads
    //           back from the same object that performed the write, bypassing
    //           the UserDefaults storage path entirely.
    // =======================================================================

    func testBug130_SetAndGetCustomHotkeyVerifiesUserDefaultsRoundTrip() {
        guard let src = readSource("OpenVerbTests/AppSettingsTests.swift") else {
            XCTFail("Bug 130 CONFIRMED: Cannot read AppSettingsTests.swift. Fix: rewrite " +
                    "testSetAndGetCustomHotkey to create a second AppSettings instance (or reload " +
                    "from UserDefaults) and assert the persisted value to test the round-trip.")
            return
        }

        // Isolate the testSetAndGetCustomHotkey function body.
        // We need only the text between the opening `{` of this specific function
        // and its closing `}` — not adjacent functions.
        guard let funcRange = src.range(of: "func testSetAndGetCustomHotkey()") else {
            XCTFail("Bug 130 CONFIRMED: testSetAndGetCustomHotkey not found in AppSettingsTests.swift — " +
                    "the function was renamed or removed. Review manually.")
            return
        }

        // Advance past the function declaration to find the opening `{`.
        let afterDecl = String(src[funcRange.upperBound...])
        guard let bodyOpenRange = afterDecl.range(of: "{") else {
            XCTFail("Bug 130 CONFIRMED: Cannot locate opening brace of testSetAndGetCustomHotkey.")
            return
        }

        // Walk forward from the opening brace to find the matching closing `}`.
        // We track brace depth to correctly handle nested braces.
        let bodyContent = String(afterDecl[bodyOpenRange.upperBound...])
        var depth = 1
        var funcBodyChars: [Character] = []
        for ch in bodyContent {
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            funcBodyChars.append(ch)
        }
        let funcBody = String(funcBodyChars)

        // Count AppSettings instantiations strictly within this function's body.
        // A round-trip test requires at least TWO: one writer and one fresh reader.
        let instantiations = funcBody.components(separatedBy: "AppSettings(defaults:").count - 1

        // Alternative fix: the test may read the value directly from UserDefaults
        // after the set, without creating a second AppSettings instance.
        let readsFromUserDefaults = funcBody.contains("UserDefaults") &&
                                    (funcBody.contains(".integer(forKey:") ||
                                     funcBody.contains(".object(forKey:") ||
                                     funcBody.contains(".value(forKey:"))

        XCTAssertTrue(
            instantiations >= 2 || readsFromUserDefaults,
            "Bug 130 CONFIRMED: testSetAndGetCustomHotkey reads hotkeyKeyCode back from the same " +
            "AppSettings instance that wrote it — this only tests the in-memory property, not " +
            "UserDefaults persistence. A stored property that ignores UserDefaults entirely would " +
            "pass this test. " +
            "Fix: create a second AppSettings(defaults:) backed by the same suite and assert " +
            "the value equals 0x32, proving the value survived a reload from UserDefaults."
        )
    }
}
