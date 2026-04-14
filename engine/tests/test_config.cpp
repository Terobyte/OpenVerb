// ---------------------------------------------------------------------------
// test_config.cpp — Unit tests for CLI argument parsing and config resolution
//
// Coverage:
//   parse_args()      --file, --context, --threads, --vad, --no-vad, unknown
//   resolve_config()  default threads=-1 resolves to a positive auto value;
//                     invalid context JSON causes exit(1)
//   --context schema  all fields optional; unknown keys ignored
//   optreset safety   successive parse_args() calls in one process are isolated
//
// Note: parse_args() resets ::optind (and ::optreset on BSD/macOS) before each
// call so successive invocations within the same process produce isolated results.
// ---------------------------------------------------------------------------

#include <gtest/gtest.h>
#include "config/config.h"
#include "config/defaults.h"

// ===========================================================================
// --file
// ===========================================================================

TEST(ParseArgsFile, SetsFilePath) {
    char prog[] = "test";
    char flag[] = "--file";
    char path[] = "/tmp/audio.wav";
    char* argv[] = {prog, flag, path};
    Config cfg = parse_args(3, argv);
    EXPECT_EQ(cfg.file_path, "/tmp/audio.wav");
}

TEST(ParseArgsFile, DefaultIsEmpty) {
    char prog[] = "test";
    char* argv[] = {prog};
    Config cfg = parse_args(1, argv);
    EXPECT_TRUE(cfg.file_path.empty());
}

// ===========================================================================
// --context: raw string storage
// ===========================================================================

TEST(ParseArgsContext, SetsContextJson) {
    char prog[] = "test";
    char flag[] = "--context";
    char val[]  = R"({"app":"Safari"})";
    char* argv[] = {prog, flag, val};
    Config cfg = parse_args(3, argv);
    EXPECT_EQ(cfg.context_json, R"({"app":"Safari"})");
}

TEST(ParseArgsContext, DefaultContextJsonEmpty) {
    char prog[] = "test";
    char* argv[] = {prog};
    Config cfg = parse_args(1, argv);
    EXPECT_TRUE(cfg.context_json.empty());
}

// ===========================================================================
// --context: JSON schema — all fields optional
//
// Schema: {"app":"<name>", "window":"<title>", "clipboard":"<text>", "selected":"<text>"}
// All four keys are optional; any subset (including empty object) is valid.
//
// Each test calls resolve_config() (with fake model/mmproj paths to bypass
// filesystem I/O) to confirm that valid JSON objects are accepted end-to-end,
// not merely stored as raw strings by parse_args().
// ===========================================================================

// Helper: run parse_args() then resolve_config() without filesystem scanning.
// Returns the resolved Config.  Exits the process (via resolve_config) only if
// context_json violates the schema contract.
static Config run_resolve(int argc, char** argv) {
    Config cfg = parse_args(argc, argv);
    cfg.model_path  = "/fake/model.gguf";
    cfg.mmproj_path = "/fake/mmproj.gguf";
    resolve_config(cfg);
    return cfg;
}

TEST(ResolveConfigContext, AllSchemaFieldsAccepted) {
    char prog[] = "test";
    char flag[] = "--context";
    char val[]  = R"({"app":"Finder","window":"Downloads","clipboard":"hi","selected":"ok"})";
    char* argv[] = {prog, flag, val};
    // resolve_config must not exit for a fully-populated valid object.
    Config cfg = run_resolve(3, argv);
    EXPECT_EQ(cfg.context_json, val);
}

TEST(ResolveConfigContext, SubsetOfFieldsOk) {
    char prog[] = "test";
    char flag[] = "--context";
    char val[]  = R"({"app":"Terminal"})";
    char* argv[] = {prog, flag, val};
    Config cfg = run_resolve(3, argv);
    EXPECT_EQ(cfg.context_json, val);
}

