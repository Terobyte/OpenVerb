#pragma once

#include <string>

// ---------------------------------------------------------------------------
// parser.h — Voice command parser interface.
//
// Responsibility: given the raw text produced by the inference backend,
// decide whether it is a structural command or plain dictated text.
//
// Design:
//   • ParsedOutput carries exactly one of {text, command} — the unused field
//     is always an empty string.  This lets callers use a simple branch:
//
//       auto r = parse_command(raw);
//       if (!r.command.empty()) handle_command(r.command);
//       else                    inject_text(r.text);
//
//   • parse_command() receives the *raw* model output (may contain leading /
//     trailing whitespace, trailing punctuation, mixed case).  Normalisation
//     happens inside the function.
//
//   • Only exact whole-string matches against COMMAND_KEYWORDS trigger a
//     command result.  Phrases that merely contain a keyword as a substring
//     ("delete that and more") are returned as plain text unchanged.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// ParsedOutput — result of one parse_command() call.
//
//   text    — the original (un-normalised) raw_output, set when no command
//             was recognised; empty string when a command was matched.
//   command — canonical action name from COMMAND_KEYWORDS, set when a
//             command was matched; empty string otherwise.
//
// Invariant: exactly one of {text, command} is non-empty (or both are empty
// only when raw_output itself is empty after normalisation).
// ---------------------------------------------------------------------------
struct ParsedOutput {
    std::string text;     // original raw_output if not a command
    std::string command;  // canonical action name if recognised
};

// ---------------------------------------------------------------------------
// parse_command — classify one raw model output string.
//
//   raw_output — text exactly as returned by the inference backend.
//
// Algorithm:
//   1. Trim leading and trailing ASCII whitespace.
//   2. Strip a single trailing punctuation character (. , ! ?) if present.
//   3. Convert to lowercase.
//   4. Look up the normalised string in COMMAND_KEYWORDS (exact match only).
//   5a. Match  → return { text="",          command=<action> }
//   5b. No match → return { text=raw_output, command=""       }
//      (raw_output is the *original* input, not the normalised form)
//
// Thread safety: stateless pure function; safe to call concurrently.
// ---------------------------------------------------------------------------
ParsedOutput parse_command(const std::string& raw_output);
