// ---------------------------------------------------------------------------
// prompt_builder.cpp — System prompt construction and context assembly
//
// MVP1: English-only, 6 one-line styles hard-coded inline.
// MVP4+ i18n: system prompts and generation suffixes localised for
//   en/ru/es/fr/de/ja via in-code locale maps; style descriptions
//   remain English-only (deferred to post-v1.0).
// ---------------------------------------------------------------------------

#include "context/prompt_builder.h"

#include "context/templates/en.h"
#include "context/templates/ru.h"
#include "context/templates/es.h"
#include "context/templates/fr.h"
#include "context/templates/de.h"
#include "context/templates/ja.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

// ---------------------------------------------------------------------------
// xml_escape — replace XML-special characters with predefined entity refs.
//
// Applied to every user-supplied field before embedding it in the XML prompt
// so that values containing '<', '>', or '&' cannot corrupt the tag structure.
// ---------------------------------------------------------------------------

static std::string xml_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (unsigned char c : s) {
        switch (c) {
            case '&':  out += "&amp;";  break;
            case '<':  out += "&lt;";   break;
            case '>':  out += "&gt;";   break;
            case '"':  out += "&quot;"; break;
            case '\'': out += "&apos;"; break;
            default:   out += static_cast<char>(c); break;
        }
    }
    return out;
}

#include <nlohmann/json.hpp>

using json = nlohmann::json;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Maximum bytes kept from selected-text field.
static constexpr std::size_t MAX_CONTEXT_BYTES = 10u * 1024u;  // 10 KB

// ---------------------------------------------------------------------------
// select_template — pick system prompt and generation suffix by language code.
//
// Returns non-owning string_views into the static inline strings defined in
// the template headers.  Safe because those strings have static storage
// duration and outlive all callers.
// ---------------------------------------------------------------------------

static std::pair<std::string_view, std::string_view>
select_template(const std::string& lang) {
    using namespace openverb::templates;
    if (lang == "ru") return {SYSTEM_PROMPT_RU, GENERATION_SUFFIX_RU};
    if (lang == "es") return {SYSTEM_PROMPT_ES, GENERATION_SUFFIX_ES};
    if (lang == "fr") return {SYSTEM_PROMPT_FR, GENERATION_SUFFIX_FR};
    if (lang == "de") return {SYSTEM_PROMPT_DE, GENERATION_SUFFIX_DE};
    if (lang == "ja") return {SYSTEM_PROMPT_JA, GENERATION_SUFFIX_JA};
    return {SYSTEM_PROMPT_EN, GENERATION_SUFFIX_EN};  // default / unknown codes
}

// ---------------------------------------------------------------------------
// STYLE_MAP — bundle ID → concise style hint (Stage 1: exact O(1) lookup)
// ---------------------------------------------------------------------------
// MVP4+ i18n: style descriptions remain English-only (deferred to post-v1.0);
//   only system prompts and generation suffixes are localised.

static const std::unordered_map<std::string, std::string> STYLE_MAP = {
    {"com.tinyspeck.slackmacgap", "Casual, concise, emoji OK"},
    {"com.apple.mail",            "Formal, complete sentences"},
    {"com.microsoft.VSCode",      "Code-aware, syntax-correct, comments"},
    {"com.apple.Terminal",        "Commands, no prose"},
    {"com.apple.Notes",           "Raw dictation, preserve everything"},
};

// ---------------------------------------------------------------------------
// FRAGMENT_STYLES — (fragment, style) pairs for Stage 2 fuzzy name matching.
//
// Ordered: first hit wins.  Fragments correspond to the well-known apps above
// so that display names like "Slack" or "Terminal" resolve to the right style.
// ---------------------------------------------------------------------------

static const std::vector<std::pair<std::string, std::string>> FRAGMENT_STYLES = {
    {"slack",    "Casual, concise, emoji OK"},
    {"mail",     "Formal, complete sentences"},
    {"vscode",   "Code-aware, syntax-correct, comments"},
    {"terminal", "Commands, no prose"},
    {"notes",    "Raw dictation, preserve everything"},
};

// ---------------------------------------------------------------------------
// resolve_style
// ---------------------------------------------------------------------------

std::string resolve_style(const std::string& app_name) {
    // Stage 1: exact bundle ID match — O(1)
    auto it = STYLE_MAP.find(app_name);
    if (it != STYLE_MAP.end())
        return it->second;

    // Stage 2: iterate FRAGMENT_STYLES and test if lowercase(app_name)
    // contains a known fragment; first match wins.
    std::string lower = app_name;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    for (const auto& [fragment, style] : FRAGMENT_STYLES) {
        if (lower.find(fragment) != std::string::npos)
            return style;
    }

    // Fallback: neutral prose cleanup
    return "Neutral, clean grammar";
}