// Each optional field must be accepted when it appears alone (a validator that
// incorrectly rejects any single-field form would fail one of the cases below).

TEST(ResolveConfigContext, OnlyWindowFieldOk) {
    char prog[] = "test";
    char flag[] = "--context";
    char val[]  = R"({"window":"Downloads"})";
    char* argv[] = {prog, flag, val};
    Config cfg = run_resolve(3, argv);
    EXPECT_EQ(cfg.context_json, val);
}

TEST(ResolveConfigContext, OnlyClipboardFieldOk) {
    char prog[] = "test";
    char flag[] = "--context";
    char val[]  = R"({"clipboard":"some text"})";
    char* argv[] = {prog, flag, val};
    Config cfg = run_resolve(3, argv);
    EXPECT_EQ(cfg.context_json, val);
}

TEST(ResolveConfigContext, OnlySelectedFieldOk) {
    char prog[] = "test";
    char flag[] = "--context";
    char val[]  = R"({"selected":"highlighted"})";
    char* argv[] = {prog, flag, val};
    Config cfg = run_resolve(3, argv);
    EXPECT_EQ(cfg.context_json, val);
}

TEST(ResolveConfigContext, EmptyObjectOk) {
    char prog[] = "test";
    char flag[] = "--context";
    char val[]  = "{}";
    char* argv[] = {prog, flag, val};
    Config cfg = run_resolve(3, argv);
    EXPECT_EQ(cfg.context_json, "{}");
}

// ===========================================================================
// --context: JSON schema — unknown keys must be silently ignored (no exit)
// ===========================================================================

TEST(ResolveConfigContext, UnknownKeysIgnored) {
    char prog[] = "test";
    char flag[] = "--context";
    // "unknown_key" is not in the documented schema; must not trigger an error.
    char val[]  = R"({"app":"Code","unknown_key":"value","another":"one"})";
    char* argv[] = {prog, flag, val};
    // resolve_config must not exit for an object with extra keys.
    Config cfg = run_resolve(3, argv);
    EXPECT_EQ(cfg.context_json, val);
}

// ===========================================================================
// --context: JSON schema — non-object JSON must exit with code 1
//
// The schema contract requires a JSON *object*.  Arrays, numbers, strings,
// booleans, and null are all syntactically valid JSON but violate the shape
// contract and must be rejected by resolve_config() with exit(1).
// ===========================================================================

TEST(ResolveConfigContextDeath, ArrayIsRejected) {
    Config cfg;
    cfg.context_json  = "[]";
    cfg.model_path    = "/fake/model.gguf";
    cfg.mmproj_path   = "/fake/mmproj.gguf";
    EXPECT_EXIT(resolve_config(cfg), testing::ExitedWithCode(1),
                "invalid context JSON");
}

TEST(ResolveConfigContextDeath, ScalarNumberIsRejected) {
    Config cfg;
    cfg.context_json  = "42";
    cfg.model_path    = "/fake/model.gguf";
    cfg.mmproj_path   = "/fake/mmproj.gguf";
    EXPECT_EXIT(resolve_config(cfg), testing::ExitedWithCode(1),
                "invalid context JSON");
}

// ===========================================================================
// --context: JSON schema — invalid JSON must exit with code 1
//
// Validation is the responsibility of resolve_config() (not parse_args(),
// which is a pure parsing step).  The test pre-populates model/mmproj paths
// so resolve_config() reaches the JSON check without scanning the filesystem.
// ===========================================================================

TEST(ResolveConfigContextDeath, InvalidJsonExitsOne) {
    Config cfg;
    cfg.context_json  = "{not-valid-json}";
    cfg.model_path    = "/fake/model.gguf";
    cfg.mmproj_path   = "/fake/mmproj.gguf";
    // resolve_config must detect malformed context JSON and call exit(1).
    // Match "invalid context JSON" to confirm the right error path fired.
    EXPECT_EXIT(resolve_config(cfg), testing::ExitedWithCode(1), "invalid context JSON");
}

