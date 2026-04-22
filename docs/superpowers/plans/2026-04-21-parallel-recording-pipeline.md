# Parallel Recording Pipeline — Tero Enriched Plan

**Goal:** Eliminate the "warm-up" first-recording failure and back-to-back session failures by decoupling audio capture from engine state via a ring buffer, and add live partial transcription display.

**Spec:** `docs/superpowers/specs/2026-04-21-parallel-recording-pipeline-design.md`

---

## Phases
- Phase 1: "Engine Preload Fix" → steps 1-6
- Phase 2: "Engine Binary Deploy" → steps 7-9
- Phase 3: "Swift Poll Timeout" → steps 10-15
- Phase 4: "AudioRingBuffer TDD" → steps 16-23
- Phase 5: "AudioPipeline State Machine" → steps 24-28
- Phase 6: "AudioPipeline Consumer" → steps 29-33
- Phase 7: "AudioSession Migration" → steps 34-39
- Phase 8: "AppDelegate Integration" → steps 40-49
- Phase 9: "Bug Fix Audit" → steps 50-54
- Phase 10: "Phase 2 Monitor Removal" → steps 55-61
- Phase 11: "Feature Flag Cleanup" → steps 62-66
- Phase 12: "SubtitlePanel Component" → steps 67-70
- Phase 13: "SubtitlePanel Wiring" → steps 71-74
- Phase 14: "Live Subtitle Diagnosis" → steps 75-81
- Phase 15: "Human Verification" → steps 82-87

