// OpenVerb Engine — llama.cpp / mtmd inference wrapper
//
// Wraps the llama.cpp C API and the mtmd multimodal library to provide
// audio-aware inference for Gemma 4 (E2B) models.
//
// API surface verified against the llama.cpp commit pinned in
// third_party/llama.cpp (tag: see CMakeLists LLAMA_TAG variable).
// Key functions used:
//   llama_model_load_from_file()   — model weights
//   llama_init_from_model()        — KV-cache context
//   mtmd_init_from_file()          — multimodal projector
//   mtmd_bitmap_init_from_audio()  — F32 PCM → mtmd_bitmap
//   mtmd_tokenize()                — prompt + audio → chunk list
//   mtmd_helper_eval_chunks()      — encode + decode prompt chunks
//   llama_sampler_chain_init/add/sample/accept — greedy decoding
//   llama_batch_init / llama_decode — single-token decode step

#include "llama_context.h"
#include "config/interrupts.h"
#include "config/log.h"

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#ifdef __APPLE__
#  include <sys/sysctl.h>
#endif
#include <sys/stat.h>

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

namespace {

// Return the file's byte size, or 0 on error.
static uint64_t file_size_bytes(const std::string& path) {
    struct stat st;
    if (::stat(path.c_str(), &st) == 0) {
        return static_cast<uint64_t>(st.st_size);
    }
    return 0;
}

// Estimate available Metal VRAM (bytes).
// On Apple Silicon, GPU and CPU share unified memory.
// MTLDevice.recommendedMaxWorkingSetSize ≈ 75 % of total RAM.
// We approximate via sysctl rather than bridging to Objective-C.
static uint64_t metal_available_bytes() {
#ifdef __APPLE__
    uint64_t mem = 0;
    size_t   len = sizeof(mem);
    if (::sysctlbyname("hw.memsize", &mem, &len, nullptr, 0) == 0) {
        return static_cast<uint64_t>(static_cast<double>(mem) * 0.75);
    }
#endif
    return 0;
}

// Check estimated VRAM and warn if tight.
//   ctx_size_tokens — KV-cache token capacity
// Gemma 4 4B rough geometry: n_layers=27, head_dim=256, n_kv_heads=16
//   → kv_per_token ≈ 2 * 27 * 16 * 256 * sizeof(float16) ≈ 221 KB / token
static void maybe_warn_vram(const std::string& model_path,
                             const std::string& mmproj_path,
                             int                ctx_size_tokens) {
    const uint64_t available = metal_available_bytes();
    if (available == 0) return;  // unknown — skip check

    const uint64_t model_sz  = file_size_bytes(model_path);
    const uint64_t mmproj_sz = file_size_bytes(mmproj_path);

    // KV cache estimate: ctx_size * 2 * n_layers * d_kv * sizeof(float16)
    // Using Gemma 4 4B approximation: n_layers=27, d_kv=4096 bytes per layer
    constexpr uint64_t KV_BYTES_PER_TOKEN_PER_LAYER = 4096;  // ~4 KB
    constexpr int      N_LAYERS_ESTIMATE             = 27;
    const uint64_t kv_cache_est = static_cast<uint64_t>(ctx_size_tokens)
                                 * 2
                                 * N_LAYERS_ESTIMATE
                                 * KV_BYTES_PER_TOKEN_PER_LAYER;

    const uint64_t estimated_usage = model_sz + mmproj_sz + kv_cache_est;

    if (estimated_usage > available) {
        const uint64_t est_mb  = estimated_usage >> 20;
        const uint64_t avail_mb = available       >> 20;
        fprintf(stderr,
                "warning: estimated VRAM usage (%llu MB) exceeds available "
                "(%llu MB), inference may be slow\n",
                (unsigned long long)est_mb,
                (unsigned long long)avail_mb);
    }
}

// Strip the Gemma 4 thinking block from model output.
//
// Gemma 4 (thinking mode) may prefix responses with a thinking block.
// When /no_think is prepended to the user turn (default), the model should
// skip thinking entirely.  This function acts as a safety net.
//
// Three known output formats (different GGUF builds / runtimes):
//   1. [Start thinking] ... [End thinking]
//   2. <start_of_think> ... <end_of_think>
//   3. <|channel>thought...<channel|>RESPONSE  (observed in MVP0 validation
//      via llama-mtmd-cli — DECISION.md line 27; split on <channel|>, take right)
static std::string strip_thinking_block(const std::string& text) {
    // Formats 1 + 2: paired start/end markers
    static const char* STARTS[] = {"[Start thinking]", "<start_of_think>", nullptr};
    static const char* ENDS[]   = {"[End thinking]",   "<end_of_think>",   nullptr};

    for (int i = 0; STARTS[i] != nullptr; ++i) {
        auto start_pos = text.find(STARTS[i]);
        if (start_pos == std::string::npos) continue;

        auto end_pos = text.find(ENDS[i], start_pos + std::strlen(STARTS[i]));
        if (end_pos == std::string::npos) {
            // Partial thinking block — strip from start marker to end of string
            return text.substr(0, start_pos);
        }

        // Remove everything from [Start thinking] through [End thinking]
        std::string after = text.substr(end_pos + strlen(ENDS[i]));
        // Trim leading whitespace/newlines after the thinking block
        auto first = after.find_first_not_of(" \t\r\n");
        return (first == std::string::npos) ? "" : after.substr(first);
    }

    // Format 3: <|channel>...<channel|>RESPONSE — split on end marker, take right
    static const char* CHANNEL_END = "<channel|>";
    auto ch_pos = text.find(CHANNEL_END);
    if (ch_pos != std::string::npos) {
        std::string after = text.substr(ch_pos + std::strlen(CHANNEL_END));
        auto first = after.find_first_not_of(" \t\r\n");
        return (first == std::string::npos) ? "" : after.substr(first);
    }

    return text;  // no thinking block found
}

// Strip Gemma 4 chat turn-control tokens from model output.
//
// In some GGUF builds the turn delimiters are not registered as EOG tokens
// so they pass through llama_token_to_piece() as plain text.  Any occurrence
// of these strings in the generated output is spurious and must be removed.
// We strip them wherever they appear (prefix, suffix, inline) and then
// re-trim leading/trailing whitespace.
static std::string strip_gemma_control_tokens(const std::string& text) {
    // List combined role patterns before the bare marker so that the role text
    // ("model\n" / "user\n") is consumed together with its angle-bracket
    // marker in a single erasure.  The bare "<start_of_turn>" entry below
    // catches any residual occurrence where the role name is absent or differs.
    static const char* CTRL[] = {
        "<start_of_turn>model\n", "<start_of_turn>user\n",
        "<start_of_turn>model",   "<start_of_turn>user",
        "<start_of_turn>",        "</start_of_turn>",
        "<end_of_turn>",          "</end_of_turn>",
        nullptr
    };

    std::string result = text;
    bool changed = true;
    while (changed) {
        changed = false;
        for (int i = 0; CTRL[i] != nullptr; ++i) {
            std::string::size_type pos;
            while ((pos = result.find(CTRL[i])) != std::string::npos) {
                result.erase(pos, std::strlen(CTRL[i]));
                changed = true;
            }
        }
    }

    // Re-trim leading/trailing whitespace introduced by the removals
    auto first = result.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return "";
    auto last = result.find_last_not_of(" \t\r\n");
    return result.substr(first, last - first + 1);
}

// Build a Gemma 4 single-turn user prompt string.
//
// Gemma 4 chat format (manual — llama_chat_apply_template does NOT parse
// Jinja, so we format manually):
//
//   <start_of_turn>user
//   /no_think
//   {text_prompt}
//   <__media__>
//   {generation_suffix}<end_of_turn>
//   <start_of_turn>model
//
// The <__media__> placeholder is replaced by audio tokens by mtmd_tokenize.
// /no_think suppresses Gemma 4's thinking mode (preferred over post-processing).
static std::string build_gemma4_prompt(const std::string& text_prompt,
                                        const std::string& generation_suffix) {
    std::string prompt;
    prompt.reserve(text_prompt.size() + generation_suffix.size() + 128);
    prompt += "<start_of_turn>user\n";
    prompt += "/no_think\n";
    if (!text_prompt.empty()) {
        prompt += text_prompt;
        prompt += "\n";
    }
    prompt += mtmd_default_marker();  // "<__media__>" placeholder
    prompt += "\n";
    if (!generation_suffix.empty()) {
        prompt += generation_suffix;
    }
    prompt += "<end_of_turn>\n";
    prompt += "<start_of_turn>model\n";
    return prompt;
}

}  // namespace

