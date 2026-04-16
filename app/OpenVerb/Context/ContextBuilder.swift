import Foundation
import AppKit

// ---------------------------------------------------------------------------
// ContextBuilder — assembles the context dictionary for session.start.
//
// MVP3 scope: "app" + "language" only.
// Accessibility API (window title, selection) is deferred to MVP4.
//
// Protocol abstraction allows unit testing without real NSRunningApplication.
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
// ContextBuilder
// ---------------------------------------------------------------------------

struct ContextBuilder {

    /// Builds the context dictionary for the current session.
    ///
    /// - Parameters:
    ///   - targetApp: The app that was frontmost when ⌥Space was pressed.
    ///                Pass `nil` if no frontmost app could be determined.
    /// - Returns: `[String: String]` suitable for `SessionStart.context`.
    static func build(
        targetApp: AppIdentifiable?
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

        // "language" — BCP-47 language code from current locale.
        context["language"] = Locale.current.language.languageCode?.identifier ?? "en"

        // "window" — always empty string in MVP3 (Accessibility API deferred to MVP4).
        // The engine uses this value to select formatting style; empty string signals
        // "no window title available, apply default style."
        context["window"] = ""

        // "selection" is omitted entirely (requires Accessibility API — MVP4).

        return context
    }

}