## Steps
1. [devops] Delete preload_thread_ field declaration from engine/src/ipc/server.h line 38
2. [devops] Remove preload_thread_ launch block (lines 97-110) from engine/src/ipc/server.cpp
3. [devops] Remove preload_thread_.join() block (lines 276-278) from engine/src/ipc/server.cpp stop()
4. [architect] Add engine.ensure_loaded() + g_interrupted check before IpcServer construction in engine/src/main.cpp (inside try block)
5. [devops] Run cmake --build build to verify engine compiles with zero errors
6. [devops] Commit C++ synchronous model preload before socket bind
7. [devops] Find app bundle location of openverb-engine via find command
8. [devops] Copy engine/build/openverb-engine into app bundle destination
9. [devops] Commit updated bundled engine binary
10. [tdd-guide] Write failing test testEnsureRunningPollDeadlineIs30Seconds in EngineManagerTests
11. [tdd-guide] Run the new test to confirm it fails (red)
12. [refactor] Update EngineManager.swift poll deadline 5s→30s and error messages at lines 272, 283, 617
13. [tdd-guide] Run the test to confirm it passes (green)
14. [tdd-guide] Run full swift test suite to confirm no regressions
15. [devops] Commit extend ensureRunning poll timeout to 30 s
16. [tdd-guide] Write failing AudioRingBufferTests for write/read/timeout/invalid-handle
17. [tdd-guide] Run AudioRingBufferTests to confirm type-not-found failure
18. [architect] Create AudioRingBuffer.swift with os_unfair_lock, withCheckedContinuation, single-fire timeout Task
19. [tdd-guide] Run AudioRingBufferTests to confirm all three scaffold tests pass
20. [devops] Commit AudioRingBuffer scaffold with write/readNext/markStart/clear
21. [tdd-guide] Write overflow + concurrent correctness tests (testOverflowDrops, testClearWakesBlocked, testConcurrent)
22. [tdd-guide] Run AudioRingBufferTests with overflow and concurrent tests to confirm pass
23. [devops] Commit ring buffer overflow and concurrent correctness tests
24. [tdd-guide] Write failing AudioPipelineTests for state transitions (idle/capturing/cancel)
25. [tdd-guide] Run AudioPipelineTests to confirm type-not-found failure
26. [architect] Create app/OpenVerb/Pipeline/AudioPipeline.swift with @MainActor state machine scaffold
27. [tdd-guide] Run AudioPipelineTests to confirm all six state machine tests pass
28. [devops] Commit AudioPipeline state machine
29. [refactor] Expose socketPath in EngineManager by removing private keyword on line 62
30. [architect] Replace AudioPipeline.swift entirely with full streamLive implementation (async contextProvider, detached consumer, error recovery)
31. [devops] Run swift build to check for compile errors after AudioPipeline replacement
32. [tdd-guide] Run full swift test suite to confirm state machine tests still pass
33. [devops] Commit streamLive consumer coroutine
34. [architect] Add USE_RING_BUFFER_PIPELINE feature flag to Constants.swift
35. [tdd-guide] Write failing testAudioSessionWritesToRingBufferWhenFlagEnabled source-scan test
36. [tdd-guide] Run the new AudioSession test to confirm it fails
37. [refactor] Refactor AudioSession.swift to write to AudioRingBuffer with OSAllocatedUnfairLock-protected handle and nil-guard
38. [tdd-guide] Run AudioSessionTests to confirm all pass including new ring buffer path
39. [devops] Commit AudioSession migration to AudioRingBuffer with feature flag on
40. [architect] Add lazy AudioRingBuffer and AudioPipeline properties to AppDelegate
41. [refactor] Extract handleResult(text:command:) sync method from drainResult .result case
42. [architect] Wire audioPipeline.onResult/onError callbacks and async contextProvider with ContextBuilder.build
43. [refactor] Extract scheduleMaxDurationTimer() private method from connectAndRecord around lines 756-770
44. [refactor] Replace startRecording() body to use audioPipeline.beginRecording and remove isDraining/drainGeneration
45. [refactor] Replace stopRecording() body to use audioPipeline.endRecording and remove drain task
46. [refactor] Replace handleCancel and abortAndRestart cancel paths with audioPipeline.cancel and delete drainResult function entirely
47. [devops] Run swift build to verify AppDelegate integration compiles
48. [tdd-guide] Run full swift test suite after AppDelegate integration
49. [devops] Commit wire AudioPipeline into AppDelegate
50. [tdd-guide] Grep all Bug N comments in AudioSession/EngineClient/EngineManager/OpenVerbApp
51. [refactor] Classify each bug comment as remove/port/delete in inline comments or commit message
52. [tdd-guide] Add prove_bug16_staleHandleIsNoOp and prove_bug81_doubleStopIsNoOp negative tests
53. [tdd-guide] Run full test suite with new negative tests included
54. [devops] Commit negative tests for bugs 16 and 81 under AudioPipeline
55. [refactor] Grep Phase 2 monitor code in EngineClient.swift to identify deletion scope
56. [refactor] Delete Phase 2 monitor code from EngineClient.swift (phase2Error/phase2Lock/wakeRead/wakeWrite/runPhase2Monitor/startPhase2/stopPhase2/callOnErrorIfLive)
57. [refactor] Remove startPhase2Monitor/stopPhase2Monitor call sites from OpenVerbApp.swift and EngineManager.swift
58. [tdd-guide] Update or delete negative tests for bugs 17, 27, 28 that scan for removed Phase 2 monitor code
59. [devops] Run swift build to verify removal compiles
60. [tdd-guide] Run full swift test suite
61. [devops] Commit remove Phase 2 monitor from EngineClient
62. [refactor] Delete USE_RING_BUFFER_PIPELINE line from Constants.swift
63. [refactor] Replace all Constants.USE_RING_BUFFER_PIPELINE if/else in AudioSession with true-branch content
64. [tdd-guide] Replace testAudioSessionWritesToRingBufferWhenFlagEnabled with testAudioSessionDoesNotUsePreBuffer
65. [devops] Run swift build and swift test to confirm clean after flag removal
66. [devops] Commit remove USE_RING_BUFFER_PIPELINE feature flag
67. [architect] Add showSubtitlePanel Key constant and @Published property to AppSettings with safe bool accessor
68. [designer] Write SubtitlePanel.swift with floating NSPanel, wantsLayer+clear background, addChildWindow ordered above, deinit cleanup, animation modifier
69. [devops] Run swift build to verify SubtitlePanel compiles
70. [devops] Commit SubtitlePanel for live partial transcription display
71. [frontend-dev] Add SubtitlePanel property to RecordingWindow and call setup in init
72. [frontend-dev] Wire show/hide SubtitlePanel with RecordingWindow.show/hide
73. [devops] Run swift build and swift test after SubtitlePanel wiring
74. [devops] Commit wire SubtitlePanel into RecordingWindow
75. [refactor] Add logger.debug instrumentation before onPartialResult call in EngineClient
76. [refactor] Grep existing onPartialResult and livePartialText wiring in AppDelegate
77. [architect] Verify AppState.livePartialText is @Published and SubtitleView observes it
78. [tdd-guide] Write testLivePartialTextUpdatesFromPartialResult integration test
79. [tdd-guide] Run partial result test and diagnose wiring vs engine-side issue
80. [refactor] Fix identified root cause of live subtitle wiring (closure assignment or actor isolation)
81. [devops] Commit fix live subtitle path wiring
82. [general] HUMAN: Open Xcode and add AudioRingBuffer.swift, Pipeline/AudioPipeline.swift, SubtitlePanel.swift to OpenVerb app target, then run ov to confirm BUILD SUCCEEDED
83. [general] HUMAN: Launch fresh app, press hotkey immediately, speak 5s sentence, verify transcript contains beginning of utterance and ensure_loaded log appears before ipc listening
84. [general] HUMAN: Perform 5 consecutive recordings without pause, verify all 5 produce non-empty transcripts
85. [general] HUMAN: Start recording, speak 3+ seconds, verify SubtitlePanel appears below recording HUD and accumulates text live
86. [general] HUMAN: Search logs after recordings under 5 min for AudioRingBuffer overflow, confirm zero occurrences
87. [general] HUMAN: Update bugs.md to reflect any bug comments removed without regression test
