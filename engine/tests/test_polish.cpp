#include <gtest/gtest.h>

#include "config/defaults.h"
#include "context/context.h"
#include "engine.h"
#include "backend/backend.h"
#include "config/config.h"

#include <atomic>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// MockPolishBackend — simulates the polish inference path.
//
// process() is called by polish_text(); it echoes back the context_json
// (the polish prompt) with a predictable prefix stripped so tests can
// assert that the correct prompt was constructed.
// ---------------------------------------------------------------------------

class MockPolishBackend : public Backend {
public:
    // Tracks the last prompt received so tests can inspect it.
    mutable std::string last_prompt;
    // Configurable output returned by the backend.
    std::string output = "polished output";

    InferenceResult process(
        const std::vector<int16_t>&,
        int,
        const std::string& context_json,
        std::function<void(float)>) override
    {
        last_prompt = context_json;
        return InferenceResult{output, "", 5};
    }

    void unload_model() override {}

    InferenceResult process_stream(
        const std::vector<int16_t>&,
        int,
        const std::string& context_json,
        const std::atomic<bool>&,
        ProgressQueue&) override
    {
        last_prompt = context_json;
        return InferenceResult{output, "", 5};
    }

    std::string name() const override { return "mock_polish"; }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static openverb::Engine make_engine_with_mock(std::shared_ptr<MockPolishBackend>& out_mock) {
    auto mock = std::make_shared<MockPolishBackend>();
    out_mock = mock;
    return openverb::Engine(Config{}, mock);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// The polish prompt must include the raw transcript.
TEST(PolishText, PromptContainsRawTranscript) {
    std::shared_ptr<MockPolishBackend> mock;
    auto engine = make_engine_with_mock(mock);

    openverb::Context ctx;
    ctx.app_identifier = "com.apple.Notes";

    const std::string raw = "эээ привет мир ну как дела";
    const std::string result = engine.polish_text(raw, ctx);

    EXPECT_FALSE(mock->last_prompt.empty())
        << "backend must have been called";
    EXPECT_NE(mock->last_prompt.find(raw), std::string::npos)
        << "polish prompt must contain the raw transcript";
}

// The system prompt string must appear in the constructed prompt.
TEST(PolishText, PromptContainsSystemPrompt) {
    std::shared_ptr<MockPolishBackend> mock;
    auto engine = make_engine_with_mock(mock);

    const std::string raw = "ну тест";
    engine.polish_text(raw, {});

    // POLISH_SYSTEM_PROMPT is a string literal; check a stable substring.
    const std::string expected_fragment = "filler words";
    EXPECT_NE(mock->last_prompt.find(expected_fragment), std::string::npos)
        << "polish prompt must include system instruction mentioning filler words";
}

// When a non-empty surrounding context is provided, it is embedded in the prompt.
TEST(PolishText, ContextFieldsThreadThrough) {
    std::shared_ptr<MockPolishBackend> mock;
    auto engine = make_engine_with_mock(mock);

    openverb::Context ctx;
    ctx.text_before_cursor = "Previous sentence. ";

    engine.polish_text("some text", ctx);

    EXPECT_NE(mock->last_prompt.find("Previous sentence."), std::string::npos)
        << "surrounding before-text must appear in polish prompt when provided";
}

// When before_cursor is empty, no Context: line is added.
TEST(PolishText, EmptyContextNoContextLine) {
    std::shared_ptr<MockPolishBackend> mock;
    auto engine = make_engine_with_mock(mock);

    engine.polish_text("hello", {});

    EXPECT_EQ(mock->last_prompt.find("Context:"), std::string::npos)
        << "Context: line must be omitted when no surrounding text is provided";
}

// Empty raw input returns empty without calling backend.
TEST(PolishText, EmptyRawReturnsEmpty) {
    std::shared_ptr<MockPolishBackend> mock;
    auto engine = make_engine_with_mock(mock);

    const std::string result = engine.polish_text("", {});

    EXPECT_EQ(result, "")
        << "polish_text with empty input must return empty string";
    // Backend should NOT have been called for empty input.
    EXPECT_TRUE(mock->last_prompt.empty())
        << "backend must not be called when raw transcript is empty";
}

// Backend output is returned as the polished result.
TEST(PolishText, BackendOutputIsReturned) {
    std::shared_ptr<MockPolishBackend> mock;
    auto engine = make_engine_with_mock(mock);
    mock->output = "Привет мир.";

    const std::string result = engine.polish_text("эээ привет мир", {});

    EXPECT_EQ(result, "Привет мир.")
        << "polish_text must return the backend output";
}