// ===========================================================================
// --threads
// ===========================================================================

TEST(ParseArgsThreads, DefaultSentinelIsMinusOne) {
    char prog[] = "test";
    char* argv[] = {prog};
    Config cfg = parse_args(1, argv);
    EXPECT_EQ(cfg.threads, DEFAULT_THREADS);  // -1
}

TEST(ParseArgsThreads, ExplicitTwoSetsThreadsTwo) {
    char prog[] = "test";
    char flag[] = "--threads";
    char val[]  = "2";
    char* argv[] = {prog, flag, val};
    Config cfg = parse_args(3, argv);
    EXPECT_EQ(cfg.threads, 2);
}

// Default threads=-1 must be resolved to a positive value by resolve_config().
//
// We pre-populate model_path and mmproj_path with fake (non-empty) strings so
// that resolve_config() skips model-file auto-detection I/O and only resolves
// the thread count — the paths do not need to exist on disk.
TEST(ParseArgsThreads, DefaultResolvesToPositiveAuto) {
    char prog[] = "test";
    char* argv[] = {prog};
    Config cfg = parse_args(1, argv);
    ASSERT_EQ(cfg.threads, DEFAULT_THREADS) << "precondition: threads sentinel before resolve";

    // Bypass model/mmproj scanning; resolve_config only touches them when empty.
    cfg.model_path  = "/fake/model.gguf";
    cfg.mmproj_path = "/fake/mmproj.gguf";
    resolve_config(cfg);

    EXPECT_GT(cfg.threads, 0) << "auto-detection must yield at least 1 thread";
}

// ===========================================================================
// --vad / --no-vad
// ===========================================================================

TEST(ParseArgsVad, FlagEnablesVad) {
    char prog[] = "test";
    char flag[] = "--vad";
    char* argv[] = {prog, flag};
    Config cfg = parse_args(2, argv);
    EXPECT_TRUE(cfg.vad_enabled);
}

TEST(ParseArgsVad, NoVadFlagDisablesVad) {
    char prog[] = "test";
    char flag[] = "--no-vad";
    char* argv[] = {prog, flag};
    Config cfg = parse_args(2, argv);
    EXPECT_FALSE(cfg.vad_enabled);
}

TEST(ParseArgsVad, DefaultMatchesFileModeDefault) {
    char prog[] = "test";
    char* argv[] = {prog};
    Config cfg = parse_args(1, argv);
    // File mode default: VAD off (boundaries are known)
    EXPECT_EQ(cfg.vad_enabled, DEFAULT_VAD_ENABLED_FILE);
    EXPECT_FALSE(cfg.vad_enabled);
}

// ===========================================================================
// Unknown / unrecognised flags — must print usage and exit with code 1
// ===========================================================================

TEST(ParseArgsUnknown, UnknownFlagPrintsUsageAndExitsOne) {
    char prog[] = "test";
    char flag[] = "--this-flag-does-not-exist";
    char* argv[] = {prog, flag};
    int   argc   = 2;
    // getopt_long returns '?' for unrecognised options; parse_args calls
    // print_help(argv[0]) then std::exit(1).
    // Match "Usage:" — the first word print_help() writes to stderr — so the
    // test proves help text was actually printed, not just that exit(1) was called.
    EXPECT_EXIT(parse_args(argc, argv), testing::ExitedWithCode(1), "Usage:");
}

// ===========================================================================
// optreset / successive-call isolation
//
// BSD/macOS getopt_long maintains two pieces of reset state:
//   optind   — which argv[] index to start from (we always set to 1)
//   optnext  — pointer into the current arg for short-option scanning
//
// The documented requirement (BSD man page) is to also set optreset = 1.
// Without it, optnext is only cleared when it is already NULL.  For long-
// only options (empty optstring) optnext IS always NULL after a complete
// parse, so the three tests below currently pass either way.
//
// The tests serve as a regression guard: if a future refactor adds a short
// optstring or changes the parsing loop, stale optnext state would silently
// corrupt results without the optreset fix — and these tests would catch it.
// ===========================================================================