// ---------------------------------------------------------------------------
// PIMPL implementation struct
// ---------------------------------------------------------------------------

struct LlamaContext::Impl {
    llama_model   * model   = nullptr;
    llama_context * lctx    = nullptr;
    mtmd_context  * mctx    = nullptr;
    llama_sampler * sampler = nullptr;

    int threads   = 4;
    int ctx_size  = 4096;

    // -------------------------------------------------------------------------
    // Constructor: load model + context + mmproj; set up greedy sampler.
    // -------------------------------------------------------------------------
    Impl(const std::string& model_path,
         const std::string& mmproj_path,
         int                threads_,
         int                ctx_size_)
        : threads(threads_), ctx_size(ctx_size_)
    {
        // Warn before allocating if VRAM looks tight
        maybe_warn_vram(model_path, mmproj_path, ctx_size);

        // --- Load text model ---
        llama_model_params mparams = llama_model_default_params();
        mparams.n_gpu_layers       = 999;  // offload all layers to Metal

        model = llama_model_load_from_file(model_path.c_str(), mparams);
        if (!model) {
            throw std::runtime_error(
                "LlamaContext: failed to load model from " + model_path);
        }

        // --- Create inference context ---
        llama_context_params cparams = llama_context_default_params();
        cparams.n_ctx            = static_cast<uint32_t>(ctx_size);
        cparams.n_batch          = 512;
        cparams.n_threads        = threads;
        cparams.n_threads_batch  = threads;
        cparams.flash_attn_type  = LLAMA_FLASH_ATTN_TYPE_ENABLED;  // Metal supports flash attention

        // Interrupt check: SIGINT between model load and context creation
        if (g_interrupted.load(std::memory_order_relaxed)) {
            llama_model_free(model);
            throw std::runtime_error("LlamaContext: load cancelled by SIGINT");
        }

        lctx = llama_init_from_model(model, cparams);
        if (!lctx) {
            llama_model_free(model);
            throw std::runtime_error(
                "LlamaContext: failed to create inference context "
                "(OOM or ctx_size too large?)");
        }

        // --- Load multimodal projector ---
        mtmd_context_params mmp = mtmd_context_params_default();
        mmp.use_gpu       = true;
        mmp.n_threads     = threads;
        mmp.print_timings = false;
        mmp.warmup        = false;

        mctx = mtmd_init_from_file(mmproj_path.c_str(), model, mmp);
        if (!mctx) {
            llama_free(lctx);
            llama_model_free(model);
            throw std::runtime_error(
                "LlamaContext: failed to load mmproj from " + mmproj_path +
                " — verify the file is a valid multimodal projector");
        }

        // --- Greedy sampler (deterministic; ideal for transcription) ---
        llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
        sampler = llama_sampler_chain_init(sparams);
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    }

