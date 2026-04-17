#include <gtest/gtest.h>

#include "context/context.h"

#include <string>

using openverb::Context;
using openverb::CONTEXT_SURROUNDING_BYTE_LIMIT;

// ---------------------------------------------------------------------------
// Round-trip: all fields present
// ---------------------------------------------------------------------------

TEST(ContextFromJson, AllFieldsPresent) {
    const std::string json = R"({
        "app": "com.apple.Mail",
        "surrounding_before": "Dear John,\n",
        "surrounding_after": "\n\nRegards"
    })";

    Context ctx = Context::from_json(json);

    EXPECT_EQ(ctx.app_identifier,     "com.apple.Mail");
    EXPECT_EQ(ctx.text_before_cursor, "Dear John,\n");
    EXPECT_EQ(ctx.text_after_cursor,  "\n\nRegards");
}

// ---------------------------------------------------------------------------
// Round-trip: only app present (no surrounding text)
// ---------------------------------------------------------------------------

TEST(ContextFromJson, AppOnlyOmitsSurrounding) {
    const std::string json = R"({"app":"com.apple.Terminal"})";

    Context ctx = Context::from_json(json);

    EXPECT_EQ(ctx.app_identifier,     "com.apple.Terminal");
    EXPECT_TRUE(ctx.text_before_cursor.empty());
    EXPECT_TRUE(ctx.text_after_cursor.empty());
}

// ---------------------------------------------------------------------------
// Empty JSON returns default-constructed Context
// ---------------------------------------------------------------------------

TEST(ContextFromJson, EmptyStringReturnsDefault) {
    Context ctx = Context::from_json("");
    EXPECT_TRUE(ctx.app_identifier.empty());
    EXPECT_TRUE(ctx.text_before_cursor.empty());
    EXPECT_TRUE(ctx.text_after_cursor.empty());
}

TEST(ContextFromJson, EmptyObjectReturnsDefault) {
    Context ctx = Context::from_json("{}");
    EXPECT_TRUE(ctx.app_identifier.empty());
}

// ---------------------------------------------------------------------------
// Unknown keys are silently ignored
// ---------------------------------------------------------------------------

TEST(ContextFromJson, UnknownKeysIgnored) {
    const std::string json = R"({
        "app": "com.apple.Safari",
        "clipboard": "some text",
        "language": "ru",
        "unknown_key": 42
    })";

    Context ctx = Context::from_json(json);
    EXPECT_EQ(ctx.app_identifier, "com.apple.Safari");
    // surrounding fields not present — remain empty
    EXPECT_TRUE(ctx.text_before_cursor.empty());
    EXPECT_TRUE(ctx.text_after_cursor.empty());
}

// ---------------------------------------------------------------------------
// Oversized surrounding text is clamped to CONTEXT_SURROUNDING_BYTE_LIMIT
// ---------------------------------------------------------------------------

TEST(ContextFromJson, OversizedBeforeTextIsClamped) {
    // Build a string larger than CONTEXT_SURROUNDING_BYTE_LIMIT (4096 bytes)
    const std::string big(CONTEXT_SURROUNDING_BYTE_LIMIT + 512, 'x');
    const std::string json = R"({"surrounding_before":")" + big + R"("})";

    Context ctx = Context::from_json(json);

    EXPECT_LE(ctx.text_before_cursor.size(), CONTEXT_SURROUNDING_BYTE_LIMIT)
        << "text_before_cursor must be clamped to CONTEXT_SURROUNDING_BYTE_LIMIT bytes";
}

TEST(ContextFromJson, OversizedAfterTextIsClamped) {
    const std::string big(CONTEXT_SURROUNDING_BYTE_LIMIT + 512, 'y');
    const std::string json = R"({"surrounding_after":")" + big + R"("})";

    Context ctx = Context::from_json(json);

    EXPECT_LE(ctx.text_after_cursor.size(), CONTEXT_SURROUNDING_BYTE_LIMIT)
        << "text_after_cursor must be clamped to CONTEXT_SURROUNDING_BYTE_LIMIT bytes";
}

// ---------------------------------------------------------------------------
// Text at exactly the byte limit passes through unchanged
// ---------------------------------------------------------------------------

TEST(ContextFromJson, ExactLimitPassesThrough) {
    const std::string exact(CONTEXT_SURROUNDING_BYTE_LIMIT, 'z');
    const std::string json = R"({"surrounding_before":")" + exact + R"("})";

    Context ctx = Context::from_json(json);

    EXPECT_EQ(ctx.text_before_cursor.size(), CONTEXT_SURROUNDING_BYTE_LIMIT);
}

// ---------------------------------------------------------------------------
// Malformed JSON throws parse_error
// ---------------------------------------------------------------------------

TEST(ContextFromJson, MalformedJsonThrows) {
    EXPECT_THROW(Context::from_json("{not valid json}"),
                 nlohmann::json::parse_error);
}
