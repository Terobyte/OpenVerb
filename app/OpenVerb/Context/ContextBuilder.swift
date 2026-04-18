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
        accessibilityReader: AccessibilityReadable = AccessibilityReader(),
        clipboardSnapshot: String? = nil,
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

        // "window" — from Accessibility API; empty string if unavailable.
        // When accessibilityApp is nil: skip — reading OpenVerb's own window title
        // is useless and would confuse the model.
        if let app = accessibilityApp {
            context["window"] = accessibilityReader.readWindowTitle(for: app) ?? ""
        } else {
            context["window"] = ""
        }

        // "clipboard" — use pre-captured snapshot when available (Bug 54 fix: avoids
        // reading TextInjector's paste as clipboard context on rapid re-press), or
        // fall back to live pasteboard read for backwards-compatible callers.
        if includeClipboard {
            let clip = clipboardSnapshot ?? pasteboard.string(forType: .string)
            if let c = clip, !c.isEmpty {
                context["clipboard"] = truncateToUTF8Bytes(c, limit: clipboardByteLimit)
            }
        }

        // "selected" — from Accessibility API; omit entirely if nil/empty.
        // NOTE: engine reads "selected" (not "selection") — see prompt_builder.cpp.
        // When accessibilityApp is nil, skip: reading OpenVerb's own selection is useless.
        if let app = accessibilityApp,
           let sel = accessibilityReader.readSelectedText(for: app), !sel.isEmpty {
            context["selected"] = truncateToUTF8Bytes(sel, limit: clipboardByteLimit)
        }

        // "surrounding_before" / "surrounding_after" — text flanking the cursor
        // in the focused text field.  Used by the engine's Context struct to
        // provide insertion-point context for smarter formatting (Phase 8, step 66).
        // Omit when empty — no-op for apps that do not expose the full field value.
        if let app = accessibilityApp {
            let (before, after) = accessibilityReader.readCursorSurroundingText(for: app)
            if !before.isEmpty {
                context["surrounding_before"] = truncateToUTF8Bytes(before, limit: clipboardByteLimit)
            }
            if !after.isEmpty {
                context["surrounding_after"] = truncateToUTF8Bytes(after, limit: clipboardByteLimit)
            }
        }

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