// ---------------------------------------------------------------------------
// build_prompt
// ---------------------------------------------------------------------------

std::pair<std::string, std::string> build_prompt(const PromptContext& ctx) {
    const std::string style = resolve_style(ctx.app_name);

    std::string xml;
    xml.reserve(2048);

    const std::string lang = ctx.language.empty() ? "en" : ctx.language;
    auto [sys_prompt, gen_suffix] = select_template(lang);

    // <SystemContext> — expert role + instructions (locale-specific)
    xml += "<SystemContext>\n";
    xml += sys_prompt;
    xml += "\n</SystemContext>\n";

    // <ApplicationContext> — always present; empty fields produce blank values.
    // app_name and window_title are escaped: bundle IDs are safe in practice
    // but window titles can contain arbitrary user text.
    xml += "<ApplicationContext>\n";
    xml += "App: ";    xml += xml_escape(ctx.app_name);    xml += "\n";
    xml += "Window: "; xml += xml_escape(ctx.window_title); xml += "\n";
    xml += "Style: ";  xml += style;                        xml += "\n";
    xml += "</ApplicationContext>\n";

    // <ClipboardContext> — omit tag entirely when clipboard is empty.
    // Marked read-only in the system prompt so the model uses it as a style
    // reference only and does not echo or quote its contents.
    if (!ctx.clipboard.empty()) {
        xml += "<ClipboardContext>\n";
        xml += xml_escape(ctx.clipboard);
        xml += "\n</ClipboardContext>\n";
    }

    // <SelectedText> — omit tag entirely when selected_text is empty.
    if (!ctx.selected_text.empty()) {
        xml += "<SelectedText>\n";
        xml += xml_escape(ctx.selected_text);
        xml += "\n</SelectedText>\n";
    }

    // The generation suffix is returned here so callers and tests can verify it
    // without depending on the inference layer.
    return {xml, std::string(gen_suffix)};
}

// ---------------------------------------------------------------------------
// truncate_utf8 — truncate to at most max_bytes, respecting UTF-8 boundaries.
//
// UTF-8 continuation bytes are 0x80–0xBF (top two bits == 10).  After slicing
// at max_bytes we walk backward over any dangling continuation bytes so we
// never leave a partial multi-byte sequence (e.g. a 3-byte Cyrillic glyph or
// a 4-byte emoji) in the result.
// ---------------------------------------------------------------------------
static std::string truncate_utf8(const std::string& s, std::size_t max_bytes) {
    if (s.size() <= max_bytes) return s;
    std::size_t pos = max_bytes;
    // Walk back over continuation bytes (10xxxxxx) to the nearest start byte.
    while (pos > 0 && (static_cast<unsigned char>(s[pos]) & 0xC0) == 0x80)
        --pos;
    return s.substr(0, pos);
}

// ---------------------------------------------------------------------------
// parse_context_json
// ---------------------------------------------------------------------------

PromptContext parse_context_json(const std::string& json_str) {
    // Contract (header line 70): return a default-empty PromptContext when the
    // string is empty.  An empty string is not valid JSON, so we must guard
    // before calling json::parse() — otherwise nlohmann throws parse_error even
    // for the normal no-`--context` path where config defaults to "".
    if (json_str.empty())
        return PromptContext{};

    // Throws nlohmann::json::parse_error on malformed JSON — propagate as-is.
    const json j = json::parse(json_str);

    PromptContext ctx;

    if (j.contains("app") && j.at("app").is_string())
        ctx.app_name = j.at("app").get<std::string>();

    if (j.contains("window") && j.at("window").is_string())
        ctx.window_title = j.at("window").get<std::string>();

    if (j.contains("clipboard") && j.at("clipboard").is_string()) {
        ctx.clipboard = j.at("clipboard").get<std::string>();
        if (ctx.clipboard.size() > MAX_CONTEXT_BYTES)
            ctx.clipboard = truncate_utf8(ctx.clipboard, MAX_CONTEXT_BYTES);
    }

    if (j.contains("selected") && j.at("selected").is_string()) {
        ctx.selected_text = j.at("selected").get<std::string>();
        if (ctx.selected_text.size() > MAX_CONTEXT_BYTES)
            ctx.selected_text = truncate_utf8(ctx.selected_text, MAX_CONTEXT_BYTES);
    }

    if (j.contains("language") && j.at("language").is_string())
        ctx.language = j.at("language").get<std::string>();

    // Unknown keys are silently ignored (no schema check, no error).
    return ctx;
}
