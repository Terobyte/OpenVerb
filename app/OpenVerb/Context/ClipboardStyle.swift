import Foundation

struct ClipboardStyle {

    static let byteLimit = 10_240

    static func describe(_ text: String) -> String {
        let truncated = ContextBuilder.truncateToUTF8Bytes(text, limit: byteLimit)
        let len = truncated.utf8.count
        let hasCode = detectCode(truncated)
        let hasMarkdown = detectMarkdown(truncated)
        let hasURL = detectURL(truncated)
        let formality = detectFormality(truncated)
        let textCase = detectCase(truncated)
        return [
            "len:\(len)",
            "coding:\(hasCode)",
            "markdown:\(hasMarkdown)",
            "url:\(hasURL)",
            "formality:\(formality)",
            "case:\(textCase)"
        ].joined(separator: ";")
    }

    private static func detectCode(_ s: String) -> Bool {
        s.contains("```") || s.contains("~~~")
    }

    private static func detectMarkdown(_ s: String) -> Bool {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { return true }
            if trimmed.hasPrefix("- ") { return true }
            if trimmed.hasPrefix("* ") { return true }
            if trimmed.hasPrefix("> ") { return true }
            if let _ = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) { return true }
            if trimmed.hasPrefix("---") || trimmed.hasPrefix("***") || trimmed.hasPrefix("___") {
                if trimmed.count >= 3 { return true }
            }
        }
        if s.contains("**") || s.contains("__") { return true }
        if s.range(of: #"\[(.+?)\]\((.+?)\)"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"`[^`]+`"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func detectURL(_ s: String) -> Bool {
        s.range(of: #"https?://[^\s]+"#, options: .regularExpression) != nil
            || s.range(of: #"www\.[^\s]+"#, options: .regularExpression) != nil
    }

    private static func detectFormality(_ s: String) -> String {
        let lower = s.lowercased()
        let informalMarkers = ["lol", "omg", "btw", "idk", "tbh", "gonna", "wanna",
                               "gotta", "dunno", "kinda", "sorta", "yep", "nope",
                               "haha", "hehe", "rofl", "brb", "imo", "imho"]
        for marker in informalMarkers {
            // Bug 126 fix: use word-boundary regex so "lol" doesn't match inside "alcohol"
            if lower.range(of: "\\b\(marker)\\b", options: .regularExpression) != nil { return "casual" }
        }
        if s.range(of: #"[!]{2,}"#, options: .regularExpression) != nil { return "casual" }
        let alphabetic = s.filter { $0.isLetter }
        let upperCount = alphabetic.filter { $0.isUppercase }.count
        let total = alphabetic.count
        if total > 0 && Double(upperCount) / Double(total) > 0.6 { return "casual" }
        return "neutral"
    }

    private static func detectCase(_ s: String) -> String {
        let alphabetic = s.filter { $0.isLetter }
        if alphabetic.isEmpty { return "none" }
        let upperCount = alphabetic.filter { $0.isUppercase }.count
        let lowerCount = alphabetic.filter { $0.isLowercase }.count
        if upperCount == alphabetic.count { return "upper" }
        if lowerCount == alphabetic.count { return "lower" }
        let words = s.split(separator: " ")
        let titleCount = words.filter { word in
            guard let first = word.first, first.isLetter else { return false }
            return first.isUppercase
        }.count
        if words.count > 0 && titleCount == words.count { return "title" }
        return "mixed"
    }
}
