import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 140
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bug_140: XCTestCase {

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
    // Bug 140 — testBug27 search window of 3000 chars is fragile against
    //           future function growth
    //
    // testBug27 in OpenBugsNegativeTests.swift uses a hard-coded 3000-character
    // substring window to locate the POLLHUP/POLLIN ordering inside
    // recvJSONSync().  The recvJSONSync function is already ~3600 chars; if it
    // grows further (even minor edits), the POLLHUP check is pushed outside the
    // window and the test silently passes instead of detecting the regression.
    //
    // EXPECTED: the length constant passed to substring(_:from:length:) in
    //   testBug27 is >= 5000, OR the test searches the full file content after
    //   the function declaration rather than using a fixed-size window (i.e. no
    //   call to substring(_:from:length:) exists in the testBug27 body at all).
    // ACTUAL:   the constant is 3000 — smaller than the current function size —
    //           so the window silently misses the POLLHUP check.
    // =======================================================================

    func testBug140_testBug27WindowLargeEnoughOrUnbounded() {
        guard let src = readSource("OpenVerbTests/OpenBugsNegativeTests.swift") else {
            XCTFail(
                "Bug 140 CONFIRMED: Cannot read OpenBugsNegativeTests.swift. " +
                "Fix: ensure testBug27 uses a search window >= 5000 chars, or searches " +
                "the full file content after the recvJSONSync declaration."
            )
            return
        }

        // Isolate the testBug27 function body.
        guard let funcRange = src.range(of: "func testBug27_pollhupCheckedBeforePollin()") else {
            // Function was renamed or removed — treat as fixed only if no
            // small-window substring call exists anywhere in the file for this purpose.
            XCTAssertFalse(
                src.contains("substring(content, from: fnRange.lowerBound, length: 3000)"),
                "Bug 140 CONFIRMED: testBug27 3000-char window still present. " +
                "Fix: raise the length constant to >= 5000 or remove the fixed window."
            )
            return
        }

        // Extract a window that covers the body of testBug27; 800 chars is
        // sufficient to reach the substring() call without spilling into the
        // next test function.
        let afterSig = String(src[funcRange.lowerBound...])
        let windowEnd = afterSig.index(
            afterSig.startIndex,
            offsetBy: 800,
            limitedBy: afterSig.endIndex
        ) ?? afterSig.endIndex
        let testBody = String(afterSig[afterSig.startIndex..<windowEnd])

        // Case 1: the test still calls substring(_:from:length:) with a fixed
        // length.  Extract the numeric literal to check its value.
        if testBody.contains("substring(") {
            // Find the length argument — pattern: `length: <number>`
            // We look for the first occurrence of "length: " followed by digits.
            let lengthPattern = "length: "
            guard let lengthKeyRange = testBody.range(of: lengthPattern) else {
                // substring() present but no length: argument — unusual; pass through.
                return
            }
            let afterLength = String(testBody[lengthKeyRange.upperBound...])
            // Collect all leading digits to form the numeric literal.
            let digits = afterLength.prefix(while: { $0.isNumber })
            guard let windowSize = Int(digits), !digits.isEmpty else {
                XCTFail(
                    "Bug 140 CONFIRMED: testBug27 calls substring() but the length " +
                    "argument could not be parsed. " +
                    "Fix: use a length >= 5000 or replace with a full-content search."
                )
                return
            }
            XCTAssertGreaterThanOrEqual(
                windowSize,
                5000,
                "Bug 140 CONFIRMED: testBug27 in OpenBugsNegativeTests.swift passes " +
                "length: \(windowSize) to substring(_:from:length:). " +
                "recvJSONSync() is already ~3600 chars; any further growth pushes the " +
                "POLLHUP check outside the window and the test silently misreports 'pass'. " +
                "Fix: raise the length constant to >= 5000, or replace the fixed window " +
                "with a search over the entire file content after the function declaration."
            )
        }
        // Case 2: no substring() call — the test was rewritten to search without
        // an arbitrary length limit.  This is the correct fix; nothing to assert.
    }
}
