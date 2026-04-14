// ---------------------------------------------------------------------------
// test_command_parser.cpp — Unit tests for voice command parsing
//
// Coverage:
//   parse_command()  exact commands, case-insensitive matching, whitespace
//                    trimming, trailing punctuation stripping, partial-match
//                    rejection, empty input, and literal-text "period"/"comma"
//                    handling.
//
// ParsedOutput invariant:
//   • Command recognised  → result.text is empty, result.command is the
//     canonical action name.
//   • Not a command       → result.text is the original raw_output (verbatim),
//     result.command is empty.
//   • Empty input         → both text and command are empty strings.
// ---------------------------------------------------------------------------

#include <gtest/gtest.h>
#include "commands/parser.h"

// ===========================================================================
// Test helpers
// ===========================================================================

// Assert that raw maps to a recognised command action.
static void expect_command(const std::string& raw,
                            const std::string& expected_action) {
    ParsedOutput r = parse_command(raw);
    EXPECT_EQ(r.command, expected_action)
        << "expected command \"" << expected_action << "\" for input: \"" << raw << "\"";
    EXPECT_TRUE(r.text.empty())
        << "text field must be empty for a recognised command; input: \"" << raw << "\"";
}

// Assert that raw is returned verbatim as plain text (not a command).
static void expect_text(const std::string& raw) {
    ParsedOutput r = parse_command(raw);
    EXPECT_EQ(r.text, raw)
        << "text must equal original raw_output; input: \"" << raw << "\"";
    EXPECT_TRUE(r.command.empty())
        << "command must be empty for non-command input: \"" << raw << "\"";
}

// ===========================================================================
// delete that → delete_last
// ===========================================================================

TEST(CommandParser, DeleteThatLowercase) {
    // Exact lowercase match against the keyword table.
    expect_command("delete that", "delete_last");
}

TEST(CommandParser, DeleteThatMixedCase) {
    // Case-insensitive: "Delete That" must normalise to "delete that".
    expect_command("Delete That", "delete_last");
}

TEST(CommandParser, DeleteThatTrailingPeriod) {
    // Trailing '.' must be stripped before lookup.
    expect_command("delete that.", "delete_last");
}

// ===========================================================================
// undo → undo
// ===========================================================================

TEST(CommandParser, UndoExact) {
    expect_command("undo", "undo");
}

TEST(CommandParser, UndoLeadingAndTrailingSpaces) {
    // Leading and trailing whitespace must be trimmed before lookup.
    expect_command("  undo  ", "undo");
}

TEST(CommandParser, UndoTrailingComma) {
    // Trailing ',' must be stripped before lookup.
    expect_command("undo,", "undo");
}

// ===========================================================================
// new line → insert_newline
// ===========================================================================

TEST(CommandParser, NewLine) {
    expect_command("new line", "insert_newline");
}

// ===========================================================================
// new paragraph → insert_newparagraph
// ===========================================================================

TEST(CommandParser, NewParagraph) {
    expect_command("new paragraph", "insert_newparagraph");
}

// ===========================================================================
// Plain text — not a command
// ===========================================================================

TEST(CommandParser, HelloWorldIsText) {
    // Ordinary dictation: "Hello world" has no keyword match.
    expect_text("Hello world");
}

TEST(CommandParser, PartialMatchIsNotACommand) {
    // "delete that and more" *contains* the keyword "delete that" as a prefix
    // but must NOT match — only exact whole-string matches count.
    expect_text("delete that and more");
}

// ===========================================================================
// Empty input
// ===========================================================================

TEST(CommandParser, EmptyInputReturnsBothEmpty) {
    // An empty string after normalisation produces ParsedOutput{"",""}.
    ParsedOutput r = parse_command("");
    EXPECT_TRUE(r.text.empty())
        << "text must be empty for empty input";
    EXPECT_TRUE(r.command.empty())
        << "command must be empty for empty input";
}

// ===========================================================================
// Literal punctuation tokens — "period" and "comma" are NOT commands
//
// Rationale: Gemma outputs the literal characters '.' and ',' as inline
// punctuation markers.  The spoken words "period" and "comma" are ordinary
// dictation tokens (the speaker is narrating punctuation, not issuing a
// structural command) and must therefore be treated as plain text.
// ===========================================================================

TEST(CommandParser, PeriodWordIsText) {
    expect_text("period");
}

TEST(CommandParser, CommaWordIsText) {
    expect_text("comma");
}
