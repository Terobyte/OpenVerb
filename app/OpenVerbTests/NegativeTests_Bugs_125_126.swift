import XCTest
import AppKit
@testable import OpenVerb

// Negative tests for: Bug 125, 126
// Tests FAIL while the bug exists. GREEN = bug fixed.
final class NegativeTests_Bugs_125_126: XCTestCase {

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
    // Bug 125 — updateNSView no-op leaves ShortcutRecorder in recording state
    //           after external reset
    //
    // ShortcutCaptureViewRepresentable.updateNSView() is a no-op:
    //   func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {}
    //
    // When the "Reset to Default" action fires while the recorder is active,
    // SwiftUI calls updateNSView to push the new binding value into the view.
    // Because updateNSView does nothing, the view remains in recording mode —
    // the next keypress overwrites the just-reset value with whatever the user
    // types next.
    //
    // EXPECTED: updateNSView contains logic to sync the view with the new
    //   binding values, e.g. calling nsView.stopRecording() when the binding
    //   changes out from under an active recording session, or updating a
    //   displayed-key property on the NSView subclass.
    // ACTUAL:   updateNSView body is completely empty — no sync at all.
    // =======================================================================

    func testBug125_UpdateNSViewIsNotNoOp() {
        guard let src = readSource("OpenVerb/Input/ShortcutRecorder.swift") else {
            XCTFail(
                "Bug 125 CONFIRMED: Cannot read ShortcutRecorder.swift. " +
                "Fix: implement updateNSView(_:context:) in ShortcutCaptureViewRepresentable " +
                "to sync view state with the current binding values."
            )
            return
        }

        // Isolate the updateNSView function body.
        guard let sigRange = src.range(of: "func updateNSView(_ nsView: ShortcutCaptureView, context: Context)") else {
            // If the signature changed, verify the no-op form is gone.
            XCTAssertFalse(
                src.contains("func updateNSView") && src.contains("context: Context) {}"),
                "Bug 125 CONFIRMED: updateNSView(_:context:) has an empty no-op body. " +
                "Fix: add logic to sync nsView state (e.g. call stopRecording() or update " +
                "a displayed-key property) so that external binding resets are reflected in the view."
            )
            return
        }

        // Extract the text from the signature onward so we can inspect the body.
        let afterSig = String(src[sigRange.upperBound...])

        // Find the opening brace of the body.
        guard let braceOpen = afterSig.range(of: "{") else {
            XCTFail("Bug 125 CONFIRMED: Cannot locate updateNSView body opening brace.")
            return
        }

        // Capture up to 300 chars of the body to check for any non-trivial content.
        let bodyStart = braceOpen.upperBound
        let bodyEnd   = afterSig.index(bodyStart,
                                        offsetBy: 300,
                                        limitedBy: afterSig.endIndex) ?? afterSig.endIndex
        let body = String(afterSig[bodyStart..<bodyEnd])

        // A no-op body closes immediately: the first non-whitespace after `{` is `}`.
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNoOp = trimmedBody.hasPrefix("}")

        XCTAssertFalse(
            isNoOp,
            "Bug 125 CONFIRMED: ShortcutCaptureViewRepresentable.updateNSView(_:context:) " +
            "has an empty body — SwiftUI calls it whenever the bound keyCode/modifiers change " +
            "(e.g. on Reset to Default) but the view never receives the update. If the recorder " +
            "is active at that moment the next keypress silently overwrites the reset value. " +
            "Fix: implement updateNSView to sync nsView with the current binding values, at " +
            "minimum by calling nsView.stopRecording() when the binding changes mid-session."
        )
    }

    // =======================================================================
    // Bug 126 — detectFormality substring match fires inside unrelated words
    //
    // ClipboardStyle.detectFormality() checks informal markers with plain
    // String.contains():
    //   if lower.contains("lol") { return "casual" }   // fires on "alcohol"
    //   if lower.contains("imo") { return "casual" }   // fires on "massimo", "maximo",
    //                                                  //   Italian words ending -imo
    //   if lower.contains("brb") { return "casual" }   // fires on "Saarbrücken"
    //
    // Scientific or foreign-language text is therefore misclassified as casual
    // when any informal marker appears as a substring inside a longer word.
    //
    // EXPECTED: detectFormality uses word-boundary detection — either a regex
    //   with \b anchors around each marker, or checks that the marker is
    //   surrounded by non-word characters (spaces, punctuation, start/end of
    //   string) so it only matches whole words.
    // ACTUAL:   plain contains() substring matching — no boundary check.
    // =======================================================================

    func testBug126_DetectFormalityUsesWordBoundaries() {
        guard let src = readSource("OpenVerb/Context/ClipboardStyle.swift") else {
            XCTFail(
                "Bug 126 CONFIRMED: Cannot read ClipboardStyle.swift. " +
                "Fix: replace plain contains() marker checks in detectFormality() with " +
                "word-boundary regex (\\\\b markers \\\\b) or equivalent whole-word detection."
            )
            return
        }

        // Isolate the detectFormality function body.
        guard let funcRange = src.range(of: "private static func detectFormality(") else {
            XCTFail("Bug 126 CONFIRMED: detectFormality() not found in ClipboardStyle.swift — file structure changed, review manually.")
            return
        }

        let afterFunc = String(src[funcRange.lowerBound...])

        // Capture enough of the function to cover all the marker checks (~600 chars).
        let windowEnd = afterFunc.index(afterFunc.startIndex,
                                         offsetBy: 600,
                                         limitedBy: afterFunc.endIndex) ?? afterFunc.endIndex
        let window = String(afterFunc[afterFunc.startIndex..<windowEnd])

        // The buggy pattern: lower.contains("<marker>") where the marker is one of
        // the known casual strings and there is no regex/boundary wrapper.
        // A plain contains() call on the lowercased string looks like:
        //   lower.contains("lol")
        // We check for at least one such literal — if any exist the bug is present.
        let plainContainsPattern = #"lower\.contains\("[a-z]+"#
        let hasPlainContains = window.range(of: plainContainsPattern, options: .regularExpression) != nil

        // A correct fix must use word-boundary matching. Accept any of:
        //   (a) \b in a regex string literal (word boundary anchor)
        //   (b) checking surrounding characters with e.g. wholeMatch, components,
        //       split on non-word chars, or a dedicated helper function that wraps
        //       the boundary logic.
        // We gate on the presence of \b in the function body as the primary signal.
        let hasWordBoundary = window.contains("\\b")

        // The bug is confirmed if plain contains() is still used AND no \b boundary
        // anchoring is present in the function.
        XCTAssertFalse(
            hasPlainContains && !hasWordBoundary,
            "Bug 126 CONFIRMED: ClipboardStyle.detectFormality() uses plain lower.contains() " +
            "for informal markers — \"lol\" matches inside \"alcohol\", \"imo\" inside \"massimo\", " +
            "\"brb\" inside \"Saarbrücken\", etc., causing false casual classifications for " +
            "scientific and foreign-language text. " +
            "Fix: replace contains() calls with a word-boundary regex, e.g. " +
            "lower.range(of: \"\\\\b\" + marker + \"\\\\b\", options: .regularExpression) != nil, " +
            "so only standalone tokens are matched."
        )
    }
}
