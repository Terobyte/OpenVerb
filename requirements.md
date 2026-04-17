# Streaming Chunked Transcription — Implementation Plan

**Goal:** Convert OpenVerb from batch inference ("record fully → infer fully") to a streaming pipeline where the engine starts inferring audio chunks while the user is still speaking, emits partial results in real time, removes the hard 5-minute recording cap, and displays a live countdown of remaining inference time after the user releases the hotkey.

**Architecture:** Engine-side three-thread pipeline: (1) network reader fills the chunker, (2) a VAD chunker thread splits the PCM stream on silence boundaries into `Chunk` records and pushes them to a bounded queue, (3) an inference worker thread pops chunks, runs `engine.process_stream()` on each, and emits a new `partial_result` wire message per chunk plus periodic `queue_status` messages carrying the adaptive ETA. Swift accumulates partials, concatenates text, and renders a live countdown only after the user releases the hotkey.

**Tech Stack:** C++17 engine (WebRTC VAD, llama.cpp, Gemma 4 E2B audio backend, GoogleTest), Swift 5.9 client (XCTest, SwiftUI), Unix-domain socket newline-delimited JSON + length-prefixed binary frames.

---

## Phases

## Steps
- [x] [general] Add streaming constants to engine/src/config/defaults.h after MAX_RECORDING_SECS: MIN_CHUNK_MS=3000, MAX_CHUNK_MS=20000, SILENCE_BOUNDARY_MS=600, CHUNK_QUEUE_MAX_DEPTH=8, QUEUE_STATUS_HEARTBEAT_MS=500, DEFAULT_CHUNK_INFER_SPEED=0.5, INFER_SPEED_EWMA_ALPHA=0.3
- [x] [general] Commit: add streaming chunk constants to defaults.h

- [x] [tdd-guide] Write failing tests for ChunkQueue in engine/tests/test_chunk_queue.cpp — cover FIFO ordering, blocking pop, shutdown unblocks popper, depth counter, queued_audio_ms tracking, backpressure (push blocks when full), shutdown unblocks blocked pusher, reset clears residue and re-arms
- [x] [general] Write engine/src/audio/chunk_queue.h: Chunk struct (id, pcm, is_final, duration_ms) and ChunkQueue class with push/pop/depth/queued_audio_ms/shutdown/reset interface
- [x] [general] Implement engine/src/audio/chunk_queue.cpp: push with backpressure (blocks at CHUNK_QUEUE_MAX_DEPTH), pop blocks until data or shutdown, shutdown wakes both pushers and poppers, reset clears queue and re-arms shut_ flag, queued_audio_ms tracks sum of pending duration_ms
- [x] [general] Commit: add thread-safe chunk queue

- [x] [tdd-guide] Write failing tests for VadScanner in engine/tests/test_vad_scanner.cpp — cover no-speech produces no chunks, continuous speech produces single chunk at MAX_CHUNK_MS, silence boundary splits into two chunks, final flush emits is_final chunk even if below MIN_CHUNK_MS
- [x] [general] Write engine/src/audio/vad_scanner.h: VadScanner class that owns a Vad, accumulates PCM, and emits completed Chunks via callback; expose push_frame(samples, n), flush(), reset()
- [x] [general] Implement engine/src/audio/vad_scanner.cpp: state machine (accumulating/boundary), split on SILENCE_BOUNDARY_MS of silence or MAX_CHUNK_MS forced cut, never emit below MIN_CHUNK_MS unless flushing, call callback with completed Chunk
- [x] [general] Commit: add online vad scanner

