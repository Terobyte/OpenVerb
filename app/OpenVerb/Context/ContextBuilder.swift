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

    /// Builds the context dictionary for the current session.
    ///
    /// - Parameters:
    ///   - targetApp: The app that was frontmost when ⌥Space was pressed.
    ///                Pass `nil` if no frontmost app could be determined.
    ///   - accessibilityApp: App to read accessibility info from (window title,
    ///                       selected text). Defaults to nil (no accessibility).
    ///   - pasteboard: Pasteboard to read clipboard from. Defaults to
    ///                 `NSPasteboard.general`.
    ///   - clipboardSnapshot: Pre-captured clipboard string (Bug 54). When nil,
    ///                        the live pasteboard is read instead.
    ///   - includeClipboard: Whether to include clipboard style. Default true.
    ///   - languageOverride: If non-nil, overrides locale language detection.
    /// - Returns: `[String: String]` suitable for `SessionStart.context`.
    ///
    /// Clipboard content is **never** sent as raw text. Instead, a structural
    /// descriptor (`clipboard_style`) is emitted via ``ClipboardStyle/describe(_:)``.
    @MainActor
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

        // "clipboard_style" — structural descriptor of clipboard content.
        // Raw clipboard text is never included; ClipboardStyle.describe() returns
        // a deterministic summary (length, coding/markdown/url flags, formality, case).
        // Uses pre-captured snapshot when available (Bug 54: avoids reading
        // TextInjector's paste as clipboard context on rapid re-press).
        if includeClipboard {
            let clip = clipboardSnapshot ?? pasteboard.string(forType: .string)
            if let c = clip, !c.isEmpty {
                context["clipboard_style"] = ClipboardStyle.describe(c)
            }
        }

        // "selected" — from Accessibility API; omit entirely if nil/empty.
        // NOTE: engine reads "selected" (not "selection") — see prompt_builder.cpp.
        // When accessibilityApp is nil, skip: reading OpenVerb's own selection is useless.
        if let app = accessibilityApp,
           let sel = accessibilityReader.readSelectedText(for: app), !sel.isEmpty {
            context["selected"] = truncateToUTF8Bytes(sel, limit: ClipboardStyle.byteLimit)
        }

        // "surrounding_before" / "surrounding_after" — text flanking the cursor
        // in the focused text field.  Used by the engine's Context struct to
        // provide insertion-point context for smarter formatting (Phase 8, step 66).
        // Omit when empty — no-op for apps that do not expose the full field value.
        if let app = accessibilityApp {
            let (before, after) = accessibilityReader.readCursorSurroundingText(for: app)
            if !before.isEmpty {
                context["surrounding_before"] = truncateToUTF8Bytes(before, limit: ClipboardStyle.byteLimit)
            }
            if !after.isEmpty {
                context["surrounding_after"] = truncateToUTF8Bytes(after, limit: ClipboardStyle.byteLimit)
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
