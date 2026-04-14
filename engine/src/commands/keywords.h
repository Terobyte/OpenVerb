#pragma once

#include <string>
#include <unordered_map>

// ---------------------------------------------------------------------------
// keywords.h — Voice command keyword table for MVP3 command parsing.
//
// COMMAND_KEYWORDS maps spoken phrases (as normalised strings) to their
// canonical action names.  Only the four structural commands live here;
// punctuation tokens (`.`, `,`, `!`, `?`) are NOT listed because Gemma
// outputs them directly as tailoring — they need no special handling.
//
// Action name convention: `insert_` prefix for text-injection actions,
// bare verb for edit actions.  This makes intent self-documenting and
// leaves room for a future "insert_*" dispatch path in the text layer.
//
// Lookup is always done through parse_command() in parser.h — callers
// should not access this map directly.
// ---------------------------------------------------------------------------

inline const std::unordered_map<std::string, std::string> COMMAND_KEYWORDS = {
    {"delete that",      "delete_last"},
    {"undo",             "undo"},
    {"new line",         "insert_newline"},
    {"new paragraph",    "insert_newparagraph"},
};