- [x] [tdd-guide] Write failing C++ tests in engine/tests/test_protocol.cpp for partial_result wire format (chunk_id, text, is_final) and queue_status wire format (pending, in_flight, eta_ms)
- [x] [general] Declare send_partial_result(fd, chunk_id, text, is_final) and send_queue_status(fd, pending, in_flight, eta_ms) in engine/src/ipc/protocol.h
- [x] [general] Implement send_partial_result and send_queue_status in engine/src/ipc/protocol.cpp using existing newline-delimited JSON framing
- [x] [general] Commit: add partial_result and queue_status wire messages
- [x] [tdd-guide] Write failing Swift decode tests in app/OpenVerbTests/EngineProtocolTests.swift for partialResult(text:chunkId:isFinal:) and queueStatus(pending:inFlight:etaMs:) round-trips through fromJSON
- [x] [general] Add .partialResult(text: String, chunkId: Int, isFinal: Bool) and .queueStatus(pending: Int, inFlight: Bool, etaMs: Int) cases to the ServerMessage enum in app/OpenVerb/Engine/EngineProtocol.swift
- [x] [general] Extend the fromJSON switch in EngineProtocol.swift to decode "partial_result" and "queue_status" JSON objects into the new enum cases
- [x] [general] Commit: decode partial_result and queue_status in swift client

- [x] [refactor] Remove the #define MAX_RECORDING_SECS 300 macro from engine/src/config/defaults.h
- [x] [refactor] Remove duration_exceeded from the wire protocol: delete send_duration_exceeded() declaration from protocol.h and its implementation from protocol.cpp
- [x] [refactor] Remove the duration check block from engine.cpp (the block that calls send_duration_exceeded and returns early)
- [x] [refactor] Remove both the duration-cap check block and the context-budget bail-out block from session.cpp STREAMING_AUDIO state
- [x] [refactor] Delete or rewrite engine tests that asserted on the 300s cap or on duration_exceeded; preserve tests that confirm unbounded recording works
- [x] [general] Commit: remove 5-minute recording cap and duration_exceeded wire code
- [x] [refactor] Rename stop() internals to drop the inference_thread_ reference: replace the join+reset of inference_thread_ with no-op stubs (worker teardown will be wired in Task 7); update destructor accordingly
- [x] [general] Commit: prepare Session::stop for chunked worker teardown
- [x] [general] Add streaming state members to the Session class in engine/src/ipc/session.h: VadScanner chunker_, ChunkQueue chunk_queue_, std::thread worker_thread_, double infer_speed_ewma_, std::atomic<bool> pipeline_active_
- [x] [general] Commit: declare streaming pipeline members on Session

- [x] [general] At the WAITING_READY → STREAMING_AUDIO state transition in session.cpp: call chunk_queue_.reset(), initialize infer_speed_ewma_ = DEFAULT_CHUNK_INFER_SPEED, set pipeline_active_ = true, launch worker_thread_ pointing to run_inference_worker_
- [x] [general] In STREAMING_AUDIO read loop in session.cpp: feed incoming PCM frames to chunker_.push_frame() instead of ring_buffer; chunker callback calls chunk_queue_.push()
- [x] [general] On sentinel receipt in session.cpp: call chunker_.flush() to emit the final chunk with is_final=true, then join worker_thread_, send the final concatenated result via send_result()
- [x] [general] On connection drop or error in session.cpp: set pipeline_active_ = false, call chunk_queue_.shutdown(), join worker_thread_ (with timeout), reset chunker_ for next session
- [x] [general] Commit: rewrite STREAMING_AUDIO with chunked pipeline (link error for run_inference_worker_ expected until step 35)
- [x] [general] Declare private method run_inference_worker_() in engine/src/ipc/session.h
- [x] [general] Implement run_inference_worker_ in session.cpp: loop pop()ing from chunk_queue_, call engine_.process_stream() on each chunk's PCM, send_partial_result() with the text and chunk id, update infer_speed_ewma_ via EWMA formula, send send_queue_status() heartbeat every QUEUE_STATUS_HEARTBEAT_MS ms, exit when chunk is_final or pipeline_active_ is false
- [x] [general] Commit: streaming chunked inference pipeline in session
- [x] [refactor] Delete the State::INFERRING enum value from session.h
- [x] [refactor] Delete the INFERRING state transition block and its case in the session.cpp state machine dispatch
- [x] [refactor] Delete inference_thread_ member and any associated start/join helpers that are now dead code
- [x] [refactor] Delete or rewrite engine tests that referenced INFERRING state or the old single-shot inference path; ensure remaining tests cover the new streaming path
- [x] [general] Commit: remove dead INFERRING state and legacy inference thread
- [x] [tdd-guide] Write session integration test in engine/tests/test_session.cpp: push ~10 seconds of alternating speech/silence PCM frames through a mock session, assert ≥2 partial_result messages arrive in monotonic chunk_id order, assert the final message is a result containing the concatenated text of all partial chunks
- [x] [tdd-guide] Run integration test, implement any missing hooks or test seams needed to make it pass, iterate until green
- [x] [general] Commit: session integration test for streaming partials