// Adversarial sequence A: parse --vad, then immediately parse --no-vad.
// Without proper reset, stale internal state could cause the second parse
// to inherit the first call's option or skip the flag entirely.
TEST(ParseArgsReset, VadThenNoVadIsIsolated) {
    {
        char prog[] = "test";
        char flag[] = "--vad";
        char* argv[] = {prog, flag};
        Config cfg = parse_args(2, argv);
        EXPECT_TRUE(cfg.vad_enabled) << "first call: --vad must set vad_enabled";
    }
    {
        char prog[] = "test";
        char flag[] = "--no-vad";
        char* argv[] = {prog, flag};
        Config cfg = parse_args(2, argv);
        // If optreset is missing and optnext is stale, getopt may skip the
        // second parse's argv entirely, leaving cfg.vad_enabled at its
        // default (false), which coincidentally matches the expected value
        // here — but for the wrong reason.  The --file tests below catch
        // the case where a different value is expected.
        EXPECT_FALSE(cfg.vad_enabled) << "second call: --no-vad must clear vad_enabled";
    }
}

// Adversarial sequence B: parse --file path1, then parse --file path2.
// If getopt's internal argv pointer is stale, the second call could read
// path1 again instead of path2.
TEST(ParseArgsReset, SuccessiveFileParsesAreIsolated) {
    {
        char prog[] = "test";
        char flag[] = "--file";
        char path[] = "/tmp/audio_first.wav";
        char* argv[] = {prog, flag, path};
        Config cfg = parse_args(3, argv);
        EXPECT_EQ(cfg.file_path, "/tmp/audio_first.wav") << "first call result";
    }
    {
        char prog[] = "test";
        char flag[] = "--file";
        char path[] = "/tmp/audio_second.wav";
        char* argv[] = {prog, flag, path};
        Config cfg = parse_args(3, argv);
        EXPECT_EQ(cfg.file_path, "/tmp/audio_second.wav")
            << "second call must not inherit path from first call (stale optnext)";
    }
    {
        char prog[] = "test";
        char flag[] = "--file";
        char path[] = "/tmp/audio_third.wav";
        char* argv[] = {prog, flag, path};
        Config cfg = parse_args(3, argv);
        EXPECT_EQ(cfg.file_path, "/tmp/audio_third.wav")
            << "third call: internal permutation state must be fully cleared";
    }
}

// Adversarial sequence C: long call followed by short (no-arg) call.
// A stale optind could leave the second parse starting mid-argv.
TEST(ParseArgsReset, LongArgvThenEmptyArgvIsIsolated) {
    {
        char prog[] = "test";
        char f1[]   = "--file";
        char p1[]   = "/tmp/a.wav";
        char f2[]   = "--threads";
        char p2[]   = "3";
        char f3[]   = "--vad";
        char* argv[] = {prog, f1, p1, f2, p2, f3};
        Config cfg = parse_args(6, argv);
        EXPECT_EQ(cfg.file_path, "/tmp/a.wav");
        EXPECT_EQ(cfg.threads,   3);
        EXPECT_TRUE(cfg.vad_enabled);
    }
    {
        // No options: a stale optind > 1 would skip argv[1..] in the new call.
        char prog[] = "test";
        char* argv[] = {prog};
        Config cfg = parse_args(1, argv);
        EXPECT_TRUE(cfg.file_path.empty())
            << "after long parse, no-arg call must see empty file_path";
        EXPECT_EQ(cfg.threads, -1)
            << "after long parse, no-arg call must see default threads=-1";
        EXPECT_FALSE(cfg.vad_enabled)
            << "after long parse, no-arg call must see default vad=false";
    }
}
