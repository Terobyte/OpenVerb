import Foundation
import AppKit

// ---------------------------------------------------------------------------
// ContextBuilder — assembles the context dictionary for session.start.
//
// Protocol abstraction allows unit testing without real NSRunningApplication
// or NSPasteboard.
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
// PasteboardReadable — protocol wrapping NSPasteboard for testability.
// NSPasteboard conforms via extension below.
// ---------------------------------------------------------------------------

protocol PasteboardReadable {
    func string(forType: NSPasteboard.PasteboardType) -> String?
}

extension NSPasteboard: PasteboardReadable {}

// ---------------------------------------------------------------------------
// ContextBuilder
// ---------------------------------------------------------------------------

struct ContextBuilder {

    // Maximum UTF-8 byte length for the clipboard context field.
    static let clipboardByteLimit = 10_240

    /// Builds the context dictionary for the current session.
    ///
    /// - Parameters:
    ///   - targetApp: The app that was frontmost when ⌥Space was pressed.
    ///                Pass `nil` if no frontmost app could be determined.
    ///   - accessibilityApp: App to read accessibility info from (window title,
    ///                       selected text). Defaults to nil (no accessibility).
    ///   - pasteboard: Pasteboard to read clipboard from. Defaults to
    ///                 `NSPasteboard.general`.
    ///   - includeClipboard: Whether to include clipboard content. Default true.
    ///   - languageOverride: If non-nil, overrides locale language detection.
    /// - Returns: `[String: String]` suitable for `SessionStart.context`.
    static func build(
        targetApp: AppIdentifiable?,
        accessibilityApp: NSRunningApplication? = nil,
        pasteboard: PasteboardReadable = NSPasteboard.general,
        includeClipboard: Bool = true,
        languageOverride: String? = nil
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

        // "language" — BCP-47 language code from current locale, or override.
        if let override = languageOverride, !override.isEmpty {
            context["language"] = override
        } else {
            context["language"] = Locale.current.language.languageCode?.identifier ?? "en"
        }

        // "window" — always empty string in MVP3 (Accessibility API deferred to MVP4).
        context["window"] = ""

        // "clipboard" — read from pasteboard if enabled; omit if nil or empty.
        if includeClipboard,
           let clip = pasteboard.string(forType: .string),
           !clip.isEmpty {
            context["clipboard"] = truncateToUTF8Bytes(clip, limit: clipboardByteLimit)
        }

        // "selected" is set from Accessibility API — deferred to MVP4.

        return context
    }

    /// Truncates `s` to at most `limit` UTF-8 bytes without splitting
    /// multi-byte characters (including surrogate pairs / emoji).
    static func truncateToUTF8Bytes(_ s: String, limit: Int) -> String {
        guard s.utf8.count > limit else { return s }
        var count = 0
        var result = ""
        for char in s {
            let charBytes = String(char).utf8.count
            if count + charBytes > limit { break }
            result.append(char)
            count += charBytes
        }
        return result
    }
}
