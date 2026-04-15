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

/// Maximum recording length accepted in --file mode (seconds)
#define MAX_RECORDING_SECS   300

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
