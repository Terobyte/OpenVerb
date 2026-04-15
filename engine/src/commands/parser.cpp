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

// ---------------------------------------------------------------------------
// trim_whitespace — remove leading and trailing ASCII whitespace in-place.
// ---------------------------------------------------------------------------

static void trim_whitespace(std::string& s) {
    // Trim leading
    s.erase(s.begin(),
            std::find_if(s.begin(), s.end(),
                         [](unsigned char c) { return !std::isspace(c); }));
    // Trim trailing
    s.erase(std::find_if(s.rbegin(), s.rend(),
                         [](unsigned char c) { return !std::isspace(c); }).base(),
            s.end());
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