- [x] [general] Add onPartialResult: ((String, Int, Bool) -> Void)? and onQueueStatus: ((Int, Bool, Int) -> Void)? closure properties on EngineClient in app/OpenVerb/Engine/EngineClient.swift
- [x] [general] Rewrite the drainResult() loop in app/OpenVerb/App/OpenVerbApp.swift to dispatch on all four ServerMessage cases: accumulate partial text on .partialResult until isFinal=true or a legacy .result arrives; call onQueueStatus on .queueStatus; preserve existing error/abort semantics
- [x] [tdd-guide] Write unit test in app/OpenVerbTests/EngineManagerTests.swift (or a new file): feed a sequence of mocked ServerMessage values through the drain loop, assert onPartialResult fires in order with correct accumulated text, assert final text equals concatenation of all partial chunks
- [x] [general] Commit: accumulate partials and expose queue_status in drain loop
- [x] [general] Add var remainingInferenceMs: Int? as a @Published property on AppState in app/OpenVerb/State/AppState.swift (or app/OpenVerb/App/AppState.swift per existing location)
- [x] [general] In OpenVerbApp.swift: set remainingInferenceMs from onQueueStatus callback when hotkey has been released; clear it (set nil) on transition back to idle state
- [x] [tdd-guide] Write unit test: AppState.remainingInferenceMs is set when a queue_status arrives after hotkey release, and is nil again after transitioning to idle
- [x] [general] Commit: plumb engine ETA into AppState

- [x] [general] Extend ProcessingViewModel in app/OpenVerb/UI/ProcessingView.swift with updateEta(ms: Int), tick(), resetEta() methods and an etaText: String? computed property that returns "~N сек" when ETA is known
- [x] [general] In OpenVerbApp.swift: observe appState.remainingInferenceMs and call processViewmodel.updateEta(ms:) / resetEta() accordingly; wire a Timer to call tick() each second while ETA is active
- [x] [general] In ProcessingView.swift: when etaText is non-nil render it as the primary status label; fall back to the existing indeterminate spinner text otherwise
- [x] [tdd-guide] Write ProcessingViewModel unit tests in app/OpenVerbTests/ProcessingViewModelTests.swift for updateEta/tick/resetEta pure logic: verify etaText value, that tick decrements, that resetEta clears it
- [x] [general] Commit: countdown display in ProcessingView