    ~Impl() {
        if (sampler) llama_sampler_free(sampler);
        if (mctx)   mtmd_free(mctx);
        if (lctx)   llama_free(lctx);
        if (model)  llama_model_free(model);
    }

    // Non-copyable
    Impl(const Impl&)            = delete;
    Impl& operator=(const Impl&) = delete;
};

// ---------------------------------------------------------------------------
// LlamaContext public API
// ---------------------------------------------------------------------------

LlamaContext::LlamaContext(const std::string& model_path,
                           const std::string& mmproj_path,
                           int                threads,
                           int                ctx_size)
    : impl_(std::make_unique<Impl>(model_path, mmproj_path, threads, ctx_size))
{}

LlamaContext::~LlamaContext() = default;

bool LlamaContext::has_audio_support() const {
    return impl_->mctx && mtmd_support_audio(impl_->mctx);
}

std::string LlamaContext::model_name() const {
    char buf[256];
    llama_model_desc(impl_->model, buf, sizeof(buf));
    return std::string(buf);
}

std::string LlamaContext::infer(const std::string&         text_prompt,
                                const std::vector<int16_t>& audio_pcm,
                                int                         sample_rate,
                                const std::string&          generation_suffix,
                                ProgressCallback            progress) {
    // Engine always resamples to 16 kHz before calling infer().
    // Assert here so any future caller that skips resampling gets a clear error.
    if (sample_rate != 16000)
        throw std::invalid_argument(
            "infer() requires 16 kHz PCM — resample first (got " +
            std::to_string(sample_rate) + " Hz)");

    // -----------------------------------------------------------------------
    // Step 1: Build Gemma 4 chat prompt with <__media__> marker
    // -----------------------------------------------------------------------
    const std::string full_prompt =
        build_gemma4_prompt(text_prompt, generation_suffix);

    // -----------------------------------------------------------------------
    // Step 2: Convert int16 PCM → float32 normalised [-1.0, 1.0]
    // -----------------------------------------------------------------------
    std::vector<float> audio_f32;
    audio_f32.reserve(audio_pcm.size());
    constexpr float INV_INT16_MAX = 1.0f / 32768.0f;
    for (const int16_t s : audio_pcm) {
        audio_f32.push_back(static_cast<float>(s) * INV_INT16_MAX);
    }

    // -----------------------------------------------------------------------
    // Step 3: Wrap audio as mtmd_bitmap (F32 PCM format)
    // -----------------------------------------------------------------------
    // mtmd_bitmap_init_from_audio expects (n_samples, float* data)
    mtmd_bitmap* audio_bmp =
        mtmd_bitmap_init_from_audio(audio_f32.size(), audio_f32.data());
    if (!audio_bmp) {
        throw std::runtime_error(
            "LlamaContext::infer: failed to create audio bitmap");
    }
    // Wrap in RAII guard
    struct BitmapGuard {
        mtmd_bitmap* p;
        ~BitmapGuard() { if (p) mtmd_bitmap_free(p); }
    } bmp_guard{audio_bmp};

    // -----------------------------------------------------------------------
    // Step 4-5: mtmd_tokenize — replaces <__media__> with audio chunk tokens,
    // producing text/audio/text chunk list.
    // -----------------------------------------------------------------------
    mtmd_input_text input_text{};
    input_text.text          = full_prompt.c_str();
    input_text.add_special   = true;   // add BOS token
    input_text.parse_special = true;   // recognise <start_of_turn> etc.

    const mtmd_bitmap* bitmaps[] = {audio_bmp};

    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    if (!chunks) {
        throw std::runtime_error(
            "LlamaContext::infer: failed to allocate input chunks");
    }
    struct ChunksGuard {
        mtmd_input_chunks* p;
        ~ChunksGuard() { if (p) mtmd_input_chunks_free(p); }
    } chunks_guard{chunks};

    int32_t tok_rc = mtmd_tokenize(impl_->mctx, chunks,
                                   &input_text, bitmaps, 1);
    if (tok_rc != 0) {
        throw std::runtime_error(
            "LlamaContext::infer: mtmd_tokenize failed (rc=" +
            std::to_string(tok_rc) + "). "
            "Ensure the prompt contains exactly one <__media__> marker.");
    }

    // -----------------------------------------------------------------------
    // Step 5: Process all chunks (encode audio + decode text into KV cache)
    // -----------------------------------------------------------------------
    // KV-cache must be cleared between calls
    llama_memory_clear(llama_get_memory(impl_->lctx), false);

    llama_pos n_past     = 0;
    int32_t   eval_rc    = mtmd_helper_eval_chunks(
        impl_->mctx,
        impl_->lctx,
        chunks,
        /*n_past=*/   n_past,
        /*seq_id=*/   0,
        /*n_batch=*/  512,
        /*logits_last=*/ true,
        &n_past
    );
    if (eval_rc != 0) {
        throw std::runtime_error(
            "LlamaContext::infer: prompt evaluation failed (rc=" +
            std::to_string(eval_rc) + ")");
    }

    // -----------------------------------------------------------------------
    // Step 6: Autoregressive generation loop
    // -----------------------------------------------------------------------
    constexpr int MAX_NEW_TOKENS = 2048;

    // Pre-allocate a single-token batch for the decode loop
    llama_batch batch = llama_batch_init(1, 0, 1);
    struct BatchGuard {
        llama_batch& b;
        ~BatchGuard() { llama_batch_free(b); }
    } batch_guard{batch};

    const llama_vocab* vocab = llama_model_get_vocab(impl_->model);

    std::string output;
    output.reserve(512);

    // Progress timing
    auto last_progress_tp = std::chrono::steady_clock::now();
    if (progress) progress(0.0f);

    for (int i = 0; i < MAX_NEW_TOKENS; ++i) {
        // --- Check for interrupt ---
        if (g_interrupted.load(std::memory_order_relaxed)) {
            break;
        }

        // --- Sample next token (greedy) ---
        const llama_token token_id =
            llama_sampler_sample(impl_->sampler, impl_->lctx, -1);
        llama_sampler_accept(impl_->sampler, token_id);

        // --- Check end-of-generation ---
        if (llama_vocab_is_eog(vocab, token_id)) {
            break;
        }

        // --- Decode token to text piece ---
        char   piece_buf[64];
        int32_t piece_len = llama_token_to_piece(
            vocab,
            token_id,
            piece_buf, sizeof(piece_buf) - 1,
            /*lstrip=*/  0,
            /*special=*/ false);
        if (piece_len > 0) {
            piece_buf[piece_len] = '\0';
            output.append(piece_buf, piece_len);
        }

        // --- Progress callback every ~500 ms ---
        auto now = std::chrono::steady_clock::now();
        auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            now - last_progress_tp).count();
        if (progress && elapsed_ms >= 500) {
            // Rough estimate: use token fraction of expected output length
            const float est = std::min(1.0f,
                static_cast<float>(i + 1) / static_cast<float>(MAX_NEW_TOKENS));
            progress(est);
            last_progress_tp = now;
        }

        // --- Decode for next iteration: single-token batch ---
        batch.n_tokens       = 1;
        batch.token[0]       = token_id;
        batch.pos[0]         = n_past++;
        batch.n_seq_id[0]    = 1;
        batch.seq_id[0][0]   = 0;
        batch.logits[0]      = 1;  // request logits for next sample

        int32_t decode_rc = llama_decode(impl_->lctx, batch);
        if (decode_rc != 0) {
            throw std::runtime_error(
                "LlamaContext::infer: llama_decode failed at token " +
                std::to_string(i) + " (rc=" + std::to_string(decode_rc) + ")");
        }
    }

    if (progress) progress(1.0f);

    // -----------------------------------------------------------------------
    // Step 7: Clean up raw model output
    //   a) Strip thinking block (safety net; /no_think is primary)
    //   b) Strip Gemma turn-control tokens that leak in some GGUF builds
    // -----------------------------------------------------------------------
    std::string cleaned = strip_thinking_block(output);
    return strip_gemma_control_tokens(cleaned);
}
