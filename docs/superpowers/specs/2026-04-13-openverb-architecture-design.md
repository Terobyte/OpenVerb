# OpenVerb — Architecture Design Spec

## Overview

OpenVerb is an open-source, 100% local voice-to-text application for macOS (and later iOS). It uses Gemma 4 as the core AI model for context-aware semantic tailoring. No cloud services, no API keys, no data leaves the device.

**Engine:** Gemma 4 E2B audio-native — single model, audio in → polished text out. ~1.5 GB download, ~2–3 GB RAM. No Whisper dependency by default.

**Fallback (Plan B):** Whisper.cpp STT → Gemma 4 E2B text-only, for cases where audio quality degrades or multilingual accuracy matters. Activated manually in Preferences.

**"100% local" scope:** All inference and processing happens on-device. The only network access is the one-time model download at first launch (from HuggingFace, SHA256-verified). After that, OpenVerb never contacts any server. No telemetry, no analytics, no update checks.

## Core Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Primary model | Gemma 4 E2B audio-native (Q4_K_M GGUF) | Single model, ~1.5 GB, ~2–3 GB RAM, no Whisper needed |
| Fallback model | Whisper.cpp (base) + Gemma 4 E2B text-only | Better STT accuracy in noisy conditions or multilingual use. `base` (not `base.en`) for multilingual support |
| Inference runtime | llama.cpp (Metal) | Proven C++, GGUF, Metal GPU on macOS |
| Engine | openverb-engine (C++) | Native performance, like whisper.cpp |
| App | Swift / SwiftUI | Native macOS + future iOS from same codebase |
| Architecture | Client-server (IPC) | Engine reusable across projects, crash isolation |
| UI | Minimal — center-screen waveform window | Spotlight-style, appears on hotkey |
| Hotkey | ⌥Space (default), configurable | Hands-free dictation; best-effort registration at launch (no macOS API to pre-check conflicts — attempt registration; on failure: show inline alert with a text field pre-filled with the conflicting hotkey so user can type an alternative immediately, without needing Preferences which ships in MVP5). MVP3 minimal fallback: `NSAlert` with an `NSTextField` accessory view — on confirm, retry registration with the new key combo. |
| Privacy | 100% local processing | No cloud option, no telemetry. One-time model download at first launch |
| Distribution | `brew install --cask openverb` | Cask for GUI app; model download at first launch |
| Repository | Monorepo | Engine + app + homebrew in one repo |

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                         macOS                            │
│                                                          │
│  ┌──────────────────────┐    ┌─────────────────────────┐ │
│  │  OpenVerb.app         │    │  openverb-engine        │ │
│  │  (Swift/SwiftUI)      │───►│  (C++ daemon)           │ │
│  │                       │IPC │                         │ │
│  │  ┌─────────────────┐  │◄───│  ┌───────────────────┐  │ │
│  │  │ Hotkey Manager  │  │    │  │ Engine API        │  │ │
│  │  │ (toggle ⌥Space) │  │    │  ├───────────────────┤  │ │
│  │  └─────────────────┘  │    │  │ Gemma 4 E2B       │  │ │
│  │  ┌─────────────────┐  │    │  │ audio-native      │  │ │
│  │  │ Audio Capture   │──┼───►│  │ (primary)         │  │ │
│  │  │ (AVAudioEngine) │  │    │  ├───────────────────┤  │ │
│  │  └─────────────────┘  │    │  │ Whisper + E2B     │  │ │
│  │  ┌─────────────────┐  │    │  │ text (fallback)   │  │ │
│  │  │ Accessibility   │──┼───►│  ├───────────────────┤  │ │
│  │  │ API (context)   │  │    │  │ VAD, Prompt Bld,  │  │ │
│  │  └─────────────────┘  │    │  │ IPC Server        │  │ │
│  │  ┌─────────────────┐  │    │  └───────────────────┘  │ │
│  │  │ Recording UI    │  │    │                         │ │
│  │  │ (waveform)      │  │    │                         │ │
│  │  └─────────────────┘  │    │                         │ │
│  │  ┌─────────────────┐  │    │                         │ │
│  │  │ Text Injection  │  │    │                         │ │
│  │  │ (clipboard/kb)  │  │    │                         │ │
│  │  └─────────────────┘  │    │                         │ │
│  └──────────────────────┘    └─────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

**Key clarifications:**
- IPC is **asymmetric bidirectional**. Client drives phase transitions; engine initiates `session.ready` and `progress` messages. The protocol is not symmetric: all session lifecycle decisions belong to the client; the engine only responds or streams status.
- Audio capture lives in Swift app (owns microphone permission). Engine has `capture.h` only for CLI standalone mode (via `--mic` flag).
- Engine supports **one session at a time**. Second connection is rejected with error.
- Command parser runs on Gemma's **text output** (post-inference). No keyword detection on raw audio.
- Resampler is in engine for CLI mode (`--file`). Swift app MUST resample to 16kHz/16-bit/mono
  before sending over IPC (using AVAudioConverter). Engine never resamples IPC audio.

### IPC Protocol

Three-phase protocol over Unix socket (`~/.openverb/engine.sock`).

**Socket security:** Socket created with mode `0600` (owner read/write only). Any process running under the same macOS user can connect — acceptable for a single-user local tool.

Each phase uses a distinct framing; transitions are explicit and unambiguous.

