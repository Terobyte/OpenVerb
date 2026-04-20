import XCTest
@testable import OpenVerb

// Negative tests for: Bug 133, 134
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_133_134: XCTestCase {

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
    // Bug 133 — AccessibilityReaderTests tests only the mock — zero coverage
    //           of the real implementation
    //
    // All four tests in AccessibilityReaderTests.swift instantiate
    // MockAccessibilityReader.  Any regression in the real AccessibilityReader
    // class is completely invisible to the test suite — a broken real
    // implementation still passes every test.
    //
    // EXPECTED: at least one test instantiates the real AccessibilityReader
    //   directly (e.g. `AccessibilityReader()`) and exercises its methods,
    //   so a regression in the production code triggers a test failure.
    // ACTUAL:   every test uses MockAccessibilityReader; AccessibilityReader()
    //           is never instantiated in the test file.
    // =======================================================================

    func testBug133_AccessibilityReaderTestsExerciseRealImplementation() {
        guard let src = readSource("OpenVerbTests/AccessibilityReaderTests.swift") else {
            XCTFail("Bug 133 CONFIRMED: Cannot read AccessibilityReaderTests.swift. Fix: add at least one test that instantiates AccessibilityReader() (the real class, not the mock).")
            return
        }

        // The fix requires at least one occurrence of `AccessibilityReader()` —
        // instantiating the concrete implementation, not the mock subclass.
        // We explicitly reject `MockAccessibilityReader()` matches by checking
        // for the exact token `AccessibilityReader()` without a "Mock" prefix.
        let lines = src.components(separatedBy: "\n")
        let hasRealInstantiation = lines.contains { line in
            line.contains("AccessibilityReader()") && !line.contains("MockAccessibilityReader()")
        }

        XCTAssertTrue(
            hasRealInstantiation,
            "Bug 133 CONFIRMED: AccessibilityReaderTests.swift only instantiates " +
            "MockAccessibilityReader — the real AccessibilityReader class is never " +
            "exercised. Any regression in the production implementation is invisible " +
            "to the test suite. " +
            "Fix: add at least one test that creates a real AccessibilityReader() " +
            "instance and calls its methods directly."
        )
    }

    // =======================================================================
    // Bug 134 — PartialAccumulationTests never exercises AppState.livePartialText
    //           accumulation
    //
    // Every test in PartialAccumulationTests.swift wires onPartialResult to a
    // local closure variable (e.g. `var received: [(String, Int, Bool)] = []`
    // or `var accumulated = ""`).  The production accumulation path —
    // `appState.livePartialText += text` — is never tested.  A regression that
    // breaks livePartialText accumulation entirely would leave every existing
    // test green.
    //
    // EXPECTED: at least one test creates an AppState instance and asserts on
    //   its livePartialText property after driving the callback, so that a
    //   broken accumulation path causes a test failure.
    // ACTUAL:   no test references appState.livePartialText; accumulation is
    //           verified only against a throwaway local variable.
    // =======================================================================

    func testBug134_PartialAccumulationTestsExerciseLivePartialText() {
        guard let src = readSource("OpenVerbTests/PartialAccumulationTests.swift") else {
            XCTFail("Bug 134 CONFIRMED: Cannot read PartialAccumulationTests.swift. Fix: add at least one test that creates an AppState instance and asserts on appState.livePartialText.")
            return
        }

        // The fix requires both:
        //   (a) an AppState instance created in the test file, AND
        //   (b) an assertion against appState.livePartialText (not just a
        //       local variable), proving the production accumulation path runs.
        let hasAppStateInstance = src.contains("AppState()")
        let hasLivePartialTextAssertion = src.contains("appState.livePartialText")

        XCTAssertTrue(
            hasAppStateInstance && hasLivePartialTextAssertion,
            "Bug 134 CONFIRMED: PartialAccumulationTests.swift never exercises the " +
            "production accumulation path `appState.livePartialText += text`. " +
            "All tests inject a local closure variable and verify it — a complete " +
            "breakage of AppState.livePartialText accumulation would still pass. " +
            "Fix: add at least one test that creates an AppState() instance, drives " +
            "onPartialResult through it, and asserts on appState.livePartialText directly."
        )
    }
}
