// ---------------------------------------------------------------------------
// context.cpp — openverb::Context JSON deserializer
// ---------------------------------------------------------------------------

#include "context/context.h"

#include <string>

namespace openverb {

// ---------------------------------------------------------------------------
// clamp_to_utf8_bytes — truncate s to at most max_bytes UTF-8 bytes without
// splitting a multi-byte sequence.
//
// Works by scanning from the front and stopping as soon as adding the next
// byte would exceed the limit.  Since we scan byte-by-byte and UTF-8
// continuation bytes start with 0b10xxxxxx (0x80–0xBF), stopping at any
// byte boundary is safe for well-formed input.
// ---------------------------------------------------------------------------
static std::string clamp_to_utf8_bytes(const std::string& s, std::size_t max_bytes) {
    if (s.size() <= max_bytes) return s;
    // Walk backwards from max_bytes to find the last complete character start.
    std::size_t end = max_bytes;
    while (end > 0 && (static_cast<unsigned char>(s[end]) & 0xC0) == 0x80) {
        --end;  // skip continuation bytes
    }
    return s.substr(0, end);
}

Context Context::from_json(const std::string& json) {
    if (json.empty() || json == "{}") {
        return {};
    }

    const auto j = nlohmann::json::parse(json);  // throws on invalid JSON

    Context ctx;

    if (j.contains("app") && j["app"].is_string()) {
        ctx.app_identifier = j["app"].get<std::string>();
    }

    if (j.contains("surrounding_before") && j["surrounding_before"].is_string()) {
        ctx.text_before_cursor = clamp_to_utf8_bytes(
            j["surrounding_before"].get<std::string>(),
            CONTEXT_SURROUNDING_BYTE_LIMIT);
    }

    if (j.contains("surrounding_after") && j["surrounding_after"].is_string()) {
        ctx.text_after_cursor = clamp_to_utf8_bytes(
            j["surrounding_after"].get<std::string>(),
            CONTEXT_SURROUNDING_BYTE_LIMIT);
    }

    return ctx;
}

}  // namespace openverb