```
# Phase 1 — JSON control (newline-delimited)
→ {"type":"session.start","context":{...}}\n
← {"type":"session.ready"}\n

# session.start context JSON schema:
# {
#   "app":      string   REQUIRED — bundle ID or app name (e.g. "com.apple.Terminal")
#                        Use NSWorkspace.frontmostApplication.bundleIdentifier.
#                        Fall back to localizedName if bundleIdentifier is nil.
#   "window":   string   OPTIONAL — window title from AXUIElement (empty string if unavailable)
#   "selection": string  OPTIONAL — selected text from AXUIElement (empty string if unavailable)
#   "language": string   OPTIONAL — BCP-47 locale (e.g. "en-US", "ru-RU"). Defaults to system locale.
# }
# Engine behavior on unknown fields: ignore silently (forward compatible).
# Engine behavior on missing "app": use "unknown" as app name, apply default style.
# All fields are UTF-8 strings. No nesting beyond top-level context object.

# ↑ After session.ready, both sides switch to Phase 2 (binary mode).

# Phase 2 — Binary audio stream (length-prefixed frames)
# Frame format: 4-byte big-endian length, then that many bytes of PCM.
# Zero-length frame is the end-of-audio sentinel — no JSON audio.end.
→ [0x00 0x00 0x10 0x00][4096 bytes raw PCM 16kHz 16-bit mono]
→ [0x00 0x00 0x10 0x00][4096 bytes raw PCM]
→ [0x00 0x00 0x00 0x00]   # sentinel: end of audio → engine starts inference

# ↑ After zero-length sentinel, both sides switch to Phase 3 (JSON mode).

# Phase 3 — JSON results (newline-delimited)
← {"type":"progress","percent":42.5}\n      # percent: number (int or float), non-monotonic estimate for Path A. Clients MUST accept both types and NOT assume monotonic increase.
← {"type":"result","text":"final tailored text","command":null}\n
# or structural command:
← {"type":"result","text":null,"command":{"action":"delete_last"}}\n
# ↑ After result, session ends. Client may reuse connection (back to Phase 1)
#   by sending a new session.start. Engine does NOT initiate reuse.

# Error response (any phase) — always JSON, always newline-terminated.
# During Phase 2 (binary), the engine NEVER sends binary frames to the client —
# it only receives them. The only data the engine sends during Phase 2 is a JSON
# error line (newline-terminated) if a fatal error occurs (e.g. audio too long,
# buffer overflow). Client MUST check every received byte sequence during Phase 2:
#   if first byte is '{' → read until '\n' (max 4096 bytes, timeout 5s) → parse JSON error
#   otherwise → this violates the protocol invariant; treat as fatal error
# After an error, engine resets to IDLE. Client must start a new session.
#
# CRITICAL CLIENT REQUIREMENT: The client MUST maintain a concurrent read path
# during Phase 2. While the client write loop is sending binary frames, a separate
# thread (or non-blocking poll) MUST read from the socket. If the client only writes
# and never reads during Phase 2, an error JSON sent by the engine will sit in the
# kernel socket buffer unread — by the time the client enters Phase 3 and reads it,
# the error context is stale and recovery is unreliable.
# Implementation: use a background thread that calls poll(fd, POLLIN, 100ms) in a
# loop during Phase 2. On POLLIN: read and parse the error JSON, abort the write loop,
# close the socket. The write loop signals the read thread on sentinel or disconnect.
← {"type":"error","code":"malformed_json","message":"..."}\n
← {"type":"error","code":"phase_violation","message":"..."}\n
← {"type":"error","code":"corrupt_audio","message":"..."}\n
← {"type":"error","code":"inference_failed","message":"..."}\n
← {"type":"error","code":"session_limit","message":"..."}\n
← {"type":"error","code":"timeout","message":"..."}\n
← {"type":"error","code":"duration_exceeded","message":"..."}\n

# Liveness check — Phase 1 only (IDLE state). Used by EngineManager on startup.
→ {"type":"ping"}\n
← {"type":"pong"}\n
# Engine resets no session state on ping. If engine is not in IDLE, ping is ignored.

# Graceful shutdown — client sends ONLY while in Phase 1 or Phase 3 (JSON mode).
→ {"type":"session.shutdown"}\n
# Engine flushes logs, closes socket, exits cleanly. No response sent.
# App may also send SIGTERM; engine handles both identically.
# If shutdown arrives mid-inference, engine aborts inference immediately.
#
# PHASE 2 ABORT RULE: There is no in-band control channel during Phase 2
# (binary mode). To abort a session during streaming, the client MUST
# close the Unix socket connection. Engine detects EOF/ECONNRESET, cancels
# buffered audio, resets to IDLE, and waits for reconnection.
# Writing a JSON message into a binary-framed stream is a protocol violation
# — engine would interpret the first 4 bytes as a huge frame length.
#
# User gestures during recording (defined at app level, not protocol level):
#   ⌥Space (while recording) = CONFIRM — Swift sends zero-length sentinel → inference starts
#   Escape (while recording)  = CANCEL  — Swift closes socket → engine resets to IDLE, window hides
#   ⌥Space (while inferring)  = ABORT + restart — Swift closes+reconnects, starts new session
#
# Escape must be registered via NSEvent.addGlobalMonitorForEvents (NOT local monitor)
# during recording. Reason: NSPanel with nonactivatingPanel style does not reliably
# become key window — a system notification, alert, or Space switch can remove key
# status at any time. A local monitor fires only when the app has key window status;
# a global monitor fires regardless. NSEvent.addGlobalMonitorForEvents for keyDown
# does NOT require Input Monitoring permission for modifier-free keys (Escape = no modifier).
# Register the global Escape monitor on IDLE→RECORDING transition; deregister on exit
# from RECORDING state. Do not leave a global monitor active during IDLE or INFERRING.
```

**Parser state machine (engine-side):**
```
IDLE
  → receives session.start JSON                     → WAITING_READY
  → receives session.shutdown JSON                  → SHUTDOWN (flush + exit)
  → 15s with no session.start after connect         → close connection

WAITING_READY   [includes model load if not already loaded — ~4s on first session or after idle unload]
  → model loaded, sends session.ready JSON          → STREAMING_AUDIO
  → internal error loading model (OOM, file missing)→ sends error JSON → IDLE
  → model load exceeds 30s                          → sends timeout error JSON → IDLE

STREAMING_AUDIO
  → receives length-prefixed PCM frame              → STREAMING_AUDIO (loop)
  → receives zero-length sentinel                   → INFERRING
  → client closes connection (EOF/ECONNRESET)       → IDLE (cancel session)
  → 15s with no first PCM chunk after session.ready → sends timeout error → IDLE
  → 30s with no PCM chunk during active streaming   → sends timeout error → IDLE
  → total recording exceeds max duration (5 min)    → sends error (duration_exceeded) → IDLE

INFERRING
  → sends progress JSON (0..N times)                → INFERRING
  → sends result JSON                               → IDLE
  → receives session.shutdown JSON                  → abort inference → SHUTDOWN
  → client closes connection (EOF/ECONNRESET)       → abort inference → IDLE
  → receives session.start JSON (new session)       → abort inference → WAITING_READY (new session)
  → no progress/result within 30s                   → sends timeout error → IDLE (restarts model)

SHUTDOWN
  → flush logs, close socket, exit process
```

**Progress semantics:** `percent` is an **estimate**, not an exact value. For Path B (Whisper), percent reflects audio processing progress (known duration → accurate). For Path A (Gemma audio-native text generation), percent is interpolated from average tokens/sec and is not guaranteed monotonic. Clients should treat it as an activity indicator, not a precise countdown. Engine sends progress every ~500ms during inference. `percent` type is `number` (JSON), not restricted to integer. Path A (interpolated) may emit float values (e.g. 42.5). Clients must accept both.

**UI guidance for non-monotonic progress:** Clamp displayed progress to be monotonically non-decreasing — update the UI value only if `newPercent > currentDisplayedPercent`. This hides Path A backtracking without suppressing updates. Users see smooth forward motion; the non-monotonic estimates are absorbed silently.

**Audio format:** 16kHz, 16-bit signed integer, mono. Chunks of 4096 bytes (exactly 128ms: 4096 / (16000 × 2) = 0.128s).

### Data Flow

1. User presses ⌥Space → toggle recording ON
2. Swift app: starts AVAudioEngine capture into a **pre-buffer** + reads context via Accessibility API (parallel). Pre-buffer accumulates PCM from the instant of capture start.
3. Sends `session.start` with context JSON. RecordingWindow shows waveform immediately (from pre-buffer PCM — reassuring user audio is live). If `session.ready` not received within 500ms, UI transitions to "Preparing..." subtitle (cold-start model load, ~4s). On `session.ready` arrival, subtitle clears. AppState emits `.preparing` → `.recording` transition.
4. Swift sends all pre-buffered audio, then continues streaming live PCM → engine VAD filters silence, buffers speech.
   Pre-buffered and live audio are identical from the engine's perspective — both arrive as
   length-prefixed binary frames. Engine does not distinguish them. Pre-buffer can be up to
   ~131 KiB (4.2 × 16 000 × 2 = 134 400 bytes) without issue — the ring buffer is sized for 5min.