- [x] [tdd-guide] Write failing test in engine/tests/test_context.cpp for Context::from_json deserialization: round-trip text_before_cursor, text_after_cursor, app_identifier; clamp oversized surrounding text to context budget
- [x] [general] Implement engine/src/context/context.h (openverb::Context struct with text_before_cursor, text_after_cursor, app_identifier) and engine/src/context/context.cpp (Context::from_json deserializer using nlohmann/json)
- [x] [general] Add readCursorSurroundingText(for:) to app/OpenVerb/Context/AccessibilityReader.swift using kAXValueAttribute and kAXSelectedTextRangeAttribute; return (before: String, after: String) tuple
- [x] [general] Populate surrounding_before and surrounding_after keys in app/OpenVerb/Context/ContextBuilder.swift buildJSON() by calling readCursorSurroundingText; replace the deferred "MVP4" placeholder comments with the real implementation
- [x] [general] Add an overloaded engine/src/engine.h Engine::process_stream(..., const Context& ctx, ...) variant that passes context to the prompt builder; existing callsites using the no-context overload must compile unchanged
- [x] [general] Commit: add Context struct and cursor-surrounding text plumbing
- [x] [general] Add POLISH_CONTEXT_TOKENS and POLISH_MAX_TOKENS constants to engine/src/config/defaults.h; add polish system prompt and instruction constants matching the Gemma Eloquent cleanup prompt pattern
- [x] [tdd-guide] Write failing tests in engine/tests/test_polish.cpp: polish removes filler words ("эээ", "ну"), normalizes mid-sentence restarts, adds terminal punctuation; context fields thread through correctly
- [x] [general] Declare and implement polish_text(const std::string& raw, const Context& ctx) in engine/src/engine.h and engine/src/engine.cpp using the same llama.cpp inference path as process_stream but with the cleanup prompt
- [x] [general] Commit: add polish_text LLM cleanup pass
- [x] [general] Add send_polish_started(fd) and send_polished_result(fd, text) to engine/src/ipc/protocol.h and protocol.cpp
- [x] [general] In session.cpp after worker_thread_ join: call engine_.polish_text(accumulated_text, ctx), send send_polish_started() before the call and send_polished_result() with the output after
- [x] [general] Extend ServerMessage enum in EngineProtocol.swift with .polishStarted and .polishedResult(text: String) cases; extend fromJSON switch to decode "polish_started" and "polished_result" JSON objects
- [x] [general] Add onPolishedResult: ((String) -> Void)? callback to EngineClient; in OpenVerbApp wire it to replace the injected text with the polished version via TextInjector
- [x] [general] Commit: polished_result wire-up and injection
- [x] [general] Add var showLiveTranscript: Bool = false to AppSettings as a @AppStorage-backed property (key "showLiveTranscript")
- [x] [general] Add var livePartialText: String = "" and var polishedText: String? as @Published properties on AppState
- [x] [general] In OpenVerbApp.swift wire onPartialResult to update appState.livePartialText while hotkey is held; wire onPolishedResult to set appState.polishedText and call TextInjector with the polished text
- [x] [general] In RecordingWindow / RecordingContentView: when appState.settings.showLiveTranscript is true, render appState.livePartialText as a live subtitle below the waveform
- [x] [general] Add a "Полирую…" state to ProcessingViewModel: enter it when polishStarted fires, exit (show polished badge) when polishedResult fires; update ProcessingView to render this state
- [x] [tdd-guide] Write view-model tests for live-partials and polish state transitions: livePartialText appends correctly, polish state entered on polishStarted, cleared on polishedResult
- [x] [general] Commit: live partials during recording and polished text injection behind opt-in flag

