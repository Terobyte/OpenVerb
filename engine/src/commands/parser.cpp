// ---------------------------------------------------------------------------
// parser.cpp — Voice command parser implementation.
//
// See parser.h for the full contract.
//
// Normalisation steps (in order):
//   1. Trim leading/trailing ASCII whitespace.
//   2. Strip one trailing punctuation character (. , ! ?) if present.
//   3. Lowercase the result.
//   4. Exact whole-string lookup in COMMAND_KEYWORDS.
//
// No substring or prefix matching is performed.  "delete that and more"
// is NOT a command match — it is returned as plain text verbatim.
// ---------------------------------------------------------------------------

#include "commands/parser.h"
#include "commands/keywords.h"

#include <algorithm>
#include <cctype>
#include <string>

static bool is_unicode_space(unsigned char c0, const std::string& s, size_t pos, int& len) {
    auto peek = [&](size_t i) -> unsigned char {
        return (pos + i < s.size()) ? static_cast<unsigned char>(s[pos + i]) : 0;
    };
    if (c0 == 0xC2 && peek(1) == 0xA0) { len = 2; return true; }
    if (c0 == 0xE2) {
        unsigned char b1 = peek(1), b2 = peek(2);
        if (b1 == 0x80 && (b2 == 0x80 || b2 == 0x81 || b2 == 0x82 ||
                           b2 == 0x83 || b2 == 0x84 || b2 == 0x85 ||
                           b2 == 0x86 || b2 == 0x87 || b2 == 0x88 ||
                           b2 == 0x89 || b2 == 0x8A || b2 == 0x8B ||
                           b2 == 0x8C || b2 == 0x8D || b2 == 0x8E ||
                           b2 == 0x8F || b2 == 0xA0))
            { len = 3; return true; }
    }
    if (c0 == 0xEF && peek(1) == 0xBB && peek(2) == 0xBF) { len = 3; return true; }
    return false;
}

static void trim_whitespace(std::string& s) {
    auto is_ws = [&](size_t pos) -> int {
        unsigned char c = static_cast<unsigned char>(s[pos]);
        if (std::isspace(c)) return 1;
        int len = 0;
        if (is_unicode_space(c, s, pos, len)) return len;
        return 0;
    };

    size_t start = 0;
    while (start < s.size()) {
        int w = is_ws(start);
        if (w == 0) break;
        start += static_cast<size_t>(w);
    }
    size_t end = s.size();
    while (end > start) {
        int w = is_ws(end - 1);
        if (w == 0) break;
        end -= static_cast<size_t>(w);
    }
    s = s.substr(start, end - start);
}

// ---------------------------------------------------------------------------
// strip_trailing_punct — remove exactly one trailing punctuation character.
//
// Handles ASCII punctuation (. , ! ?) and common CJK / fullwidth Unicode
// punctuation characters:
//   U+3002 。 CJK fullstop         (UTF-8: 0xE3 0x80 0x82)
//   U+3001 、 CJK enumeration comma (UTF-8: 0xE3 0x80 0x81)
//   U+FF01 ！ fullwidth exclamation (UTF-8: 0xEF 0xBC 0x81)
//   U+FF1F ？ fullwidth question    (UTF-8: 0xEF 0xBC 0x9F)
//   U+FF0C ， fullwidth comma       (UTF-8: 0xEF 0xBC 0x8C)
//   U+FF0E ． fullwidth full stop   (UTF-8: 0xEF 0xBC 0x8E)
//   U+300D 」 CJK right corner bracket (UTF-8: 0xE3 0x80 0x8D)
//   U+FF09 ） fullwidth right paren (UTF-8: 0xEF 0xBC 0x89)
// ---------------------------------------------------------------------------

static void strip_trailing_punct(std::string& s) {
    if (s.empty()) return;

    // ASCII punctuation: single byte.
    char last = s.back();
    if (last == '.' || last == ',' || last == '!' || last == '?') {
        s.pop_back();
        return;
    }

    // CJK / fullwidth Unicode punctuation: 3-byte sequences.
    // Check that the string is long enough and that the trailing 3 bytes
    // match one of the known punctuation sequences.
    if (s.size() >= 3) {
        const unsigned char b0 = static_cast<unsigned char>(s[s.size() - 3]);
        const unsigned char b1 = static_cast<unsigned char>(s[s.size() - 2]);
        const unsigned char b2 = static_cast<unsigned char>(s[s.size() - 1]);

        bool is_cjk_punct = false;

        // 0xE3 0x80 block: CJK punctuation (U+3001, U+3002, U+300D, …)
        if (b0 == 0xE3 && b1 == 0x80) {
            // U+3001 、 (0x81), U+3002 。 (0x82), U+300D 」 (0x8D)
            is_cjk_punct = (b2 == 0x81 || b2 == 0x82 || b2 == 0x8D);
        }

        // 0xEF 0xBC block: fullwidth punctuation (U+FF01 ！, U+FF09 ）, …)
        if (b0 == 0xEF && b1 == 0xBC) {
            // U+FF01 ！ (0x81), U+FF09 ） (0x89), U+FF0C ， (0x8C),
            // U+FF0E ． (0x8E), U+FF1F ？ (0x9F)
            is_cjk_punct = (b2 == 0x81 || b2 == 0x89 || b2 == 0x8C ||
                            b2 == 0x8E || b2 == 0x9F);
        }

        if (is_cjk_punct) {
            s.erase(s.size() - 3, 3);
        }
    }
}

// ---------------------------------------------------------------------------
// to_lower — lowercase the string in-place (ASCII only).
// ---------------------------------------------------------------------------

static void to_lower(std::string& s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
}

// ---------------------------------------------------------------------------
// parse_command — see parser.h for full contract.
// ---------------------------------------------------------------------------

ParsedOutput parse_command(const std::string& raw_output) {
    // Build a normalised copy; raw_output is preserved for the no-match return.
    std::string normalised = raw_output;

    trim_whitespace(normalised);
    strip_trailing_punct(normalised);
    trim_whitespace(normalised);
    to_lower(normalised);

    // Exact whole-string lookup.
    auto it = COMMAND_KEYWORDS.find(normalised);
    if (it != COMMAND_KEYWORDS.end()) {
        // Recognised command: text field is empty, command carries the action.
        return ParsedOutput{"", it->second};
    }

    // Not a command: return original raw string as text, command is empty.
    return ParsedOutput{raw_output, ""};
}