5. User presses ⌥Space → toggle recording OFF (CONFIRM)
   OR user presses Escape → CANCEL: Swift closes socket, engine resets to IDLE, window hides. Audio discarded.
6. [CONFIRM path only] Swift sends zero-length binary sentinel → engine runs inference (progress updates back to app)
7. Engine returns `result` → Swift injects text at cursor via clipboard simulation
8. Recording window auto-hides

**Hotkey debouncing:** Minimum 300ms between ⌥Space toggles. Presses within the debounce window are ignored. This prevents state corruption from rapid double-taps.

**⌥Space during inference:** If user presses ⌥Space while engine is in INFERRING state, the current inference is **aborted** and a new recording session begins. The aborted result is discarded. This feels natural — user is "starting over."

**Abort-and-restart latency:** After the client closes the socket, the IpcServer poll loop (1s timeout) may take up to 1s to detect the disconnect and return to `accept()`. Total reconnect window: up to ~1.5s (poll timeout + accept setup). During this window, AppState MUST show a "Reconnecting..." subtitle in RecordingWindow (not IDLE, not RECORDING) — UI must NOT go dark or appear hung. On reconnect success (ping/pong), transition to RECORDING and start streaming. The new session does NOT require a model reload — model stays loaded.

**Empty/ultra-short audio:** If zero-length sentinel arrives with <210ms of audio (<7 VAD frames at 30ms each; frame-aligned threshold — see engine VAD spec), or VAD detected no speech, engine skips inference and returns `{"type":"result","text":"","command":null}`. App discards empty results silently — no error shown.

**VAD-filtered-to-zero:** Even if >210ms of audio was received, if VAD processing filtered ALL frames as silence (ring_buffer.bytes_available() == 0 after sentinel), the engine MUST also return an empty result rather than attempting inference on a zero-byte buffer. Check: `if (ring_buffer_.bytes_available() == 0) → return empty result`. This is a separate check from the duration check and must happen after VAD processing is applied to the buffer.

### Prompt (Primary — Gemma 4 E2B audio-native)

Gemma 4 E2B accepts interleaved text and audio tokens. The engine constructs:
```
[Text tokens: system prompt XML + context XML]
[Audio tokens: raw PCM → Gemma audio embeddings]
[Text tokens: "Output ONLY the final text:"]
```
No `<UserSpeech>` tag — audio is native input, not transcribed text.

**Path A system prompt:**
```xml
<SystemContext>
You are an expert text editor processing direct audio input.
The user dictated speech. Your task:
1. Transcribe what the user said faithfully, preserving all sentences and ideas.
   For short utterances: output the single phrase. For long dictations: output
   every sentence — do NOT summarize or collapse multiple sentences into one.
2. If the same phrase or sentence appears repeated multiple times in the audio,
   output it ONCE only — repetition is an audio encoding artifact, not intentional.
3. Remove filler words (um, uh, like, you know).
4. Fix grammar, adapt tone and style for the active application.
5. If the output is ONLY a structural command (delete that, undo, new line,
   new paragraph), output ONLY that command word(s) with no other text.
   Punctuation (period, comma, question mark, exclamation) is NOT a command —
   output it directly as . , ? ! in the tailored text.
</SystemContext>

<ApplicationContext>
App: {app_name}
Window: {window_title}
Style: {style_from_template}
</ApplicationContext>

<ClipboardContext>
{clipboard_content_dynamic_limit}
</ClipboardContext>

<SelectedText>
{selected_text_dynamic_limit}
</SelectedText>
```

**Dynamic context token limits:** The flat 10KB limit for clipboard and selected text is unsafe when `ctx_size` is small. Use a dynamic ceiling instead:
```
max_context_chars = (ctx_size - 500 - estimated_audio_tokens) * 4
estimated_audio_tokens = recording_duration_secs * 25  # Gemma audio encoder: ~25 tokens/sec
max_clipboard_chars = max_context_chars / 2            # split budget equally
max_selected_chars  = max_context_chars / 2
```
Hard ceiling: 10KB per field regardless of ctx_size (prevents unintended prompt flooding).
Floor: at least 256 chars per field if context budget allows (never truncate to zero when ctx_size is adequate).
`prompt_builder.cpp` MUST apply this calculation before inserting context fields. Log a WARN if either field is truncated.

**XML escaping:** Before inserting clipboard or selected text into prompt tags, escape XML special characters:
- `&` → `&amp;`
- `<` → `&lt;`
- `>` → `&gt;`
- `"` → `&quot;`

This prevents clipboard content from breaking out of its XML tag context. `prompt_builder.cpp` MUST apply this escaping before interpolation. The escaping is applied to `clipboard` and `selected_text` fields only — `app_name`, `window_title`, and `style` values come from internal lookups, not user content, and do not require escaping.

**Context tag behavior when Accessibility is denied:** If Accessibility permission is not granted, `<ApplicationContext>` is populated with `App: unknown`, `Style: default`. `<SelectedText>` is omitted entirely (tag not present in prompt). `<ClipboardContext>` is always available (NSPasteboard does not require Accessibility).

**Clipboard privacy:** `<ClipboardContext>` can be disabled in Preferences (`Include clipboard in context: OFF`). When disabled, the tag is omitted from the prompt. Regardless of setting, clipboard content is never logged — it is used only in-memory for prompt assembly.

Key difference from Path B prompt: instruction 2 explicitly handles repetition artifacts from the audio encoder. Gemma 4 E2B's integrated audio encoder is known to hallucinate repeated phrases on short utterances or silence — the LLM pass is the correct place to suppress this.

