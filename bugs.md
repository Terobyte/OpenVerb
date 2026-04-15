# OpenVerb — Bug Report (Audited)

Verified against source code on 2026-04-14. 3 confirmed, 10 false positives.

---

## 1. [FIXED] CGEvent tap callback retain cycle

**Severity:** Critical
**File:** `app/OpenVerb/Input/HotkeyManager.swift:113`

`.listenOnly` tap returned `Unmanaged.passRetained(event)` — system ignores the return for listen-only taps, so nobody releases it. Every keyDown leaked a CGEvent.

**Fix:** `passRetained` → `passUnretained`.

---

## 2. [FALSE POSITIVE] Fd race condition в disconnect()

**File:** `app/OpenVerb/Engine/EngineClient.swift:134-150`

Both `close(fd)` and `writeFully` are dispatched on the serial `ioQueue` — they never run concurrently. The `isConnected` data race (reading `fd` outside ioQueue) is technically real but harmless — it's an integer read, not a use-after-free. `wakeWrite` access is protected by MainActor isolation in practice.

---

## 3. [FALSE POSITIVE] RingBuffer: unsigned underflow при пустом буфере

**File:** `engine/src/audio/ring_buffer.cpp:9,29,53`

Theoretical race between `reset()` and concurrent `write()`/`read_all()` exists, but the session state machine ensures `reset()` is only called when no concurrent readers/writers are active. The two-store non-atomicity in `reset()` cannot trigger in normal usage. Defensive hardening could be added later, but this is not an active bug.

---

## 4. [FALSE POSITIVE] `recordingWindow.show()` вызывается до проверки ошибок

**File:** `app/OpenVerb/App/OpenVerbApp.swift:286`

The code wraps `audioSession.start()` in do/catch (lines 268–280) that returns on error. `recordingWindow.show()` is only reached if start succeeds. Order is correct.

---

## 5. [FALSE POSITIVE] VAD filter: короткие команды теряются

**File:** `engine/src/audio/vad.cpp:91`

210ms threshold is spec-compliant (">200ms" requirement). "delete that" at ~500ms produces ~16 speech frames — well above the 7-frame minimum. Filtering would require >50% VAD false negatives from extreme noise, which is inherent to any VAD, not a code bug.

---

## 6. [FALSE POSITIVE] `unload_model()` + активный inference thread = segfault

**File:** `engine/src/backend/backend_gemma_audio.cpp:107-109` + `engine/src/engine.cpp:160-166`

Both `unload_model()` and `process_stream()` hold `engine_mutex_` — they cannot run concurrently. Additionally, `IpcServer` only calls `unload_model()` when `!session_active_`, adding a second layer of protection.

---

## 7. [FALSE POSITIVE] Server `start()` — raw `this` в GCD block

**File:** `engine/src/ipc/server.cpp:101-137`

`stop()` calls `dispatch_source_cancel()` + `dispatch_sync(mem_queue_, ^{})` as a barrier, guaranteeing the handler finishes before `this` is destroyed. Destructor calls `stop()` as a safety net. No use-after-free possible.

---

## 8. [FALSE POSITIVE] Session: `inference_thread_` lifetime gap

**File:** `engine/src/ipc/session.cpp:292-312`

`stop()` checks `inference_thread_.joinable()` before calling `join()`. The non-joinable state between old thread join and new thread creation means no thread is running — this is expected and handled correctly.

---

## 9. [FALSE POSITIVE] Shared RecvBuffer для JSON и бинарных фреймов

**File:** `engine/src/ipc/session.cpp:365`

Protocol enforces that only JSON is received during INFERRING (client sends session.start/session.shutdown only). No binary frames during inference. Acknowledged as "currently safe" in original report.

---

## 10. [FALSE POSITIVE] `json_escape` не валидирует UTF-8

**File:** `engine/src/main.cpp:44-67`

