import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 131, 132
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_131_132: XCTestCase {

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
    // Bug 131 — Test suite shares one UserDefaults suite name — fragile
    //           cross-test isolation
    //
    // AppSettingsTests.setUp() calls:
    //   UserDefaults.standard.removePersistentDomain(forName: "io.openverb.test")
    // and every test method constructs:
    //   UserDefaults(suiteName: "io.openverb.test")
    //
    // removePersistentDomain() clears on-disk storage but the in-memory cache
    // is implementation-defined: a key written by test A may still be visible
    // to test B if the backing store reloads before the cache is flushed.
    // Tests are order-dependent and fragile.
    //
    // EXPECTED: each test method receives a UNIQUE UserDefaults suite — either
    //   via UUID().uuidString generated per-test in setUp(), or via a unique
    //   per-test name (e.g. derived from the test name / UUID).  No two tests
    //   must share the same suite name string.
    // ACTUAL:   the hardcoded literal "io.openverb.test" is used everywhere;
    //           no UUID() or per-test uniqueness mechanism exists.
    // =======================================================================

    func testBug131_AppSettingsTestsUsesUniqueUserDefaultsSuitePerTest() {
        guard let src = readSource("OpenVerbTests/AppSettingsTests.swift") else {
            XCTFail(
                "Bug 131 CONFIRMED: Cannot read AppSettingsTests.swift. " +
                "Fix: generate a UUID().uuidString suite name in setUp() (or per test) so " +
                "every test run gets an isolated UserDefaults store."
            )
            return
        }

        // The fix requires a uniqueness mechanism in setUp() or at the class level.
        // We look for UUID().uuidString as the canonical uniqueness signal.
        let hasUUID = src.contains("UUID().uuidString") || src.contains("UUID()")

        XCTAssertTrue(
            hasUUID,
            "Bug 131 CONFIRMED: AppSettingsTests uses the hardcoded suite name " +
            "\"io.openverb.test\" for every test — removePersistentDomain() only clears " +
            "on-disk storage; the in-memory UserDefaults cache is implementation-defined and " +
            "can carry state written by a prior test into the next one, making test order " +
            "matter and results fragile. " +
            "Fix: in setUp(), assign `suiteName = UUID().uuidString` and pass that value to " +
            "every `UserDefaults(suiteName:)` call so each test gets a fresh, isolated store."
        )
    }

    // =======================================================================
    // Bug 132 — ContextBuilderTests asserts ctx["clipboard"] nil — key never
    //           exists; tests vacuously pass
    //
    // Production code (ContextBuilder) writes the key "clipboard_style", NOT
    // "clipboard".  The tests at lines 73–93 of ContextBuilderTests.swift
    // assert:
    //   XCTAssertNil(ctx["clipboard"], ...)
    //
    // Because ContextBuilder never writes a "clipboard" key under any
    // circumstance, these assertions are always true regardless of what the
    // production code actually does.  A complete regression in clipboard
    // context logic would leave these tests green.
    //
    // EXPECTED: the clipboard tests verify the key the production code actually
    //   writes ("clipboard_style"), not the phantom key "clipboard".  At minimum
    //   the tests that are intended to check that clipboard data is NOT stored
    //   raw must assert on "clipboard_style" (e.g. nil when empty/absent) so
    //   they exercise real production behaviour.
    // ACTUAL:   XCTAssertNil(ctx["clipboard"]) — the "clipboard" key is never
    //           written by production code, so these assertions are vacuously
    //           true and test nothing.
    // =======================================================================

    func testBug132_ContextBuilderTestsCheckClipboardStyleNotClipboard() {
        guard let src = readSource("OpenVerbTests/ContextBuilderTests.swift") else {
            XCTFail(
                "Bug 132 CONFIRMED: Cannot read ContextBuilderTests.swift. " +
                "Fix: replace XCTAssertNil(ctx[\"clipboard\"]) assertions with checks on " +
                "\"clipboard_style\" — the key that ContextBuilder actually writes."
            )
            return
        }

        // The bug: XCTAssertNil(ctx["clipboard"]) appears in the test file.
        // "clipboard" is never written by production code, so these assertions
        // are vacuously true and catch nothing.
        let hasVacuousClipboardNilCheck = src.contains("ctx[\"clipboard\"]")

        XCTAssertFalse(
            hasVacuousClipboardNilCheck,
            "Bug 132 CONFIRMED: ContextBuilderTests.swift asserts ctx[\"clipboard\"] == nil " +
            "in multiple test methods (testClipboardOmittedWhenNil, testClipboardOmittedWhenEmpty, " +
            "testClipboardKeyIsNeverEmittedWithRawText).  Production code (ContextBuilder) " +
            "never writes the key \"clipboard\" — it writes \"clipboard_style\".  These " +
            "assertions are always true, meaning the tests pass even when clipboard handling " +
            "is completely broken.  " +
            "Fix: replace XCTAssertNil(ctx[\"clipboard\"]) with assertions on " +
            "ctx[\"clipboard_style\"] to verify the key the production code actually emits " +
            "(e.g. XCTAssertNil(ctx[\"clipboard_style\"]) when clipboard is nil or empty)."
        )
    }
}