**Audio encoder architecture (Gemma 4 E2B):** The integrated audio encoder operates on 40ms frames (vs Whisper's 10ms). Larger frames reduce the token count per second of audio, lowering CPU load. The encoder uses hybrid attention (sliding window + global) to handle longer recordings without linear memory growth.

**MVP 0 validation required — audio embedding path in llama.cpp:**
llama.cpp's mmproj mechanism was designed for vision models (LLaVA-style). Its applicability to Gemma 4 audio input must be confirmed experimentally. Google's own implementation (AI Edge Eloquent) uses LiteRT-LM, not llama.cpp — there is no public reference for Gemma audio via llama.cpp. Two options to validate in MVP 0:
1. **llama.cpp mmproj** — test if Gemma 4 E2B GGUF with audio mmproj weights can process PCM input. This is the preferred path (stays within the existing C++ stack).
2. **LiteRT-LM fallback** — if mmproj proves incompatible, Path A backend switches to LiteRT-LM (Google's own runtime). Adds a second native dependency (~30 MB) but is the proven path. Decision deferred to MVP 0 results.

**Q4_K_M quantization for audio:** Aggressive quantization may degrade audio recognition quality. MVP 0 must benchmark WER at Q4_K_M vs Q8_0 vs F16. If Q4_K_M WER is >5% worse than F16, default to Q8_0 (~3 GB download, ~4 GB RAM).

### Prompt (Fallback — Whisper + Gemma 4 E2B text-only)

After Whisper transcribes audio to text, that text is placed in the prompt:
```xml
<SystemContext>
You are an expert text editor. The user dictated speech which has been
transcribed. Transform the transcription into polished text appropriate
for the active application. Remove filler words (um, uh, like, you know).
If the same phrase appears repeated multiple times, output it ONCE only.
Fix grammar, adapt tone and style. If the output is ONLY a structural
command (delete that, undo, new line, new paragraph, period, comma,
question mark, exclamation), output ONLY that command word(s) with no
other text.
Output ONLY the final text or command, nothing else.
</SystemContext>

<ApplicationContext>
App: {app_name}
Window: {window_title}
Style: {style_from_template}
</ApplicationContext>

<ClipboardContext>
{clipboard_content_dynamic_limit}
</ClipboardContext>

<SelectedText>
{selected_text_dynamic_limit}
</SelectedText>

<Transcription>
{whisper_raw_output}
</Transcription>
```

### App → Style Mapping

Templates in `engine/src/context/templates/`:

| App (Bundle ID) | Style |
|-----------------|-------|
| com.tinyspeck.slackmacgap | Casual, concise, emoji OK |
| com.apple.mail | Formal, complete sentences |
| com.microsoft.VSCode | Code-aware, syntax-correct, comments |
| com.apple.Terminal | Commands, no prose |
| com.apple.Notes | Raw dictation, preserve everything |
| default | Neutral, clean grammar |

### Structural Voice Commands

Detected from Gemma's text output (post-inference pattern match):

| Gemma output | Action | Keystroke (CommandExecutor.swift) |
|-------------|--------|----------------------------------|
| "delete that" | command: delete_last | ⌘Z — undo last paste. Rationale: OpenVerb injected via ⌘V; undo reverses it cleanly in all standard macOS text editors. Keystroke is identical to "undo" — semantic distinction only. |
| "undo" | command: undo | ⌘Z |
| "new line" | command: insert_newline | Return (`kVK_Return`, no modifiers) |
| "new paragraph" | command: insert_newparagraph | Return + Return (two sequential CGEvents, 50ms apart) |

All CGEvents fired by CommandExecutor target the frontmost app captured at ⌥Space time. RecordingWindow must be hidden before CommandExecutor fires (same focus rule as TextInjector).

Punctuation ("period", "comma") — Gemma outputs `.` or `,` directly as part of tailoring, no special handling.

### Failure Modes

| Failure | Handling |
|---------|----------|
| Engine crashes | App detects broken socket, shows error in menu bar, auto-restarts engine with exponential backoff (1s, 2s, 4s between attempts). Crash counter tracked per session: if engine crashes 3 times within 60s, stop auto-restarting and show persistent alert: "Engine keeps crashing — try reducing --ctx-size or closing memory-intensive apps." This prevents OOM crash loops where restart → OOM → crash → repeat until jetsam kills the app. |
| Model fails to load (OOM, corrupt) | Engine returns error JSON, app shows "Model error — re-download?" |
| IPC socket disconnects mid-session | App cancels recording, hides window, shows brief error |
| Microphone access revoked | App detects on next toggle, shows "Microphone permission needed" |
| Gemma produces empty/garbage output | App discards, shows "Could not process — try again" |
| Inference stalls (no progress for 30s) | App shows timeout error, engine restarts model (not entire process) |
| Inference progress (long audio) | Engine sends `{"type":"progress","percent":N}` every ~500ms; app shows activity indicator |
| Recording exceeds 5 min max | Engine sends timeout error, app shows "Recording too long" |

## Threading Model

```
Engine process:
├── Main thread        — IPC listener, accepts connections, session management
├── Audio thread       — receives PCM chunks over IPC, runs VAD, fills ring buffer
└── Inference thread(s)— Gemma/Whisper inference (default: max(1, min(4, cores-2)))

Synchronization:
├── Ring buffer        — lock-free SPSC (single producer = audio thread,
│                        single consumer = ONE inference coordinator thread).
│                        The coordinator thread reads the complete audio buffer ONCE
│                        after the zero-length sentinel, then dispatches all data to
│                        llama.cpp which handles its own internal parallelism (n_threads).
│                        Multiple consumer threads reading the ring buffer would violate SPSC.
│
│                        reset() TIMING INVARIANT: ring_buffer_.reset() is safe to call ONLY
│                        when the inference thread is suspended on infer_cv_.wait(). This is
│                        guaranteed because reset() is called from the session thread only
│                        after result_cv_ signals (inference complete) OR after abort_inference_
│                        is set AND result_cv_ is waited on (abort path). Never call reset()
│                        while the inference thread may be in process_stream().
│
│                        ABORT FREQUENCY: The inference thread MUST check abort_inference_ at
│                        least every 32 generated tokens (one llama.cpp batch boundary is typical).
│                        If abort_inference_ is not checked frequently enough, result_cv_.wait()
│                        in the session thread can hang for seconds while the inference thread
│                        finishes a long batch. 32-token check interval ≈ 0.5–1s max wait on M3 Pro.
├── Progress messages  — inference thread writes to a thread-safe queue;
│                        main thread drains the queue and sends over IPC socket.
│                        No direct socket writes from inference thread.
└── Session state      — owned by main thread. Audio/inference threads signal via atomics.
```

**Inference thread count:** `max(1, min(4, perf_cores))` where `perf_cores` = P-core count only,
obtained via `sysctlbyname("hw.perflevel0.physicalcpu")` (macOS 12+, falls back to
`sysctlbyname("hw.physicalcpu") - 2` on older systems). E-cores slow llama.cpp inference
on Apple Silicon — exclude them from the thread pool. Configurable via `--threads`.

**Model load thread count:** Use ALL physical cores (P + E) during `llama_model_load_from_file`.
Model loading is I/O-bound (disk reads + weight parsing), not compute-bound — E-cores help here.
Set `n_threads_load = hw.physicalcpu` before `llama_model_load_from_file`, restore to inference
thread count after. This can reduce cold-start time by ~30% on Apple Silicon by parallelizing
weight decompression and memory mapping across all cores.

## Daemon Lifecycle

**Liveness check (socket-based, not PID):**
- On startup, app attempts to **connect** to `~/.openverb/engine.sock`
- If connect succeeds and engine responds to `{"type":"ping"}` with `{"type":"pong"}` → reuse existing engine
- If connect fails (ECONNREFUSED / ENOENT) → remove stale socket file, start new engine
- PID file (`~/.openverb/engine.pid`) is written for informational/debugging purposes only, never used for liveness decisions. This avoids TOCTOU race conditions inherent in PID-based checks.

**Socket at** `~/.openverb/engine.sock` (mode `0600`)

**Stale session timeout:** If no first PCM chunk received within 15s of `session.start`, session auto-cancelled. After first chunk, a **streaming stall timeout** of 30s applies — if no PCM chunk arrives for 30s during active streaming, session is cancelled. This prevents engine hangs when the client freezes mid-stream.

**Recording duration limit:** Maximum 5 minutes of continuous audio per session. Ring buffer is sized for 5 minutes at 16kHz/16-bit/mono = ~9.6 MB. Exceeding the limit triggers a timeout error.

**launchd:** macOS launchd plist installed at `~/Library/LaunchAgents/io.openverb.engine.plist` with `KeepAlive = false`. launchd is used **only** for auto-start at login. All crash recovery is handled by EngineManager in the Swift app. The app is the **sole owner** of engine lifecycle — launchd never restarts the engine on its own. If app detects engine is already running (socket connect succeeds), it reuses it regardless of who started it.

**Model lifecycle:**
- Model loads lazily on first `session.start` after daemon start (or after idle unload).
  `session.ready` is sent **only after** the model finishes loading — the client never
  streams audio to an unloaded model. The 15s stale-session timeout covers the ~4s load time.
  Subsequent sessions within the idle timeout reuse the already-loaded model and get
  `session.ready` in <50ms.
- Model unloads after 5 minutes of inactivity (no inference requests); configurable via `--model-idle-timeout` (seconds, default 300)
- **Memory pressure:** Engine registers a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` handler at startup (levels: `DISPATCH_MEMORYPRESSURE_WARN` and `DISPATCH_MEMORYPRESSURE_CRITICAL`). On WARN: log a warning and schedule immediate idle unload (override idle timer). On CRITICAL: call `unload_model()` immediately regardless of session state — if session is active, abort it first (same as SIGTERM path). A 2–3 GB loaded model will be killed by jetsam if not proactively unloaded under critical memory pressure. This is especially important on 8GB and 16GB unified-memory Macs.
- On `NSWorkspace.willSleepNotification`: model unloaded immediately, socket closed
- On wake: engine process stays alive (launchd already started it); model reloads on next inference request

### Backend Switching

Triggered from Preferences when the user changes from Path A (gemma_audio) to Path B (whisper_gemma) or back.

**Lifecycle:**
1. Swift app checks: if recording is active, show alert "Stop recording before switching backend." Block switch.
2. Swift sends `{"type":"session.shutdown"}` to cleanly exit the engine process.
3. EngineManager waits up to 3s for socket to close (process exit confirmation). If timeout, sends SIGTERM.
   **Partial write race:** If the engine is mid-result when SIGTERM arrives (writing `{"type":"result","text":"Hello wo`), the client may read a partial JSON frame. EngineClient MUST handle `JSONDecoder` parse errors during backend switch gracefully — treat a partial/corrupt final message as a cancelled session, not a fatal error. Do not surface a parse error to the user during an intentional backend switch.
4. EngineManager starts a new engine process with `--backend whisper_gemma` (or `gemma_audio`).
5. New engine responds to `{"type":"ping"}` with `{"type":"pong"}` → Swift shows "Backend ready" in status bar.

**Model download:** Path B requires the Whisper model. If not present, EngineManager triggers ModelDownloader **before** starting the new process. Download progress shown in Preferences view. Switch blocked until download completes.

**Memory:** Backend switch requires ~5–10s total (shutdown + model load). Preferences UI must show a loading state during this window.

**No hot-swap:** There is no in-process backend switch. Engine restart is required because llama.cpp and whisper.cpp have separate initialization paths that cannot coexist in a single context.

## openverb-engine (C++) Structure

```
engine/
├── CMakeLists.txt
├── src/
│   ├── main.cpp
│   ├── engine.h/.cpp               # Unified public API
│   │                               # Engine constructor does NOT load the model.
│   │                               # BOTH call sites MUST call engine.ensure_loaded() explicitly:
│   │                               #   (1) IPC daemon: Session calls ensure_loaded() in WAITING_READY
│   │                               #   (2) CLI mode: main.cpp calls ensure_loaded() before process_file()
│   │                               # Forgetting ensure_loaded() in the CLI path is a regression risk
│   │                               # when the constructor load is removed (MVP2 step 21). ensure_loaded()
│   │                               # is idempotent — safe to call multiple times.
│   ├── backend/
│   │   ├── backend.h                    # Abstract interface — TWO inference methods:
│   │   │                                #   process_file(path, ctx_json) → InferenceResult
│   │   │                                #     (CLI mode only; progress via std::function<void(float)>)
│   │   │                                #   process_stream(pcm, sample_rate, ctx_json,
│   │   │                                #                  abort_flag, progress_queue) → InferenceResult
│   │   │                                #     (IPC daemon mode; progress via ProgressQueue&)
│   │   │                                # These are ADDITIVE methods — process_file() is NOT replaced
│   │   │                                # or unified with process_stream(). They serve different call
│   │   │                                # sites with different progress delivery mechanisms. Avoid
│   │   │                                # creating a third "unified" path — maintain both separately.
│   │   ├── backend_gemma_audio.h/.cpp   # Primary: Gemma 4 E2B audio-native
│   │   └── backend_whisper_gemma.h/.cpp # Fallback: Whisper + Gemma 4 E2B text
│   ├── inference/
│   │   ├── llama_context.h/.cpp    # llama.cpp wrapper
│   │   └── whisper_context.h/.cpp  # whisper.cpp wrapper
│   ├── audio/
│   │   ├── vad.h/.cpp              # VAD — two options: Silero via ONNX Runtime (~50MB dep, higher accuracy)
│   │   │                           #   or WebRTC VAD (~100KB, no extra dep, lower accuracy).
│   │   │                           #   Default: WebRTC VAD (zero-dep for easier first build).
│   │   │                           #   Recommendation: switch default to Silero after MVP 1 if binary size acceptable.
│   │   │                           #   Silero can be enabled at build time with -DOPENVERB_SILERO_VAD=ON.
│   │   ├── reader.h/.cpp           # WAV/PCM file reader (CLI mode)
│   │   ├── resampler.h/.cpp        # → 16kHz/16-bit/mono (CLI mode)
│   │   ├── ring_buffer.h/.cpp      # Lock-free SPSC audio buffer (sized for 5 min max = ~9.6 MB)
│   │   └── capture.h/.cpp          # CoreAudio capture (CLI --mic mode only)
│   ├── ipc/
│   │   ├── server.h/.cpp           # Unix socket listener (creates socket with mode 0600)
│   │   ├── protocol.h/.cpp         # JSON + binary framing (incl. binary-phase error detection)
│   │   ├── session.h/.cpp          # Session state machine (all states from spec)
│   │   └── progress.h/.cpp         # Thread-safe progress queue, drained by main thread
│   ├── context/
│   │   ├── prompt_builder.h/.cpp   # XML prompt assembly (omits empty optional tags)
│   │   └── templates/              # Per-app prompts
│   ├── commands/
│   │   ├── parser.h/.cpp           # Post-inference command detection
│   │   └── keywords.h
│   └── config/
│       ├── config.h/.cpp           # Config, CLI args
│       └── defaults.h
├── tests/
├── third_party/                    # Git submodules
│   ├── llama.cpp/
│   ├── whisper.cpp/
│   ├── silero-vad/
│   └── onnxruntime/                # For Silero VAD (adds ~50MB to binary; optional, off by default)
└── bindings/swift/                 # C wrapper layer for iOS embedded mode
                                    # Exports: full inference API (load model, run inference, get result)
                                    # Does NOT export: IPC, daemon, socket — not needed on iOS
```

### CLI Usage

```bash
# Daemon mode (used by macOS app)
openverb-engine --listen

# CLI mode — file input
openverb-engine --file audio.wav --context '{"app":"Terminal"}'

# Context size note: --ctx-size 4096 (default) supports ~130s of audio
# (Gemma 4 E2B audio encoder: ~25 tokens/sec; (4096 − 200) / 25 ≈ 156s max).
# For long recordings (>2 min), pass --ctx-size 8192 or higher. The 5-minute recording limit
# consumes ~7500 audio tokens alone, requiring --ctx-size 8192 minimum.
# Default 4096 is intentionally conservative for memory; increase for long dictation use cases.
#
# OVERFLOW PROTECTION (engine-side): The engine MUST check at every 30s boundary during
# STREAMING_AUDIO whether the buffered audio would exceed the current ctx_size budget:
#   max_audio_tokens = ctx_size - 500 - system_prompt_tokens
#   max_recording_secs = max_audio_tokens / 25
# If the recording duration crosses 80% of max_recording_secs, engine sends a warning:
#   {"type":"warning","code":"approaching_context_limit","seconds_remaining":N}
# If the recording duration hits 100%, engine sends duration_exceeded error and resets to IDLE.
# This prevents silent data truncation — the user gets an explicit error rather than a
# silently truncated or corrupted result.

# CLI mode — live microphone capture (uses capture.h / CoreAudio)
openverb-engine --mic --context '{"app":"Terminal"}'

# Fallback mode explicitly
openverb-engine --backend whisper_gemma --file audio.wav

# Custom model path
openverb-engine --model ~/models/gemma-4-e2b-q4.gguf
```

## OpenVerb.app (Swift) Structure

```
app/OpenVerb/
├── App/
│   └── OpenVerbApp.swift
├── Engine/
│   ├── EngineClient.swift           # IPC client (checks first byte of incoming frames: '{' = JSON, else binary)
│   ├── EngineProtocol.swift         # Message types
│   └── EngineManager.swift          # Process lifecycle, crash recovery, socket-based liveness
├── Input/
│   ├── HotkeyManager.swift          # CGEvent global hotkey (toggle, 300ms debounce)
│                                    # ⌥Space global = confirm/toggle (Input Monitoring required)
│                                    # Escape local = cancel during recording only
│                                    #   (NSEvent.addLocalMonitorForEvents — no extra permission,
│                                    #    fires only when RecordingWindow is key window)
│   └── AudioSession.swift           # AVAudioEngine, mic permission, pre-buffer.
│                                    # MUST downsample capture to 16kHz/16-bit/mono before
│                                    # sending over IPC. Use AVAudioConverter with explicit
│                                    # output format (16kHz, Int16, mono). AVAudioEngine
│                                    # native capture is typically 44.1kHz or 48kHz depending
│                                    # on hardware — do NOT assume 16kHz from the hardware tap.
├── Context/
│   ├── AccessibilityReader.swift    # AXUIElement: app, window, field, selection
│   ├── ClipboardMonitor.swift       # NSPasteboard (max 10KB in context, opt-out in Preferences)
│   └── ContextBuilder.swift         # Assembles context JSON; omits empty optional sections
│                                    # MVP3: {app: NSWorkspace.frontmostApp, clipboard: NSPasteboard}
│                                    #   — no Accessibility; style = app-name fallback only
│                                    # MVP4: adds AccessibilityReader → window title + selected text
│                                    #   → full context-aware prompt tailoring activated
├── UI/
│   ├── RecordingWindow.swift        # Center-screen NSPanel overlay
│   ├── WaveformView.swift           # Real-time audio amplitude — drawn from LOCAL PCM chunks
│                                    # produced by AudioSession BEFORE they are sent to engine.
│                                    # Engine never sends audio data back. AudioSession calls
│                                    # waveform callback(Data) → WaveformView computes RMS amplitude.
│                                    # No IPC involvement — purely a tap on the local audio pipeline.
│                                    # THREADING: AVAudioEngine tap callback fires on a background
│                                    # audio thread. WaveformView @State/@Published updates MUST
│                                    # be dispatched to the main thread:
│                                    #   DispatchQueue.main.async { self.amplitude = rms }
│                                    # Or mark the update method @MainActor. Direct @State mutation
│                                    # from a background thread is undefined behavior in SwiftUI.
│   ├── ProcessingView.swift         # Animated indicator during inference. Driven by progress
│                                    # percent from engine {"type":"progress","percent":N}.
│                                    # NOT a precise countdown (Path A progress is non-monotonic).
│                                    # UI clamps progress to be monotonically non-decreasing:
│                                    # update display only if new value > current displayed value.
│                                    # No numeric label. Falls back to spinner if no progress
│                                    # message received within 2s of inference start.
│                                    # RESET INVARIANT: displayedPercent MUST be reset to 0.0
│                                    # on every IDLE→PREPARING transition (start of new session).
│                                    # If not reset, the clamp variable retains 100 from the prior
│                                    # session and the ring will never animate for the next result.
│   │                                # WAVEFORM→PROCESSING TRANSITION: On RECORDING→INFERRING
│   │                                # transition (sentinel sent), WaveformView fades out over
│   │                                # 150ms while ProcessingView fades in over 150ms (crossfade).
│   │                                # Use SwiftUI .transition(.opacity) with .animation(.easeInOut(
│   │                                # duration: 0.15)) on a ZStack conditioned on AppState.
│   │                                # Do NOT use .transition(.slide) — it causes layout jump.
│   │                                # RecordingWindow height stays constant during transition
│   │                                # (WaveformView and ProcessingView must have matching heights).
│   ├── StatusBarItem.swift          # Menu bar icon
│   ├── PreferencesView.swift        # Hotkey, backend, model path, language, clipboard toggle
│   └── OnboardingView.swift         # First-launch permissions + model download
├── Output/
│   ├── TextInjector.swift           # Clipboard simulation: save→paste→restore
│   └── CommandExecutor.swift        # CGEvent execution of engine commands:
│                                    #   delete_last → ⌘Z (undo last paste)
│                                    #   undo → ⌘Z
│                                    #   insert_newline → Return
│                                    #   insert_newparagraph → Return + Return (50ms apart)
│                                    # Must hide RecordingWindow before firing, same as TextInjector
├── State/
│   └── AppState.swift               # Observable state machine
│                                    # States: IDLE → PREPARING → RECORDING → INFERRING → ERROR
│                                    # PREPARING: session.start sent, session.ready not yet received
│                                    #   (cold-start model load window, up to ~4s)
│                                    # RECORDING: session.ready received, streaming audio
│                                    # Captures targetApp (NSRunningApplication) on IDLE→PREPARING
│                                    #   transition — used by TextInjector and CommandExecutor
├── Model/
│   └── ModelDownloader.swift        # HTTPS download with Range-request resume, progress, SHA256 verify
└── Resources/
    ├── Sounds/                      # start.aiff, stop.aiff
    └── DefaultPrompts/              # Bundled template files
```

### Text Injection

Primary: clipboard simulation — **STRICT OPERATION ORDER** (order is critical for focus correctness):
1. `targetApp: NSRunningApplication` — captured at the moment ⌥Space was first pressed (stored in AppState). Do NOT re-query frontmost app at injection time — RecordingWindow may be foreground by then.
2. Record `NSPasteboard.changeCount` and save current clipboard contents.
3. Write result text to clipboard.
4. `RecordingWindow.orderOut(nil)` — hide panel, release key window status.
5. `targetApp.activate(options: [])` — bring target app to foreground. Focus transfer is async (Mach message to Window Server) while CGEvent posts to the HID event stream — these are separate queues and order is not guaranteed at 0ms delay. Insert a **minimum 50ms delay** (`DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)`) between `activate()` and the CGEvent post. This is the minimum that reliably covers focus transfer under load; 0ms works in benchmarks but fails intermittently when the system is under pressure.
6. Simulate ⌘V via CGEvent (`kCGEventKeyDown`/`Up`, virtualKey `0x09`, flags `.maskCommand`) — posts to HID event stream, delivered to now-active target app.
7. After 300ms (`DispatchQueue.main.asyncAfter`): restore original clipboard **only if** `NSPasteboard.general.changeCount == savedChangeCount` — if another process wrote during the window, skip restore.

**Known edge case (acceptable):** If the user presses ⌘C in the target app BEFORE the ⌘V paste completes (within the first ~100ms), their new clipboard content overwrites OpenVerb's result text, changeCount increments, and the restore is skipped. Result: user's pre-recording clipboard is lost. This race requires sub-100ms user action concurrent with injection and is considered an acceptable edge case — documenting for awareness, not fixing in MVP3.

Fallback: CGEvent keystroke per character (for fields where ⌘V is blocked).

Note: RecordingWindow must use `styleMask: .nonactivatingPanel` to avoid stealing focus during recording. `orderOut` before `targetApp.activate` is required — firing CGEvent while the panel is key window sends ⌘V to the panel, not the target app.

Note: 300ms covers slow applications. If a target app is known to be faster, this can be tuned down, but 100ms is too tight for the general case.

### Internationalization

System prompt language matches the `language` setting in Preferences. Bundled templates exist for: en, ru, es, fr, de, ja. Default: system locale (e.g. `NSLocale.current.languageCode`), falling back to `en` if not in the template list.

**Path B (multilingual):** Whisper `base` model handles STT in 99 languages including Russian. Whisper outputs a detected language code alongside the transcript. If it differs from the configured language, the engine logs a warning. An "auto-detect" option in Preferences uses Whisper's detected language to pick the prompt template dynamically. Gemma 4 E2B does text tailoring in whatever output language the prompt template specifies — this works correctly for Russian, English, and others.

**Path A (English STT only):** Gemma 4 E2B's integrated audio encoder is trained on English audio. Users selecting Path A are shown a warning in Preferences if their configured language is not English. Path A is hidden/disabled in Preferences when the configured language is non-English. If a user explicitly enables Path A on a non-English locale, the engine logs a warning and the result quality is undefined.

### macOS Permissions

- Microphone — for audio recording
- Accessibility — for reading app context (optional; degrades gracefully to `App: unknown` / default style if denied)
- Input Monitoring — for global hotkey

## Repository Structure

```
github.com/openverb/openverb
├── engine/
├── app/
├── homebrew/
│   └── Casks/
│       └── openverb.rb              # Cask definition (lives in monorepo, published to homebrew-tap)
├── scripts/
│   ├── download-model.sh            # Download with Range-request resume + SHA256 verify model files
│   └── build-release.sh
├── validation/                      # MVP 0 validation scripts and results
├── LICENSE                          # MIT
└── README.md
```

**Homebrew tap:** Published as a separate repository `openverb/homebrew-tap` (required by Homebrew conventions). The cask formula source lives in `homebrew/Casks/openverb.rb` in the monorepo; `build-release.sh` copies it to the tap repo during releases.

## Installation

```bash
brew tap openverb/tap              # points to github.com/openverb/homebrew-tap
brew install --cask openverb
# Installs OpenVerb.app
# On first launch: permissions wizard + model download with progress (~1.5 GB, Path A default)
```

Model download source: HuggingFace. SHA256 checksum verified before use.

**Checksum security:** SHA256 checksums MUST be hardcoded in the app bundle (in `ModelDownloader.swift` as compile-time constants), NOT downloaded from a server. If checksums are fetched over the network, a MITM can substitute both the model file and the matching checksum, defeating the verification entirely. The hardcoded values are updated at each release via the build process — `build-release.sh` pins the checksums before signing.

**TODO (must be resolved before MVP 1 human testing):** Pin exact model source:
- `gemma-4-E2B-it-Q4_K_M.gguf` — source repo TBD (ggml-org or unsloth). Record SHA256 in `scripts/download-model.sh`.
- `gemma-4-E2B-it-mmproj.gguf` — audio projection weights, same source.
- Whisper base model — from `ggml-org/whisper.cpp` releases. Record SHA256.

Until pinned, `scripts/download-model.sh` must print a warning: "WARNING: model SHA256 not yet pinned — verify manually after download."

Default model directory: `~/.openverb/models/`

### Build from Source

```bash
git clone https://github.com/openverb/openverb
cd openverb

# Init required submodules only (onnxruntime is optional — Silero VAD, off by default)
git submodule update --init engine/third_party/llama.cpp engine/third_party/whisper.cpp

# Optional: enable Silero VAD (higher accuracy, adds ~50 MB onnxruntime dependency)
# git submodule update --init engine/third_party/onnxruntime engine/third_party/silero-vad
# Then build with: cmake -B build -DOPENVERB_SILERO_VAD=ON

# Download models
./scripts/download-model.sh

# Build engine
cd engine && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j4 && cd ..

# Build app
cd app && xcodebuild -scheme OpenVerb -configuration Release && cd ..
```

## First Launch

1. Open OpenVerb.app
2. Onboarding wizard:
   - Microphone → Allow
   - Accessibility → System Settings (optional but recommended)
   - Input Monitoring → Allow
3. Model download (~1.5 GB Gemma 4 E2B Q4_K_M): SHA256 verified, progress bar.
   Whisper model (~150 MB) is NOT downloaded at first launch — it is downloaded
   on-demand when the user first switches to Path B in Preferences.
4. Engine daemon starts, launchd plist installed
5. Menu bar icon → ready
6. Press ⌥Space → waveform window → speak → press ⌥Space → text at cursor

## Sleep/Wake Handling

App listens for `NSWorkspace.willSleepNotification`:
- **If recording is active:** immediately cancel the session (discard audio, hide window).
  Do NOT attempt inference — the sleep notification budget is too tight (~1–3s, system-dependent)
  and a partial inference result produces worse UX than no result.
- Send `{"type":"session.shutdown"}` IPC message; engine flushes logs, closes socket, exits.
  If socket is unresponsive within 1s, send SIGTERM as fallback.
  **SIGTERM risk during inference:** If the engine is in INFERRING state and its session thread is blocked in process_stream(), it may not respond to SIGTERM within 1s. The engine MUST install a SIGTERM handler that sets a global `g_interrupted` atomic and calls `abort_inference_ = true` — inference thread checks this flag every N tokens (see ring_buffer reset timing). After SIGTERM, allow up to 500ms for the thread to exit gracefully before the OS reclaims the process.
- On wake: EngineManager restarts engine process (≈2s). Model reloads lazily on next use (≈4s on cold load). **Total cold-start latency after wake: ≈6s.** EngineManager MUST show a "Loading model..." indicator in the status bar during this window so the user knows why the first post-wake hotkey press is slow. Subsequent presses within the idle timeout are <50ms.

## Logging

Engine logs to `~/.openverb/logs/engine.log`. Levels: ERROR, WARN, INFO, DEBUG. Rotation: 10 MB max, 3 files kept. Default level: INFO.

**Privacy:** Clipboard content and selected text are NEVER logged at any level. Audio data is never logged. Only metadata (app name, session duration, result length) is logged at INFO.

Swift app logs to OSLog (Console.app visible).

## Performance Targets

> Baseline hardware: Apple M3 Pro (11-core CPU, 18 GB unified memory). Intel Mac performance may be 3–5× slower; M1 approximately 1.5× slower than M3 Pro. Numbers TBD from MVP 0 benchmarks.

| Metric | Primary (Gemma 4 E2B audio) | Fallback (Whisper + E2B) |
|--------|--------------------------|--------------------------|
| Hotkey → waveform visible | < 100ms | < 100ms |
| VAD decision per chunk | < 10ms | < 10ms |
| End-to-end (stop → text injected) | 5–7s (persistent model) | 6–9s (sequential) |
| Memory (model loaded, idle) | ~2–3 GB | ~3 GB |
| Memory (model unloaded, idle) | < 100 MB | < 100 MB |
| IPC audio latency | < 1ms | < 1ms |
| Model download | ~1.5 GB | ~1.7 GB (+Whisper) |
| Max recording duration | 5 min | 5 min |

> **Latency note (from MVP 0 validation):** Persistent-process eval latency is 5–7s per utterance
> on M3 Pro (Q4_K_M, typical 5–15s utterance). Cold-start (model load + eval) is ~12s — the daemon
> model eliminates this. A 5–7s wait is acceptable for dictation where users speak-then-wait; the
> app MUST show an active inference indicator (ProcessingView spinner) during this window.
> Paths to sub-2s: speculative decoding, KV-cache reuse across sessions, chunked streaming
> inference — deferred to post-MVP1 optimization.

## MVP Phases

### MVP 0: Validation (Weeks 1–2)
Prove Gemma 4 E2B audio-native works end-to-end via llama.cpp. CLI tests with recorded audio: WER measurement (Q4_K_M vs Q8_0 vs F16), latency benchmarks, repetition artifact rate. Validate mmproj audio embedding path in llama.cpp — if incompatible, switch to LiteRT-LM. Decision document. **No product code written.**

### MVP 1: C++ Engine CLI (Weeks 3–6)
`openverb-engine --file audio.wav --context '{"app":"Slack"}'` → tailored text. Primary backend (Gemma 4 E2B audio-native) only.

### MVP 2: IPC Daemon + Swift Client (Weeks 7–10)
Daemon mode. Minimal Swift app streams live mic audio, prints result. Engine crash recovery.
**Migration contract:** `client/` is a throwaway CLI prototype. EngineClient.swift, EngineManager.swift, and EngineProtocol.swift from `client/` serve as behavioral reference for MVP3, NOT as copy-paste source. MVP3 rewrites them for `app/OpenVerb/Engine/` with Swift concurrency (async/await), @MainActor, and ObservableObject patterns. `client/` is retained in repo for reference only — it is NOT part of the `app/` build target.

### MVP 3: Hotkey + UI + Text Injection (Weeks 11–14)
Full macOS UX: ⌥Space → waveform window → speak → ⌥Space → text at cursor in any app.
Includes: HotkeyManager, RecordingWindow, WaveformView, ProcessingView, TextInjector.swift,
CommandExecutor.swift (executes delete_last/undo/newline commands from engine result).
**Context limitation:** Accessibility API not included (MVP4). Context JSON = `{app: NSWorkspace.frontmostApp, clipboard: NSPasteboard}` only — no window title, no selected text. Prompt tailoring works via app-name style lookup (fallback mode). MVP3 is a functional but context-minimal proof of the full injection pipeline.
**Model requirement:** EngineManager checks at launch if GGUF model exists at DEFAULT_MODEL_DIR. If missing: show modal alert "Model not found. Download with: ./scripts/download-model.sh" and exit. ModelDownloader.swift is NOT in MVP3 (introduced in MVP5 with OnboardingView). The download script from MVP1 covers developers.

### MVP 4: Context Awareness (Weeks 15–17)
Accessibility API integration. Slack vs Email vs VS Code produce different output automatically.

### MVP 5: Distribution + Polish (Weeks 18–22)
Preferences UI. Onboarding wizard. Homebrew cask. `brew install --cask openverb` on clean Mac.
Note: Voice command **parsing** (commands/parser.h/.cpp + keywords.h) ships in MVP1 (engine-side). CommandExecutor.swift (app-side execution) ships in MVP3 as part of text injection. MVP5 adds Preferences for command customization only — not first introduction of commands.

## Not in v1.0

- Fancy UI animations (ghosting, typing effect)
- Semantic editing commands ("make it shorter", "translate to X")
- Macrowhisper-style routing and automation
- Macros and snippets
- Windows / Linux support
- Meeting transcription / speaker diarization
- Multiple concurrent engine sessions
- Streaming / partial results during inference (long dictations wait for full output)
- Streaming STT→LLM pipeline in Path B (v1.0 Path B is sequential by design: Gemma inference begins only after Whisper fully completes. Future optimization: stream Whisper partial tokens into Gemma as transcription progresses, before STT finishes.)

## iOS

On iOS, `openverb-engine` is compiled as a static library, embedded via `bindings/swift/` (C wrapper layer over the C++ API). Same inference code, same prompt logic.

**bindings/swift/ exports:** Model loading, inference execution, result retrieval, and progress callbacks. It does NOT export IPC, daemon lifecycle, or socket code — none of these exist on iOS.

iOS differences vs macOS (not trivial):
- **Transport:** Unix sockets unavailable → replaced with direct Swift→C function calls on a **background thread** (DispatchQueue.global). Never called on main thread — would block UI. Callback-based: inference runs async, result delivered via completion handler.
- **Daemon/launchd:** No background daemon, no launchd; engine instance is owned by the app process
- **Audio stack:** AVAudioEngine stays; `capture.h` (CoreAudio) replaced with AVAudioSession equivalents; must handle audio session interruptions (calls, Siri)
- **Memory:** iOS background memory limits apply; model must be unloaded when app backgrounds; lazy load required
- **Hotkey:** No global hotkey API on iOS; replaced with in-app button or Action Extension entry point
- **Text injection:** No Accessibility API for text injection in third-party apps; output shown in-app for copy, or via a custom keyboard extension

iOS support is post-v1.0. The `bindings/swift/` C wrapper is designed now to avoid API breakage later.
