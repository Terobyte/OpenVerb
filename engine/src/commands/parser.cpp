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
// strip_trailing_punct — remove exactly one trailing punctuation char if
// it is one of: . , ! ?
// ---------------------------------------------------------------------------

static void strip_trailing_punct(std::string& s) {
    if (s.empty()) return;
    char last = s.back();
    if (last == '.' || last == ',' || last == '!' || last == '?')
        s.pop_back();
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
