#pragma once

// ---------------------------------------------------------------------------
// Audio / protocol constants (no prefix — physical facts about the wire format)
// ---------------------------------------------------------------------------

/// PCM sample rate expected by the model (Hz)
#define SAMPLE_RATE          16000

/// PCM bit depth
#define SAMPLE_BITS          16

/// Number of audio channels (mono)
#define CHANNELS             1

/// Silence duration that triggers end-of-utterance in VAD (milliseconds)
#define VAD_SILENCE_MS       500

/// RMS energy silence gate threshold (int16 amplitude scale, 0–32767).
/// Audio whose RMS is below this value is classified as silence and returned
/// as an empty InferenceResult without running inference.
///
/// Initial estimate: 50 (≈ 0.15% of full scale).  This value is UNVALIDATED
/// and must be calibrated against validation/audio/silence.wav and quiet
/// speech samples during integration testing.
///   • Raise if inference is triggered on near-silent recordings.
///   • Lower if quiet speech is incorrectly suppressed.
#define SILENCE_RMS_THRESHOLD  50.0

// ---------------------------------------------------------------------------
// IPC / daemon constants
// ---------------------------------------------------------------------------

#define CHUNK_BYTES               4096
#define DEFAULT_SOCKET_PATH       "~/.openverb/engine.sock"
#define DEFAULT_PID_PATH          "~/.openverb/engine.pid"
#define DEFAULT_IDLE_TIMEOUT_SECS 0
#define DEFAULT_SESSION_TIMEOUT_SECS 15
#define DEFAULT_STREAM_STALL_SECS 30
#define DEFAULT_INFERENCE_TIMEOUT_SECS 30
#define DEFAULT_MAX_JSON_SIZE     65536
#define RING_BUFFER_SIZE          16777216
#define AUDIO_TOKENS_PER_SEC      25
#define SYSTEM_PROMPT_TOKENS_RESERVED 500
#define DEFAULT_CTX_SIZE          4096

// ---------------------------------------------------------------------------
// Streaming chunked inference constants
// ---------------------------------------------------------------------------

#define MIN_CHUNK_MS              3000
#define MAX_CHUNK_MS              20000
#define SILENCE_BOUNDARY_MS       600
#define CHUNK_QUEUE_MAX_DEPTH     8
#define QUEUE_STATUS_HEARTBEAT_MS 500
#define DEFAULT_CHUNK_INFER_SPEED 0.5
#define INFER_SPEED_EWMA_ALPHA    0.3

// ---------------------------------------------------------------------------
// Polish LLM cleanup pass constants
// ---------------------------------------------------------------------------

/// Token budget reserved for the surrounding-context in the polish prompt.
#define POLISH_CONTEXT_TOKENS     256

/// Maximum tokens the polish pass may generate (cleaned transcript output).
#define POLISH_MAX_TOKENS         512

/// System prompt used by the polish pass (Gemma Eloquent cleanup style).
#define POLISH_SYSTEM_PROMPT      \
    "You are a precise transcript editor. Remove filler words (\"эээ\", \"ну\", "  \
    "\"like\", \"um\", \"uh\"), fix mid-sentence restarts by keeping the last "    \
    "clean attempt, and add terminal punctuation. Output ONLY the cleaned text."

/// Instruction prefix injected before the raw transcript in the polish prompt.
#define POLISH_INSTRUCTION_PREFIX "Clean this transcript: "

// ---------------------------------------------------------------------------
// User-facing defaults (DEFAULT_ prefix — can vary per workflow / user pref)
// ---------------------------------------------------------------------------

/// Thread count sentinel: resolve_config() computes max(1, min(4, cores-2))
#define DEFAULT_THREADS          -1

/// Inference backend identifier
#define DEFAULT_BACKEND          "gemma_audio"

/// Directory scanned when --model is not provided
#define DEFAULT_MODEL_DIR        "~/.openverb/models/"

/// Glob matched against DEFAULT_MODEL_DIR to find an audio-capable Gemma model.
/// Pattern narrows to E2B variants so text-only Gemma weights are excluded.
#define DEFAULT_MODEL_GLOB       "gemma-*[Ee]2[Bb]*.gguf"

/// Glob matched in the model directory to locate the multimodal projector
#define DEFAULT_MMPROJ_GLOB      "*mmproj*.gguf"

/// Directory for log files (rotation / file logging deferred to post-MVP1)
#define DEFAULT_LOG_DIR          "~/.openverb/logs/"

/// VAD default for --file mode (off — file has defined boundaries)
#define DEFAULT_VAD_ENABLED_FILE false

/// VAD default for future live / daemon mode (on — stream needs segmentation)
#define DEFAULT_VAD_ENABLED_LIVE true