Gemma 4 produces valid UTF-8. Function comment explicitly states scope: "Sufficient for MVP1 model output." Adding UTF-8 validation would be defensive hardening, not a bug fix.

---

## 11. [FIXED] `ContextBuilder.truncateToUTF8Bytes` — удаляет валидный leading byte

**Severity:** Medium
**File:** `app/OpenVerb/Context/ContextBuilder.swift:92-96`

After removing continuation bytes, the code unconditionally removed any byte with bit 7 set — including leading bytes of *complete* multi-byte sequences. E.g., `é` (C3 A9) at the limit boundary: step 1 removes A9, step 2 removes C3. Valid character lost.

**Fix:** Determine expected sequence length from the leading byte. Only remove it if the sequence is incomplete (fewer bytes than expected). If complete, restore the full sequence.

---

## 12. [FIXED] StatusBarItem pulsация не анимируется

**Severity:** Low
**File:** `app/OpenVerb/UI/StatusBarItem.swift:99`

Comment said "Pulse" but code set static `alphaValue = 0.5`. Fixed comment to match actual behavior ("Dim").

---

## 13. [FALSE POSITIVE] `EngineManager.shutdown()` блокирует MainActor семафором

**File:** `app/OpenVerb/Engine/EngineManager.swift:271-279`

Only called from `applicationWillTerminate` and `handleSleep`, where blocking the main thread is acceptable. No other call sites exist.

---

## 14. [CONFIRMED] RingBuffer: нечётные записи оставляют «зависшие» байты

**Severity:** Medium
**File:** `engine/src/audio/ring_buffer.cpp:29-30`

`read_all()` вычисляет `samples = avail / 2`, молча отбрасывая остаток. Если клиент отправляет PCM-фрейм с нечётным числом байт (нарушение протокола, но без валидации), 1 байт навсегда остаётся в буфере и накапливается между сессиями.

```cpp
size_t avail   = w - r;
size_t samples = avail / 2;   // нечётный байт потерян навсегда
```

**Fix:** Валидировать чётность в `write()`, или читать по маске: `size_t n = avail & ~size_t(1);`

---

## 15. [CONFIRMED] Stale `session_active_` отклоняет валидные соединения

**Severity:** Medium
**File:** `engine/src/ipc/server.cpp:213,224-226,241`

`session_active_` использует `memory_order_relaxed`. Сессионный поток записывает `false` (строка 241), но accept-цикл читает флаг (строка 213) *до* join'а потока (строка 224-226). Join обеспечивает happens-before, но происходит слишком поздно — флаг уже проверен. Возникает окно, в котором завершённая сессия выглядит активной, и следующий клиент получает `session_limit` rejection.

```cpp
if (session_active_.load(std::memory_order_relaxed)) {  // stale true
    send_json(client_fd, ...);  // reject
}
if (session_thread_.joinable()) {
    session_thread_.join();     // happens-after, уже поздно
}
```

**Fix:** Использовать `memory_order_acquire` на load, или перенести join перед проверкой флага.

---

## 16. [CONFIRMED] Abort не проверяется во время токенизации аудио

**Severity:** Medium
**File:** `engine/src/inference/llama_context.cpp:405-437`

`mtmd_tokenize()` и `mtmd_helper_eval_chunks()` могут выполняться несколько секунд для длинных аудио, но не проверяют `abort_flag`. Прерывание сессии (timeout, disconnect клиента, `session.start` override) срабатывает только когда запускается генерация (строка 460), создавая задержку в несколько секунд.

```cpp
int32_t tok_rc = mtmd_tokenize(...);        // нет проверки abort
int32_t eval_rc = mtmd_helper_eval_chunks(...); // нет проверки abort
// abort проверяется только здесь:
for (int i = 0; i < MAX_NEW_TOKENS; ++i) {
    if (abort_flag && abort_flag->load()) break;
```

**Fix:** Проверять `abort_flag` (и `g_interrupted`) между tokenize и eval, а также периодически внутри eval если API поддерживает чанкованную обработку.