- [ ] [general] HUMAN: build engine after adding streaming constants — cd engine && cmake --build build -j (expect: clean build, macros unused, no new errors)
- [ ] [general] HUMAN: confirm chunk queue tests fail to build before implementation — cd engine && cmake --build build --target test_chunk_queue -j (expect: compile error referencing missing ChunkQueue symbols)
- [ ] [general] HUMAN: build and run chunk queue tests after implementation — cd engine && cmake --build build --target test_chunk_queue -j && ./build/tests/test_chunk_queue (expect: all 8 tests pass)
- [ ] [general] HUMAN: confirm vad scanner tests fail to build before implementation — cd engine && cmake -B build && cmake --build build --target test_vad_scanner -j (expect: compile error)
- [ ] [general] HUMAN: build and run vad scanner tests after implementation — cd engine && cmake --build build --target test_vad_scanner -j && ./build/tests/test_vad_scanner (expect: all tests pass)
- [ ] [general] HUMAN: confirm C++ protocol tests fail before implementation — cd engine && cmake --build build --target test_protocol && ./build/tests/test_protocol (expect: new test cases fail)
- [ ] [general] HUMAN: run C++ protocol tests after implementation — ./build/tests/test_protocol (expect: all pass including partial_result and queue_status cases)
- [ ] [general] HUMAN: confirm Swift decode tests fail before implementation — cd app && swift test --filter EngineProtocol (expect: new test cases fail with unrecognized message type)
- [ ] [general] HUMAN: run Swift decode tests after implementation — cd app && swift test --filter EngineProtocol (expect: all pass)
- [ ] [general] HUMAN: rebuild engine after removing recording cap — cd engine && cmake --build build -j (expect: clean build; fix any unused-variable warnings from removed locals)
- [ ] [general] HUMAN: grep-check zero residues after cap removal — run: grep -rn MAX_RECORDING_SECS engine/src/ && grep -rn duration_exceeded engine/ && grep -rn ring_buffer engine/src/ipc/ (expect: zero hits in each)
- [ ] [general] HUMAN: build engine after stop() rename — cd engine && cmake --build build -j (expect: clean build)
- [ ] [general] HUMAN: verify engine compiles after adding streaming Session members — cd engine && cmake --build build -j (members unused at this point; no new errors expected)
- [ ] [general] HUMAN: build engine after STREAMING_AUDIO rewrite — cd engine && cmake --build build -j (expect: builds up to a link error on run_inference_worker_ until step 35 is complete)
- [ ] [general] HUMAN: build engine after implementing run_inference_worker_ — cd engine && cmake --build build -j (expect: clean build, no link errors)
- [ ] [general] HUMAN: run all engine tests after session implementation — cd engine && ctest --test-dir build --output-on-failure (expect: all tests pass)
- [ ] [general] HUMAN: grep dead INFERRING surface before deletion — grep -rn "INFERRING\|inference_thread_" engine/src/ (document every occurrence before removing)
- [ ] [general] HUMAN: build engine and run full test suite after INFERRING removal — cd engine && cmake --build build -j && ctest --test-dir build --output-on-failure; then grep -rn "INFERRING" engine/src/ (expect: clean build, all tests pass, zero INFERRING in production code)
- [ ] [general] HUMAN: run Swift client tests after partial accumulation — cd app && swift test --filter EngineClient (expect: all pass)
- [ ] [general] HUMAN: build engine and run all tests after adding Context struct — cd engine && cmake --build build -j && ctest --test-dir build --output-on-failure (expect: all pass including test_context)
- [ ] [general] HUMAN: build engine and run polish tests — cd engine && cmake --build build -j && ./build/tests/test_polish (expect: all pass)
- [ ] [general] HUMAN: build engine and run full Swift test suite after polish wire-up — cd engine && cmake --build build -j; cd app && swift test (expect: all pass)
- [ ] [general] HUMAN: smoke test 30-second clip with several clear pauses — confirm in engine logs that ≥3 partial_result messages are sent in monotonic chunk_id order, and the final one has is_final:true
- [ ] [general] HUMAN: smoke test 3-minute clip — confirm no duration_exceeded error, confirm final concatenated text is coherent and complete
- [ ] [general] HUMAN: smoke test 10-minute clip (previously impossible) — confirm session completes and text is produced; measure time from hotkey release to text pasted (expect a few seconds regardless of total length)
- [ ] [general] HUMAN: smoke test single syllable ("да") released immediately — confirm one final partial with the text, no queue backlog, countdown shows ≤1 sec
- [ ] [general] HUMAN: smoke test abort mid-speech via Escape key — confirm worker thread exits cleanly, chunk queue is drained, no orphan partial_result arrives after the abort
- [ ] [general] HUMAN: smoke test kill engine mid-inference — confirm Swift client recovers via existing crash-handler path without hanging
- [ ] [general] HUMAN: visually verify countdown decrement after hotkey release — confirm smooth decrement from ~N down to 0, no stutter, no going negative
- [ ] [general] HUMAN: commit any final tweaks discovered during manual smoke testing
