import Foundation
import AppKit

// ---------------------------------------------------------------------------
// ContextBuilder — assembles the context dictionary for session.start.
//
// MVP3 scope: "app" + "clipboard" + "language" only.
// Accessibility API (window title, selection) is deferred to MVP4.
//
// Protocol abstractions allow unit testing without real NSRunningApplication
// or NSPasteboard instances.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// AppIdentifiable — protocol wrapping the NSRunningApplication fields used
// for context assembly.  NSRunningApplication conforms via extension below.
// ---------------------------------------------------------------------------

protocol AppIdentifiable {
    var bundleIdentifier: String? { get }
    var localizedName: String? { get }
}

extension NSRunningApplication: AppIdentifiable {}

// ---------------------------------------------------------------------------
// PasteboardReadable — minimal clipboard abstraction for testability.
// ---------------------------------------------------------------------------

protocol PasteboardReadable {
    func string(forType: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: PasteboardReadable {}

// ---------------------------------------------------------------------------
// ContextBuilder
// ---------------------------------------------------------------------------

struct ContextBuilder {

    /// Builds the context dictionary for the current session.
    ///
    /// - Parameters:
    ///   - targetApp: The app that was frontmost when ⌥Space was pressed.
    ///                Pass `nil` if no frontmost app could be determined.
    ///   - pasteboard: Clipboard source; defaults to `NSPasteboard.general`.
    /// - Returns: `[String: String]` suitable for `SessionStart.context`.
    static func build(
        targetApp: AppIdentifiable?,
        pasteboard: PasteboardReadable = NSPasteboard.general
    ) async -> [String: String] {
        var context: [String: String] = [:]

        // "app" — prefer bundleIdentifier, fall back to localizedName, then "unknown".
        if let id = targetApp?.bundleIdentifier, !id.isEmpty {
            context["app"] = id
        } else if let name = targetApp?.localizedName, !name.isEmpty {
            context["app"] = name
        } else {
            context["app"] = "unknown"
        }

        // "clipboard" — truncate to 10 240 UTF-8 bytes at a character boundary;
        // omit key entirely if clipboard is nil or empty.
        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            context["clipboard"] = truncateToUTF8Bytes(raw, limit: 10_240)
        }

        // "language" — BCP-47 language code from current locale.
        context["language"] = Locale.current.language.languageCode?.identifier ?? "en"

        // "window" — always empty string in MVP3 (Accessibility API deferred to MVP4).
        // The engine uses this value to select formatting style; empty string signals
        // "no window title available, apply default style."
        context["window"] = ""

        // "selection" is omitted entirely (requires Accessibility API — MVP4).

        return context
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Truncates `s` to at most `limit` UTF-8 bytes, preserving whole
    /// characters by walking back from the cut point through any continuation
    /// bytes (0x10xxxxxx, i.e. byte & 0xC0 == 0x80).
    static func truncateToUTF8Bytes(_ s: String, limit: Int) -> String {
        let allBytes = Array(s.utf8)
        guard allBytes.count > limit else { return s }
        var end = limit
        // Walk back through UTF-8 continuation bytes to find the leading byte.
        while end > 0 && (allBytes[end - 1] & 0xC0) == 0x80 {
            end -= 1
        }
        // Check if the leading byte starts an incomplete multi-byte sequence.
        if end > 0 {
            let lead = allBytes[end - 1]
            if lead & 0x80 != 0 {
                let expected: Int
                if lead & 0xE0 == 0xC0      { expected = 2 }
                else if lead & 0xF0 == 0xE0 { expected = 3 }
                else if lead & 0xF8 == 0xF0 { expected = 4 }
                else                         { expected = 1 }
                let seqLen = limit - (end - 1)
                if seqLen < expected {
                    end -= 1  // incomplete — remove leading byte
                } else {
                    end = end - 1 + expected  // complete — restore full sequence
                }
            }
        }
        return String(bytes: Array(allBytes.prefix(end)), encoding: .utf8) ?? s
    }
}