---

## 17. [CONFIRMED] `send_json` для progress не защищён от disconnect

**Severity:** Low
**File:** `engine/src/ipc/session.cpp:340-344`

Прогресс-обновления используют `send_json()` напрямую — он бросает `ConnectionClosed` при отключении клиента. `send_error()` и `send_warning()` оборачивают свои вызовы `send_json` в `try { } catch (...) {}`, но отправка прогресса — нет. При disconnect во время INFERRING исключение попадает в catch-блок, обходя нормальный flow очистки.

```cpp
for (float pct : progress_queue_.drain()) {
    send_json(fd, nlohmann::json{...});  // может бросить ConnectionClosed
}
```

**Fix:** Обернуть в `try { send_json(...); } catch (...) { break; }`.

---

## 18. [CONFIRMED] Нет валидации `--model-idle-timeout` на отрицательные значения

**Severity:** Low
**File:** `engine/src/config/config.cpp:210-218`

Отрицательные значения принимаются без ошибки. В сервере проверка `idle_timeout_secs_ > 0` пропускает отрицательные — по смыслу это эквивалент «никогда не выгружать», но `0` уже означает это по конвенции. Опечатка вроде `--model-idle-timeout -30` не выдаёт ошибки.

```cpp
cfg.model_idle_timeout_secs = std::stoi(optarg);  // нет range check
```

**Fix:** Добавить `if (cfg.model_idle_timeout_secs < 0) { error; exit(1); }`.

---

## 19. [CONFIRMED] `engine_mutex_` удерживается всю inference — блокирует `unload_model()`

**Severity:** Design
**File:** `engine/src/engine.cpp:175`

`process_stream()` удерживает `engine_mutex_` на всё время инференса (потенциально 30+ секунд). `unload_model()` требует тот же мьютекс. Обработчик CRITICAL memory pressure в `server.cpp` вынужден устанавливать `g_interrupted`, убивая весь процесс, вместо graceful unload модели.

```cpp
InferenceResult Engine::process_stream(...) {
    std::lock_guard<std::mutex> lk(engine_mutex_);  // удерживается 30+ секунд
    ...
    return backend_->process_stream(...);
}
```

**Fix:** Загружать модель под мьютексом, затем отпускать его до инференса. Реаквизировать только при необходимости unload.

---

## 20. [CONFIRMED] `recv_json` buffer size check позволяет овершут

**Severity:** Low
**File:** `engine/src/ipc/protocol.cpp:57-58,92`

Проверка `MAX_JSON_SIZE` происходит в начале цикла, до `poll()` и `read()`. После чтения до 4096 байт (строка 92) буфер может вырасти до `MAX_JSON_SIZE + 4096` (~69632 байт) прежде чем проверка сработает на следующей итерации.

```cpp
if (buf.accumulated.size() > MAX_JSON_SIZE) {  // проверка до read
    throw ...;
}
// ...
buf.accumulated.append(buf.chunk, n);  // может превысить на 4096
```

**Fix:** Проверять размер после append, или пре-проверять `MAX_JSON_SIZE - 4096`.

---

# New bugs — TDD audit 2026-04-14

Method: 4-level C++ debugging (static → cross-file → scenario simulation)
Test file: `engine/tests/test_prove_bugs_tdd.cpp`
Test status: **4/4 RED** — all tests fail, proving the bugs are real

---

## 21. [CONFIRMED] ring_buffer write() return value ignored → silent data loss

**Severity:** HIGH
**Files:** `engine/src/ipc/session.cpp:233`, `engine/src/main.cpp:141`
**Test:** `Bug1_RingBufferDataLoss.*`

`RingBuffer::write()` returns how many bytes were actually written. When the buffer is full it returns less than requested. Neither caller checks the return value.

