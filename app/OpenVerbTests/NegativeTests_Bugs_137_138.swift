import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 137, 138
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_137_138: XCTestCase {

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
    // Bug 137 — polishedText and remainingInferenceMs lack private(set) —
    //           invariant bypass
    //
    // AppState.swift declares both properties as plain `@Published var`, giving
    // external code unrestricted write access.  Callers can set polishedText or
    // remainingInferenceMs at any time without going through state transitions,
    // bypassing the cleanup logic in applyEntryEffects (which clears these
    // values on every transition to .idle).
    //
    // EXPECTED: both properties use `private(set)`, so only AppState itself can
    //   mutate them while observers (views, tests) can still read them.
    //   Declaration form: `@Published private(set) var polishedText` and
    //   `@Published private(set) var remainingInferenceMs`.
    // ACTUAL: plain `@Published var` — no setter access control on either
    //         property.
    // =======================================================================

    func testBug137_polishedTextHasPrivateSetAccessControl() {
        guard let src = readSource("OpenVerb/State/AppState.swift") else {
            XCTFail(
                "Bug 137 CONFIRMED: Cannot read AppState.swift. " +
                "Fix: add private(set) to polishedText and remainingInferenceMs declarations."
            )
            return
        }

        XCTAssertTrue(
            src.contains("private(set) var polishedText"),
            "Bug 137 CONFIRMED: AppState.polishedText is declared as plain `@Published var` " +
            "with no setter access control — external code can write to it directly, bypassing " +
            "the cleanup logic in applyEntryEffects that clears it on every .idle transition. " +
            "Fix: change the declaration to `@Published private(set) var polishedText`."
        )
    }

    func testBug137_remainingInferenceMsHasPrivateSetAccessControl() {
        guard let src = readSource("OpenVerb/State/AppState.swift") else {
            XCTFail(
                "Bug 137 CONFIRMED: Cannot read AppState.swift. " +
                "Fix: add private(set) to polishedText and remainingInferenceMs declarations."
            )
            return
        }

        XCTAssertTrue(
            src.contains("private(set) var remainingInferenceMs"),
            "Bug 137 CONFIRMED: AppState.remainingInferenceMs is declared as plain `@Published var` " +
            "with no setter access control — external code can write to it directly, bypassing " +
            "the cleanup logic in applyEntryEffects that clears it on every .idle transition. " +
            "Fix: change the declaration to `@Published private(set) var remainingInferenceMs`."
        )
    }

    // =======================================================================
    // Bug 138 — testBug1 wrong first assertion — fails at wrong line when
    //           Bug 1 and Bug 39 coexist
    //
    // BugsMDTDDTests.testBug1_resetShouldClearAmplitudesSynchronously() calls
    // updateAmplitude() twice and then immediately asserts
    // `!vm.amplitudes.isEmpty` BEFORE calling reset().  If updateAmplitude is
    // itself async (Bug 1), this assertion fails with "Should have amplitudes
    // before reset" — a misleading message that has nothing to do with
    // reset()'s behaviour.  The real invariant under test (reset must clear
    // synchronously, Bug 39) is never reached, masking that regression.
    //
    // EXPECTED: the test calls reset() (or an equivalent state-clearing call)
    //   BEFORE making any assertion about whether amplitudes are empty — so the
    //   first meaningful assertion exercises the reset() path, not the
    //   updateAmplitude() path.
    // ACTUAL: `XCTAssertFalse(vm.amplitudes.isEmpty, ...)` appears BEFORE the
    //         `vm.reset()` call, causing an unrelated failure when Bug 1 exists.
    // =======================================================================

    func testBug138_testBug1ResetCalledBeforeFirstAssertion() {
        guard let src = readSource("OpenVerbTests/BugsMDTDDTests.swift") else {
            XCTFail(
                "Bug 138 CONFIRMED: Cannot read BugsMDTDDTests.swift. " +
                "Fix: in testBug1, call reset() before any XCTAssert on amplitudes."
            )
            return
        }

        // Locate the testBug1 function body.
        guard let funcRange = src.range(of: "func testBug1_resetShouldClearAmplitudesSynchronously()") else {
            XCTFail(
                "Bug 138 CONFIRMED: testBug1_resetShouldClearAmplitudesSynchronously() not found " +
                "in BugsMDTDDTests.swift — file structure changed, review manually."
            )
            return
        }

        // Extract from the function signature to the end of file so we can
        // compare the relative positions of reset() and the first assertion.
        let funcSuffix = String(src[funcRange.lowerBound...])

        // Find the first occurrence of vm.reset() within this function.
        guard let resetRange = funcSuffix.range(of: "vm.reset()") else {
            XCTFail(
                "Bug 138 CONFIRMED: vm.reset() not found inside " +
                "testBug1_resetShouldClearAmplitudesSynchronously(). " +
                "Fix: ensure the test calls vm.reset() before asserting on amplitude state."
            )
            return
        }

        // Find the first XCTAssert call within this function.
        guard let assertRange = funcSuffix.range(of: "XCTAssert") else {
            XCTFail(
                "Bug 138 CONFIRMED: No XCTAssert found inside " +
                "testBug1_resetShouldClearAmplitudesSynchronously(). " +
                "Fix: the test must call reset() first, then assert amplitudes are empty."
            )
            return
        }

        // The fix requires reset() to come BEFORE the first assertion.
        XCTAssertTrue(
            resetRange.lowerBound < assertRange.lowerBound,
            "Bug 138 CONFIRMED: testBug1_resetShouldClearAmplitudesSynchronously() places " +
            "XCTAssertFalse(vm.amplitudes.isEmpty, ...) BEFORE vm.reset() — when Bug 1 makes " +
            "updateAmplitude() async, this pre-reset assertion fails with a misleading message " +
            "('Should have amplitudes before reset') that has nothing to do with reset() " +
            "synchronicity, masking the actual Bug 39 regression. " +
            "Fix: move vm.reset() to before the first XCTAssert so the test correctly isolates " +
            "whether reset() clears amplitudes synchronously."
        )
    }
}
