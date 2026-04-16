#pragma once

#include <nlohmann/json.hpp>

#include <string>
#include <utility>

// ---------------------------------------------------------------------------
// PromptContext — caller-supplied desktop context for one transcription request.
//
// All fields are optional (empty string = not provided).  Use parse_context_json()
// to populate from the JSON wire format, or construct directly in tests.
//
// Wire format (--context flag):
//   {"app":"<bundle-id>","window":"<title>","selected":"<text>"}
// ---------------------------------------------------------------------------

struct PromptContext {
    std::string app_name;      // macOS bundle ID of the frontmost app (e.g. "com.apple.Mail")
    std::string window_title;  // frontmost window title
    std::string selected_text; // text currently selected in the active app
};

// ---------------------------------------------------------------------------
// build_prompt — construct the two-part prompt from a PromptContext.
//
// Returns a pair {system_xml, generation_suffix} where:
//   system_xml         — XML-wrapped system instruction encoding the context;
//                        empty fields are omitted from the XML output.
//   generation_suffix  — fixed suffix appended by LlamaContext after audio tokens:
//                        "Output ONLY the final text:"
//
// The generation_suffix is returned here (rather than hard-coded in LlamaContext)
// so callers and tests can inspect it without depending on the inference layer.
// ---------------------------------------------------------------------------
std::pair<std::string, std::string> build_prompt(const PromptContext& ctx);

// ---------------------------------------------------------------------------
// resolve_style — map a macOS bundle ID to a concise style hint string.
//
// The style hint is embedded in the system_xml produced by build_prompt() and
// guides the model towards app-appropriate output formatting (e.g. terse
// terminal commands vs. composed email prose).
//
// Lookup is O(1) via a static unordered_map initialised on first call.
// Unknown bundle IDs return "general".
//
// Example mappings:
//   "com.apple.Terminal"           → "terminal"
//   "com.apple.Mail"               → "email"
//   "com.tinyspeck.slackmacgap"    → "chat"
//   "com.microsoft.VSCode"         → "code"
//   "com.apple.Notes"              → "notes"
//   "com.google.Chrome"            → "web"
// ---------------------------------------------------------------------------
std::string resolve_style(const std::string& app_name);

// ---------------------------------------------------------------------------
// parse_context_json — deserialise the --context JSON blob into a PromptContext.
//
// Expected schema (all keys optional; unknown keys are silently ignored):
//   {
//     "app":       "<bundle-id>",
//     "window":    "<window-title>",
//     "selected":  "<selected-text>"
//   }
//
// Returns a default-constructed PromptContext if json is empty or "{}".
// Throws nlohmann::json::parse_error on malformed JSON.
// ---------------------------------------------------------------------------
PromptContext parse_context_json(const std::string& json);