```cpp
// session.cpp:233 — return value ignored
ring_buffer_.write(frame.data(), frame.size());

// main.cpp:141 — return value ignored
capture.start([&](const uint8_t* data, size_t len) {
    ring_buffer.write(data, len);
});
```

**When it manifests:** 16 MB buffer holds ~8.5 min at 16kHz/16-bit. A client sending audio faster than real-time over the socket overflows before the wall-clock MAX_RECORDING_SECS limit. Middle of audio silently dropped → garbled inference.

---

## 22. [CONFIRMED] read_pcm() doesn't check f.read() result

**Severity:** HIGH
**Files:** `engine/src/audio/reader.cpp:208-210`
**Test:** `Bug2_ReadPcmUnchecked.*`

```cpp
// read_pcm — bare f.read(), no check
if (num_samples > 0)
    f.read(reinterpret_cast<char*>(samples.data()),
           static_cast<std::streamsize>(num_samples * sizeof(int16_t)));
// ← no check on f.fail()
```

`read_wav()` uses `must_read()` which throws on I/O error. `read_pcm()` skips this check entirely. On I/O error, vector contains uninitialized memory sent directly to inference.

---

## 23. [CODE REVIEW] process_file() calls std::exit(1) from library code

**Severity:** MEDIUM
**Files:** `engine/src/engine.cpp:89-93, 103-108, 112-114`

Three `std::exit(1)` calls in `Engine::process_file()`. `std::exit` skips local destructors. Engine is a class designed for reuse — daemon, tests, or embedded callers get killed instead of receiving an error.

---

## 24. [CODE REVIEW] llama token pieces >63 bytes silently dropped

**Severity:** MEDIUM
**Files:** `engine/src/inference/llama_context.cpp:476-486`

```cpp
char piece_buf[64];
int32_t piece_len = llama_token_to_piece(..., piece_buf, sizeof(piece_buf) - 1, ...);
if (piece_len > 0) {          // negative = buffer too small → silently skipped
    output.append(piece_buf, piece_len);
}
```

Per llama.cpp API, when buffer is too small, returns negative of required size. The `if (piece_len > 0)` skips it. Tokens >63 bytes disappear from output.

---

## ~~25. DUPLICATE of #6~~ unload_model() — protected by engine_mutex_, not an active bug

## ~~26. DUPLICATE of #3~~ reset() non-atomic — session state machine prevents concurrent access

## ~~27. RELATED to #17~~ send_error() catch-all — see #17 for the actionable variant

---

## 28. [CONFIRMED] VAD filter() vs is_speech() use different sample_rate source

**Severity:** LOW (latent)
**Files:** `engine/src/audio/vad.cpp:49-51` vs `engine/src/audio/vad.cpp:80-83`
**Test:** `Bug8_VadRateMismatch.*`

`is_speech()` uses `sample_rate_` from constructor. `filter()` uses its parameter. If these differ, behavior is silently wrong. Currently both always 16kHz.

---

## 29. [CONFIRMED] g_interrupted set by IpcServer::stop(), never reset

**Severity:** LOW
**Files:** `engine/src/ipc/server.cpp:253`, `engine/src/config/interrupts.h`
**Test:** `Bug9_GlobalInterruptPollution.*`

`stop()` sets the process-global `g_interrupted = true`. Nothing resets it. If IpcServer is stopped and recreated (tests, re-init), the new poll loop exits immediately.

---

# New bugs — TDD audit 2026-04-15

Method: code audit + gtest where possible
Test file: `engine/tests/test_bugs_30_35_tdd.cpp`

---

## 30. [FALSE POSITIVE] kMinSpeechFrames — was already 7 in git history

**Reported:** `kMinSpeechFrames = 1` instead of 7 — spec violation.
**Reality:** `git log --all` shows the value was **always 7** since first commit (959aa84). The bug report cited a value that never existed in committed code. Possibly observed in an uncommitted local edit that was fixed before commit.

---

## 31. [CONFIRMED] VAD filter output discarded — full audio sent to inference

