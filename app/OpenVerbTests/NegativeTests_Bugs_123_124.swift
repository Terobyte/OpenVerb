import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 123, Bug 124
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_123_124: XCTestCase {

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
    // Bug 123 — reset() skips modelDirectory trailing-slash normalization
    //           applied in init()
    //
    // AppSettings.init() normalizes modelDirectory by stripping any trailing
    // slash:
    //
    //   modelDirectory = rawDir.hasSuffix("/") ? String(rawDir.dropLast()) : rawDir
    //
    // AppSettings.reset() assigns the default value directly from
    // FileManager.homeDirectoryForCurrentUser without the same normalization:
    //
    //   modelDirectory = FileManager.default.homeDirectoryForCurrentUser
    //       .appendingPathComponent(".openverb/models").path
    //
    // FileManager.appendingPathComponent() can produce a trailing slash on some
    // macOS versions, so a reset() produces a stored value inconsistent with the
    // value a fresh init() would produce from the same path.
    //
    // EXPECTED: reset() applies the same trailing-slash normalization as init()
    //   (e.g. uses hasSuffix("/") guard, or strips via dropLast(), or builds the
    //   path and normalises before assigning).
    // ACTUAL:   reset() assigns the raw .path directly with no normalization.
    // =======================================================================

    func testBug123_ResetNormalizesModelDirectoryTrailingSlash() {
        guard let src = readSource("OpenVerb/Settings/AppSettings.swift") else {
            XCTFail(
                "Bug 123 CONFIRMED: Cannot read AppSettings.swift. " +
                "Fix: apply the same trailing-slash normalization in reset() as init() does " +
                "(e.g. use hasSuffix(\"/\") ? String(rawDir.dropLast()) : rawDir before assigning modelDirectory)."
            )
            return
        }

        // Isolate the reset() function body.
        guard let resetFuncRange = src.range(of: "func reset()") else {
            XCTFail(
                "Bug 123 CONFIRMED: reset() not found in AppSettings.swift — file structure changed."
            )
            return
        }

        // Extract from the function signature to the end of the file.
        let fromReset = String(src[resetFuncRange.lowerBound...])

        // Find the opening brace of the function body.
        guard let bodyOpenRange = fromReset.range(of: "{") else {
            XCTFail("Bug 123 CONFIRMED: Cannot locate reset() body in AppSettings.swift.")
            return
        }

        // Grab up to 600 chars of the body — reset() is a medium-length method.
        let bodyStart = bodyOpenRange.upperBound
        let bodyEnd   = fromReset.index(bodyStart,
                                        offsetBy: 600,
                                        limitedBy: fromReset.endIndex) ?? fromReset.endIndex
        let resetBody = String(fromReset[bodyStart..<bodyEnd])

        // The fix requires that the normalization expression appears in the reset() body
        // near the modelDirectory assignment.  The canonical normalization from init() is:
        //   hasSuffix("/") ... dropLast()
        // Any equivalent form (dropLast, hasSuffix) signals the fix is present.
        let hasNormalization = resetBody.contains("hasSuffix(\"/\")") || resetBody.contains("dropLast()")

        XCTAssertTrue(
            hasNormalization,
            "Bug 123 CONFIRMED: AppSettings.reset() assigns modelDirectory from " +
            "FileManager.homeDirectoryForCurrentUser.appendingPathComponent().path without " +
            "applying the same trailing-slash normalization that init() applies. " +
            "A reset() can produce a value inconsistent with what a fresh init() would load, " +
            "causing path-comparison mismatches elsewhere. " +
            "Fix: add the same normalization as init() — e.g. " +
            "`let raw = ...; modelDirectory = raw.hasSuffix(\"/\") ? String(raw.dropLast()) : raw`."
        )
    }

    // =======================================================================
    // Bug 124 — hotkeyModifiers = 0 (no modifiers) treated as "not set" on reload
    //
    // AppSettings.init() loads hotkeyModifiers with:
    //
    //   let storedMods = defaults.integer(forKey: Key.hotkeyModifiers)
    //   if storedMods != 0 { hotkeyModifiers = CGEventFlags(rawValue: UInt64(storedMods)) }
    //
    // defaults.integer(forKey:) returns 0 for both an absent key AND a stored
    // value of 0.  If the user deliberately saves a hotkey with no modifier
    // flags (CGEventFlags rawValue 0), the `if storedMods != 0` guard treats it
    // as absent and silently reverts to the default (.maskAlternate) on every
    // launch.
    //
    // EXPECTED: the load path distinguishes "key not present" from "key present
    //   with value 0".  The correct pattern is:
    //     defaults.object(forKey: Key.hotkeyModifiers) != nil
    //   (or defaults.contains(key:) / dictionaryRepresentation().keys.contains)
    //   as the existence check, followed by the integer read.
    // ACTUAL:   bare defaults.integer(forKey:) conflates 0 with absent.
    // =======================================================================

    func testBug124_HotkeyModifiersLoadUsesExistenceCheck() {
        guard let src = readSource("OpenVerb/Settings/AppSettings.swift") else {
            XCTFail(
                "Bug 124 CONFIRMED: Cannot read AppSettings.swift. " +
                "Fix: replace the bare defaults.integer(forKey: Key.hotkeyModifiers) existence " +
                "check with defaults.object(forKey: Key.hotkeyModifiers) != nil so that a " +
                "stored value of 0 is not treated as absent."
            )
            return
        }

        // Isolate the init() function body to avoid matching reset() or other methods.
        guard let initFuncRange = src.range(of: "init(defaults: UserDefaults") else {
            XCTFail(
                "Bug 124 CONFIRMED: init(defaults:) not found in AppSettings.swift — file structure changed."
            )
            return
        }

        // Extract from the init signature to the end of the file.
        let fromInit = String(src[initFuncRange.lowerBound...])

        // Grab a window large enough to cover the full init body (~800 chars).
        let windowEnd = fromInit.index(fromInit.startIndex,
                                       offsetBy: 800,
                                       limitedBy: fromInit.endIndex) ?? fromInit.endIndex
        let initBody = String(fromInit[fromInit.startIndex..<windowEnd])

        // The buggy pattern: load with defaults.integer and gate on != 0.
        // This conflates stored-0 with absent.
        let hasBuggyPattern = initBody.contains("defaults.integer(forKey: Key.hotkeyModifiers)")
            && initBody.contains("storedMods != 0")

        // The fix replaces the existence check with an object(forKey:) != nil guard.
        // Accept any of the correct existence-check forms:
        //   defaults.object(forKey: Key.hotkeyModifiers) != nil
        //   dictionaryRepresentation().keys.contains(Key.hotkeyModifiers)
        let hasFixedPattern = initBody.contains("object(forKey: Key.hotkeyModifiers)")

        XCTAssertFalse(
            hasBuggyPattern && !hasFixedPattern,
            "Bug 124 CONFIRMED: AppSettings.init() loads hotkeyModifiers with " +
            "`defaults.integer(forKey:)` and skips assignment when the result is 0. " +
            "defaults.integer(forKey:) returns 0 for both an absent key and a stored value of 0, " +
            "so a hotkey intentionally bound with no modifier flags silently reverts to the " +
            "default (.maskAlternate) on every app launch. " +
            "Fix: use `defaults.object(forKey: Key.hotkeyModifiers) != nil` as the existence " +
            "guard, then read the integer value unconditionally inside that guard."
        )
    }
}
