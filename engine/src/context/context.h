#pragma once

#include <nlohmann/json.hpp>
#include <string>

// ---------------------------------------------------------------------------
// openverb::Context — typed wire-context for one transcription request.
//
// Populated from the JSON object the Swift client sends in session.start:
//   {"app":"<bundle-id>", "surrounding_before":"<text>",
//    "surrounding_after":"<text>", ...}
//
// Fields:
//   app_identifier      — macOS bundle ID (e.g. "com.apple.Mail")
//   text_before_cursor  — text in the focused field before the insertion point
//   text_after_cursor   — text in the focused field after the insertion point
//
// All fields are optional (empty string = not provided).
//
// Surrounding text is clamped to CONTEXT_SURROUNDING_BYTE_LIMIT bytes each
// to prevent oversized context from blowing the model's token budget.
// ---------------------------------------------------------------------------

namespace openverb {

constexpr std::size_t CONTEXT_SURROUNDING_BYTE_LIMIT = 4096;

struct Context {
    std::string app_identifier;
    std::string text_before_cursor;
    std::string text_after_cursor;

    // -----------------------------------------------------------------------
    // from_json — deserialise from the session.start context JSON object.
    //
    // Reads:
    //   "app"                → app_identifier
    //   "surrounding_before" → text_before_cursor  (clamped at byte limit)
    //   "surrounding_after"  → text_after_cursor   (clamped at byte limit)
    //
    // Returns a default-constructed Context if json is empty or "{}".
    // Throws nlohmann::json::parse_error on malformed JSON.
    // -----------------------------------------------------------------------
    static Context from_json(const std::string& json);
};

}  // namespace openverb