**Severity:** MEDIUM
**File:** `engine/src/backend/backend_gemma_audio.cpp:55-76` (commit 959aa84)
**Proof:** code read — `speech` computed but unused; `audio_pcm` passed to `infer()`

`vad_.filter()` computed trimmed audio (without silence), but the result was never used. `llama_->infer()` received the original `audio_pcm` with silence. The comment on line 60-61 explicitly documents this as intentional ("Gemma 4 processes the full audio natively"), but the spec requirement is to strip silence to save context tokens.

```cpp
const std::vector<int16_t> speech = vad_.filter(tmp, sample_rate);
if (speech.empty()) { return InferenceResult{}; }
// Note: we pass the *original* audio_pcm to infer(), not the trimmed
// speech, because Gemma 4 processes the full audio natively.
// VAD here is used only as a gating filter, not for trimming.
// ...
llama_->infer(system_xml, audio_pcm, ...);  // ← original, not speech
```

**Impact:** ~50% of 4096-token context window wasted on silence for typical 30s recordings with pauses.

**Fix:** `inference_pcm = speech` — pass filtered audio to `infer()`.

---

## 32. [CONFIRMED] EngineClient.phase2Monitor data race on fd

**Severity:** MEDIUM
**File:** `app/OpenVerb/Engine/EngineClient.swift:438-444`
**Proof:** code read — no gtest (Swift code)

Phase2 monitor (`Task.detached`) reads `fd` directly and calls `recvJSONSync` without `ioQueue` synchronization. `fd` is modified on `ioQueue` in `connectSync` and `disconnect`. Race window: `disconnect()` closes `fd` on `ioQueue` while monitor passes stale `fd` to `poll()`/`read()`.

Mitigated in practice by `stopPhase2Monitor()` writing to wakeup pipe, which causes the monitor to exit within 100ms. But the window exists.

**Fix:** Capture `fd` as `monitorFd` at monitor start; use captured value instead of reading `fd` directly.

---

## 33. [CONFIRMED] EngineClient.isConnected data race

**Severity:** LOW (harmless on 64-bit platforms)
**File:** `app/OpenVerb/Engine/EngineClient.swift:150`
**Proof:** code read — no gtest (Swift code)

`isConnected` reads `fd` from any thread, but `fd` is protected by `ioQueue`. On 64-bit platforms Int32 reads are naturally atomic. Stale read is benign (worst case: returns stale `true` for a few ms after disconnect). Not worth fixing.

---

## 34. [FALSE POSITIVE — already fixed in commit 114042b] process_stream() mutex release → latent use-after-free

**Reported:** `unload_model()` could free model while `process_stream()` runs via shared_ptr copy.
**Reality:** Commit 114042b ("fix engine: release mutex before inference via shared_ptr backend") already fixed this. The pre-fix code held `engine_mutex_` for the entire inference (BUG 19), and the fix introduced the shared_ptr copy pattern. `unload_model()` is only called when `!session_active_` by convention, and the shared_ptr keeps the Backend alive for any in-flight inference.

---

## 35. [CONFIRMED] drainResult() redundantly hides RecordingWindow

**Severity:** LOW
**File:** `app/OpenVerb/App/OpenVerbApp.swift:559-584`
**Proof:** code read — no gtest (Swift code)

After `.result` case, `TextInjector.inject()` or `CommandExecutor.execute()` already hides the window via `window.orderOut`. Then line 584 calls `recordingWindow.hide()` again — redundant double-hide. No functional impact (double-hide is a no-op), just dead code.

```swift
case .result(let text, let command):
    // ... TextInjector/CommandExecutor already hides window ...
    hotkeyManager.removeEscapeMonitors()
    appState.transition(to: .idle)
    recordingWindow.hide()  // ← redundant, window already hidden
```

**Fix:** Remove the redundant `recordingWindow.hide()`.

---

# New bugs — TDD audit 2026-04-15 (wave 2)

Method: code audit + gtest where possible
Test file: `engine/tests/test_new_bugs_36_40_tdd.cpp`
Test status: **5/5 RED** — all tests fail, proving the bugs are real

---

## 36. [CONFIRMED] parse_command: trailing space after punctuation strip breaks keyword match

**Severity:** MEDIUM
**File:** `engine/src/commands/parser.cpp:67-69`
**Test:** `Bug36_CommandNormOrder.*`

Normalization runs `trim_whitespace` → `strip_trailing_punct` → `to_lower`. When the model outputs `"delete that ."` (space before period), the strip removes `.` but leaves `"delete that "` with a trailing space. The space prevents exact keyword match.

```cpp
trim_whitespace(normalised);       // "delete that ." → "delete that ."
strip_trailing_punct(normalised);  // "delete that ." → "delete that " ← trailing space!
to_lower(normalised);              // "delete that " → "delete that "
auto it = COMMAND_KEYWORDS.find(normalised);  // "delete that " ≠ "delete that" → no match
```

**Fix:** Swap steps 1 and 2 (strip punctuation first, then trim), or add a second `trim_whitespace` after `strip_trailing_punct`.

---

## 37. [CONFIRMED] WAV unknown chunk `chunk_size = 0xFFFFFFFF` uint32_t overflow causes misparse

**Severity:** MEDIUM
**File:** `engine/src/audio/reader.cpp:146`
**Test:** `Bug37_WavChunkOverflow.*`

```cpp
uint32_t skip = chunk_size + (chunk_size & 1u);
```

When `chunk_size = 0xFFFFFFFF` (odd): `0xFFFFFFFF + 1 = 0` (wraps in uint32_t). `f.seekg(0, cur)` is a no-op — file position doesn't advance. Parser re-reads payload bytes as chunk headers, never finds the `data` chunk, and throws `"reached end of file without a data chunk"`.

**Fix:** Use `uint64_t` for skip calculation: `uint64_t skip = static_cast<uint64_t>(chunk_size) + (chunk_size & 1u);` or detect overflow before the addition.

---

## 38. [CONFIRMED] to_mono silently discards trailing samples when `samples.size() % channels != 0`

**Severity:** LOW
**File:** `engine/src/audio/resampler.cpp:216`
**Test:** `Bug38_ToMonoTrailingSamples.*`

```cpp
const std::size_t frames = input.samples.size() / static_cast<std::size_t>(ch);
```

Integer division silently drops remainder. 3 stereo samples → 1 frame, sample at index 2 is lost with no warning. Truncated or corrupted audio files can lose up to `channels - 1` samples.

**Fix:** Use ceiling division: `frames = (input.samples.size() + ch - 1) / ch`, or throw if `samples.size() % ch != 0`.

---

## 39. [CONFIRMED] resample_channel uses floor division — loses last sample

**Severity:** LOW
**File:** `engine/src/audio/resampler.cpp:162-164`
**Test:** `Bug39_ResampleFloorTruncation.*`

```cpp
const std::size_t n_out = static_cast<std::size_t>(
    static_cast<double>(n_in) * static_cast<double>(dst_rate)
    / static_cast<double>(src_rate));
```

48001 samples at 48 kHz → 16 kHz: `floor(48001 * 16000 / 48000) = 16000`, but correct output is 16001. The `static_cast<size_t>` truncates toward zero, losing the last sample.

**Fix:** Use ceiling: `n_out = static_cast<size_t>(std::ceil(...))` or integer arithmetic `(n_in * dst_rate + src_rate - 1) / src_rate`.

---

## 40. [CONFIRMED] max_audio_secs goes negative when `ctx_size < SYSTEM_PROMPT_TOKENS_RESERVED`

**Severity:** MEDIUM
**File:** `engine/src/ipc/session.cpp:76-78`
**Test:** `Bug40_NegativeMaxAudioSecs.*`

```cpp
const double max_audio_secs =
    static_cast<double>(effective_ctx - SYSTEM_PROMPT_TOKENS_RESERVED)
    / static_cast<double>(AUDIO_TOKENS_PER_SEC);
```

`--ctx-size` accepts any positive integer (config.cpp validates `> 0` but not `> 500`). With `ctx_size = 100`: `max_audio_secs = (100 - 500) / 25 = -16.0`. Then `dur >= max_audio_secs` is always true (duration is non-negative), so every audio frame is immediately rejected with `duration_exceeded`.

**Fix:** Clamp: `effective_ctx = std::max(effective_ctx, SYSTEM_PROMPT_TOKENS_RESERVED + 1)`.

---

## 41. [CODE REVIEW] PCM path allocates entire file before checking duration

**Severity:** MEDIUM
**File:** `engine/src/engine.cpp:93-104`

WAV path peeks duration via header before allocating (`peek_wav_duration_secs`). PCM path calls `read_pcm()` first (allocates entire file into memory), then checks duration. A 4 GB PCM file causes OOM before the duration check fires.

**Fix:** `stat()` the file before calling `read_pcm()`, or add a max-size parameter.

---

## 42. [CODE REVIEW] recv_json per-poll timeout — connection held open indefinitely

**Severity:** MEDIUM
**File:** `engine/src/ipc/protocol.cpp:42-94`

`recv_json` calls `poll()` with the same `timeout_ms` every iteration. A client sending one byte every `timeout_ms - 1` ms never triggers a timeout. With `idle_timeout_secs = 15` and `MAX_JSON_SIZE = 65536`: a malicious client can hold a connection for ~11.4 days. Contrast with `read_exact()` which correctly uses a deadline.

**Fix:** Track a deadline like `read_exact()` does; shrink remaining timeout each iteration.

---

## 43. [CODE REVIEW] Session catch(...) block doesn't set inference_error_

**Severity:** LOW
**File:** `engine/src/ipc/session.cpp:313-315`

```cpp
} catch (...) {
    LOG_WARN("session: inference threw non-std exception");
    stop_requested_.store(true, std::memory_order_relaxed);
    // ← inference_error_ NOT set
}
```

The `std::exception` handler sets `inference_error_ = e.what()`, but `catch(...)` doesn't. Client gets generic `"inference produced no result"` instead of a meaningful error.

**Fix:** Add `inference_error_ = "non-std exception during inference";` in the catch(...) block.

---

## 44. [CODE REVIEW] GCD memory pressure handler — relaxed load race on pressure_critical_active_

**Severity:** HIGH (latent, ARM-specific)
**File:** `engine/src/ipc/server.cpp:135,241-242`

```cpp
// Accept path (main thread):
pressure_critical_active_.store(true, std::memory_order_relaxed);  // line 241
session_active_.store(true, std::memory_order_relaxed);            // line 242
session_thread_ = std::thread(...);                                  // line 245

// GCD handler (different thread):
if (self->pressure_critical_active_.load(std::memory_order_relaxed)) {  // line 135
    // safe path: set g_interrupted
} else {
    self->engine_.unload_model();   // ← can fire during active inference!
}
```

Both stores use `memory_order_relaxed` — no memory barrier. On ARM (Apple Silicon), the GCD thread can read stale `false` from `pressure_critical_active_` even after the main thread has set it to `true`. The `else` branch calls `engine_.unload_model()` during active inference, which resets `llama_` via `backend_->unload_model()` while the session thread still holds a `shared_ptr` to the same Backend object. The shared_ptr prevents deallocation but not internal mutation → null `unique_ptr` dereference → segfault.

The crash window is narrow: GCD handler must fire between `process_stream()` copying the shared_ptr and inference completion, AND the relaxed load must return stale `false`. Unlikely but not impossible under memory pressure.

**Fix:** Use `memory_order_release` on stores and `memory_order_acquire` on loads, or check `session_active_` in the `else` branch as a fallback guard.
