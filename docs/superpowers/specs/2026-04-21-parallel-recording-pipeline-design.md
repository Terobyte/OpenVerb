# Parallel Recording Pipeline — Design Spec

**Date:** 2026-04-21
**Status:** Approved (pending spec review)
**Scope:** Decouple audio capture from engine state to eliminate "warm-up" and back-to-back session failures, while preserving live partial transcription.

---

## Overview

### Problem Statement

OpenVerb currently exhibits two user-visible recording failures:

1. **First recording "warm-up" failure.** After app launch, the first recording consistently loses audio from the beginning of the utterance. When model load exceeds ~3 s, the audio pre-buffer (capped at 24 chunks / ~3 s) evicts the oldest samples, so only the tail end of the user's speech reaches the engine.

2. **Intermittent second-recording failure.** Approximately every second recording fails with an engine error. Multiple race conditions in the current Phase 2 monitor and `isDraining` re-entrancy guard create windows where session N+1 reads state from session N.

### Root Causes

1. **--listen mode does not call `engine.ensure_loaded()` at engine startup.** `main.cpp:148-150` only constructs the `Engine` and starts the IPC server — model loads lazily on the first `session.start`. Swift's `tryPing()` succeeds as soon as the socket binds, which happens before the model is loaded. Result: the Swift side reports `status = .running` while the engine still takes 5–10 s before it can respond to the first real session.

2. **Tight coupling of audio capture to engine state.** `AudioSession` holds a capped `preBuffer` (24 chunks) that accumulates audio before `session.ready`. The cap was added as Bug 142 to prevent unbounded growth during slow cold starts — it inadvertently created a "silent audio loss" failure mode.

3. **Phase 2 monitor race conditions.** `EngineClient.startPhase2Monitor` resets `phase2MonitorStopped = false` before the previous session's detached monitor task has exited, which lets the stale task read from the new session's socket. Combined with `isDraining`/`drainGeneration` re-entrancy guards in `AppDelegate`, the state machine allows session N+1 to observe N's residual state.

### Design Goals

1. **100 % capture guarantee** for audio within app control (process alive, microphone healthy, AVAudioEngine nominal).
2. **Zero audio loss during model cold-load.** First recording after launch contains the user's full utterance.
3. **Deterministic session isolation.** Session N+1 cannot be influenced by session N's residual state.
4. **Live partial transcription preserved.** Partial results flow from engine to UI during recording and inferring, as before (but more reliably).
5. **Simpler code.** Net effect: remove more code than added. Remove detached-task concurrency in favor of a single state machine.

---

## Core Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Model pre-warm strategy | Add `engine.ensure_loaded()` in `main.cpp:--listen` before `server.start()` | One-line C++ change. Inverts the lazy-load invariant: socket binding implies "model ready". No Swift dummy-session plumbing needed. |
| Swift `ensureRunning` poll timeout | 5 s → 30 s | Engine now blocks on `ensure_loaded()` (5–10 s) before accepting connections. Poll must outlast the load. |
| Audio buffer | New `AudioRingBuffer` (RAM, 60 s, ~2 MB) | Producer/Consumer decoupling. `AudioSession` writes; `AudioPipeline` reads from timestamp. No cap-induced audio loss. |
| Buffer persistence | In-memory only | Disk-backed persistence (option C in brainstorm) deferred as overkill. 99.99 % capture guarantee acceptable; 100 % requires disk which adds privacy concerns and complexity. |
| Consumer model | Tail-follow reader, live streaming | Replaces `preBuffer` + `flushPreBuffer` + `commitSendCallback` + `sendCallback`. Chunks flow to engine as soon as they arrive in buffer. Live `partial_result` behavior preserved. |
| Error detection | `AudioPipeline` message-receive loop | Replaces `EngineClient.Phase 2 monitor` (detached Task + shared mutable flags). Single-threaded state machine, easier to reason about. |
| Live subtitle | New `SubtitlePanel` NSPanel below `RecordingWindow` | User reports existing live subtitle never worked. New dedicated panel with 16 pt text, no truncation. Diagnose existing path in parallel. |
| Session isolation | `AudioPipeline` handle per session | Session N receives a unique handle; reads/writes gated on handle. Prevents cross-session state reads. Replaces `drainGeneration` / `isDraining` guards. |
| Migration | 9 phased PRs, feature flag on Phase 5 | Each phase leaves app in working state. Feature flag on the risky `AudioSession` migration allows kill-switch rollback. |

---

## Architecture

### High-level

```
┌────────── Producer ──────────┐      ┌────────── Consumer ──────────┐
│                              │      │                              │
│  AVAudioEngine.tap           │      │  AudioPipeline.streamLive()  │
│        │                     │      │    (tail-follow reader)      │
│        ▼                     │      │         │                    │
│  AudioRingBuffer (60s, RAM)  │◄─────┤  reads from t_start           │
│        ▲                     │      │         │                    │
│        │ timestamped chunks  │      │         ▼                    │
│  AudioSession.start()        │      │  EngineClient.sendAudioFrame │
│                              │      │         │ (each chunk live)  │
│                              │      │         ▼                    │
│                              │      │  engine → partial_result     │
│                              │      │  onPartialResult → livePartialText
│                              │      │         │                    │
│                              │      │         ▼                    │
│                              │      │  SubtitlePanel (new UI)      │
└──────────────────────────────┘      └──────────────────────────────┘
         producer ↕ consumer are independent in time

╔══════════════ Engine pre-warm (one-line fix) ══════════════╗
║  main.cpp --listen block, between Engine(cfg) and server.start:
║    engine.ensure_loaded();       // blocks 5-10 s at startup
║    // socket bound AFTER model in RAM → tryPing=true ⇔ model hot
╚═════════════════════════════════════════════════════════════╝
```

### Components

| Component | Status | Responsibility |
|-----------|--------|----------------|
| `AudioRingBuffer` | new | Thread-safe ring buffer of PCM chunks with timestamps. Write-only for audio thread; timestamp-indexed read for consumer. Overflow drops oldest with log. |
| `AudioSession` | modified | Pure producer. Keeps `AVAudioEngine` + `AVAudioConverter`. Writes chunks to `AudioRingBuffer` and invokes waveform callback. No more `preBuffer`, `sendCallback`, `flushPreBuffer`, `commitSendCallback`, `syncOnIOQueue`. |
| `AudioPipeline` | new | Orchestrator. Owns state machine (idle / capturing / streaming / finalizing / error). Beginning a recording allocates a unique handle; all reads/writes gated on handle. Runs tail-follow consumer that streams chunks to `EngineClient`. Handles engine errors and user cancels without losing buffered audio. |
| `SubtitlePanel` | new | Separate `NSPanel` positioned directly below `RecordingWindow`. Renders `AppState.livePartialText` at 16 pt, no truncation, auto-scroll on overflow. Visible during `.recording` and `.inferring`. Toggleable via `AppSettings.showSubtitlePanel` (default true). |
| `EngineClient` | simplified | Remove Phase 2 monitor entirely (~120 lines deleted: `startPhase2Monitor`, `stopPhase2Monitor`, `runPhase2Monitor`, `callOnErrorIfLive`, `phase2Error`, `phase2Lock`, `phase2MonitorStopped`, `phase2MonitorTask`, `wakeRead`, `wakeWrite`). Error detection moves to `AudioPipeline`'s receive loop. |
| `EngineManager` | small change | `ensureRunning` poll timeout 5 s → 30 s. |
| `AppDelegate` (`OpenVerbApp.swift`) | simplified | `connectAndRecord` loses `flushPreBuffer`, `syncOnIOQueue`, `startPhase2Monitor` calls — replaced by `AudioPipeline.beginRecording` + `streamLive`. `stopRecording` loses `stopPhase2Monitor`, `drainGeneration`, `isDraining` (AudioPipeline owns re-entrancy via handle). |
| `RecordingWindow` (`UI/RecordingWindow.swift`) | small change | Creates and positions `SubtitlePanel` on initialization. Shows/hides panel in sync with recording state. |
| `AppSettings` | +1 flag | `showSubtitlePanel: Bool = true`. |
| `main.cpp` (engine) | +1 line | `engine.ensure_loaded();` before `server.start(cfg.socket_path);` in the `--listen` block. |

### AudioPipeline state machine

```
       ┌─────────┐
       │  idle   │
       └────┬────┘
            │ beginRecording() → handle H
            ▼
       ┌──────────────┐
       │  capturing   │ ← AudioSession writes to RingBuffer.
       │              │   Consumer awaits engineStatus == .ready.
       └────┬─────┬───┘
            │     │ engine ready & session started
            │     ▼
            │ ┌────────────┐
            │ │ streaming  │ ← Consumer tail-follows RingBuffer,
            │ │            │   sends chunks to engine live.
            │ └─────┬──────┘   Live partials flow back via onPartialResult.
            │       │
            │       │ endRecording(H) (user ⌥Space / Stop)
            │       ▼
            │ ┌────────────┐
            │ │ finalizing │ ← AudioSession stopped; consumer drains
            │ │            │   buffer tail, sends sentinel, awaits .result.
            │ └─────┬──────┘
            │       │ result received
            │       ▼
            │ ┌─────────┐
            └─┤  idle   │ ← buffer cleared for handle H.
              └─────────┘
                    ▲
           error ▲  │ cancel(H) from any state → idle
                 │  │
       ┌─────────┴──┐
       │   error    │ ← engine crashed / connection lost.
       │            │   Buffer retained. retry() possible.
       └────────────┘
```

State transitions are atomic, guarded by a single `os_unfair_lock`. No detached Tasks with shared mutable flags.

### Pre-warm sequence

```
applicationDidFinishLaunching
    ▼
Task { engineManager.ensureRunning() }
    ├─ spawn openverb-engine --listen
    │   Engine process:
    │     Engine engine(cfg);
    │     engine.ensure_loaded();       ← NEW LINE — blocks 5-10 s
    │     IpcServer server(engine, timeout);
    │     server.start(socket_path);    ← socket bound only now
    ├─ poll socket (up to 30 s) via tryPing
    └─ status = .running (model is loaded AND socket is alive)
    ▼
User ⌥Space any time:
    ├─ audioSession.start + AudioPipeline.beginRecording(handle H)
    ├─ AppState: .idle → .preparing → .recording (immediate)
    └─ if status == .running → session.start → .ready almost instant
       if status == .starting → AudioPipeline waits, RingBuffer accumulates
```

Invariant: `engineManager.status == .running` ⇔ model is loaded into Engine RAM and socket is accepting connections.

Edge case: **memory-pressure forced unload.** If macOS signals critical memory pressure, `IpcServer` may force-unload the model. Next `session.start` will trigger lazy `ensure_loaded()` → brief warm-up on that specific session. `RingBuffer` ensures no audio is lost. Acceptable on 16 GB+ Macs (the target hardware).

---

## Data Flow

### Happy path — second recording (back-to-back with first)

```
Precondition: app running, model hot, previous session completed.
RingBuffer: empty. AudioPipeline: idle.

t=0.000 s  User presses ⌥Space.
           AppDelegate.handleHotkeyToggle()
           ├─ AppState: .idle → .preparing
           ├─ audioSession.start()                     // AVAudioEngine.start() ~100 ms
           │   └─ tap installed, feeds AudioRingBuffer
           ├─ AudioPipeline.beginRecording() → handle H2
           │   └─ state: idle → capturing, markStart(H2, t=0)
           ├─ AppState: .preparing → .recording         // immediate!
           └─ Task { await streamPipeline(H2) }

t=0.100 s  AVAudio tap: first 4096-byte chunk
           └─ AudioRingBuffer.write(chunk, ts=0.1, handle=H2)

t=0.120 s  streamPipeline(H2):
           ├─ engineClient.connect(socket)             // fast (engine alive)
           ├─ engineClient.startSession(realContext)
           ├─ receiveMessage(.ready)                   // ~50 ms (model hot)
           └─ AudioPipeline.beginStreaming(H2)
              └─ state: capturing → streaming

t=0.175 s  Consumer loop:
           loop:
             chunk = RingBuffer.readNext(H2)           // blocks ≤200 ms
             engineClient.sendAudioFrame(chunk)

t=0.400 s  Engine VAD segment complete → inference
t=0.450 s  Engine → partial_result { text: "привет" }
           ├─ EngineClient.receiveMessage returns
           ├─ onPartialResult → livePartialText += "привет"
           └─ SubtitlePanel renders "привет"            // live visible

t=0.900 s  Engine → partial_result { text: "привет, как" }
...

t=3.500 s  User presses ⌥Space (stop).
           AppDelegate.stopRecording()
           ├─ AppState: .recording → .inferring
           ├─ audioSession.stop()
           └─ AudioPipeline.endRecording(H2)
              ├─ state: streaming → finalizing
              ├─ markEnd(H2, ts=3.5)
              └─ consumer drains tail, sends sentinel

t=3.700 s  Consumer sends sendEndOfAudio(). Awaits .result.
t=4.200 s  Engine → result { text: "привет, как дела" }
           ├─ TextInjector.inject(text, targetApp)
           ├─ engineManager.disconnect()
           ├─ AudioPipeline state: finalizing → idle (clears buffer for H2)
           └─ AppState: .inferring → .idle
```

### Edge case — hotkey pressed during engine cold-start

```
t=0.0 s   App just launched; engine loading model in background.
          engineManager.status == .starting.

t=2.0 s   User presses ⌥Space.
          AudioSession.start()                         // mic on; RingBuffer fills
          AudioPipeline.beginRecording() → H1          // state: capturing
          AppState: .preparing → .recording            // UX says "recording" immediately

t=2.1 s   tap writes chunk @ ts=0.1 to RingBuffer(H1)
t=2.3 s   more chunks accumulate in buffer
...

t=5.0 s   engineManager.status → .running              // model finished loading
          AudioPipeline observes status change:
            engineClient.startSession(context)
            receiveMessage(.ready)                     // fast; model hot
            state: capturing → streaming
            consumer burst-sends all buffered chunks from H1.start
            live partials begin flowing

t=5.5 s   SubtitlePanel shows first partial_result
...
```

No audio is lost. User sees slightly delayed partial text but the full utterance is transcribed.

### Error path — engine crash mid-recording

```
State: streaming. Engine alive. Consumer writing chunks.

Engine process SIGKILL (or memory pressure OOM).

Consumer:
  engineClient.sendAudioFrame returns write-error (EPIPE).
  OR engineClient.receiveMessage returns connectionClosed.
  
AudioPipeline:
  state: streaming → error
  retain buffer contents
  Task { engineManager.handleCrash() }                 // existing logic
    → respawn engine → ensure_loaded() → socket bind
    → engineManager.status = .running (model hot again)

AudioPipeline (after recovery):
  reconnect via engineClient.connect + startSession
  receive .ready
  resume consumer from last-sent-timestamp in RingBuffer(H)
    (continues streaming chunks that accumulated during downtime)
  state: error → streaming

User notices a brief pause in live subtitle but the utterance completes.
```

---

## Error Handling

| Event | Producer (AudioSession) | Consumer (AudioPipeline) | UI |
|-------|-------------------------|---------------------------|----|
| Engine crash mid-recording | keeps writing buffer | detects connection_closed → state: streaming → error; triggers handleCrash | subtitle: "Engine restarting…" |
| After crash recovery completes | still writing | retry() → reconnect → resend buffer from last-sent-ts | subtitle: resumes with partials |
| User presses Escape | audioSession.stop() | cancel(H) → disconnect → idle; RingBuffer cleared for H | window hides |
| RingBuffer overflow (speech > 60 s) | drop oldest chunk + log WARN | unaffected | optional "max duration reached" toast |
| User ⌥Space during cold-start | starts as usual | waits for engineStatus == .running; buffer accumulates | normal recording UI; slight result delay |
| Memory pressure unloads model | keeps writing | next session.start triggers lazy reload; +5-10 s on that session only | unchanged |
| Microphone permission denied | start() throws | state → error; cancel(H) | NSAlert + link to Settings |
| AVAudioEngine hardware failure | start() throws | state → error | AppState: .error("Microphone unavailable") |

---

## Testing Strategy

### Unit tests

| Test | Behavior |
|------|----------|
| `AudioRingBuffer.writeRead_preservesOrder` | Chunks read back in written order |
| `AudioRingBuffer.overflow_dropsOldest` | Capacity exceeded → oldest evicted |
| `AudioRingBuffer.readFromTimestamp_returnsOnlyNewer` | `readFrom(t=5.0)` excludes chunks written at t<5.0 |
| `AudioRingBuffer.concurrentWriteRead_noCorruption` | 1000 writes + 1000 reads from different threads → all data intact |
| `AudioPipeline.beginRecording_allocatesHandle` | Unique handle; state == capturing |
| `AudioPipeline.engineCrash_retainsBuffer` | Mock engine error leaves buffer intact |
| `AudioPipeline.cancel_clearsHandle` | After cancel, handle invalid; buffer cleared |
| `AudioPipeline.backToBackSessions_noStateLeak` | Handle H2 cannot read data written for H1 |
| `AudioPipeline.retryAfterCrash_resumesFromLastSent` | After crash + recovery, resend resumes from correct timestamp |
| `EngineManager.ensureRunning_timeout30s` | Poll runs for 30 s before throwing `launchTimeout` |

### Integration tests (real engine)

| Test | What it proves | Target symptom |
|------|----------------|----------------|
| `IntegrationTwoBackToBackSessions` | Session 1 → result; Session 2 → result; both non-empty | Symptom 2 (every-second-fails) |
| `IntegrationFirstRecordingFullAudio` | Synthetic 5 s audio injected immediately after launch → transcript contains beginning | Symptom 1 (warm-up) |
| `IntegrationModelIdleUnload` | Force `unload_model()` → next session lazy-reloads → audio not lost | Memory-pressure edge case |
| `IntegrationEngineCrashRecovery` | SIGKILL engine mid-recording → AudioPipeline retries after respawn | Crash resilience |
| `IntegrationLivePartialsFlow` | 3 s synthetic speech → `onPartialResult` callback fires ≥1 time; `livePartialText` accumulates | Live-subtitle diagnosis |

### Negative tests

Continue the `OpenBugsNegativeTests.swift` pattern. Each migrated "Bug N:" fix receives a `prove_bug_N_stays_fixed` test in the new context. New invariants get new negative tests (e.g., `prove_ring_buffer_does_not_drop_during_model_load`).

---

## Phased Migration

Each phase leaves the app in a working state. PRs can be merged independently.

| # | Phase | Files touched | Mergeable independently |
|---|-------|---------------|-------------------------|
| 1 | Engine pre-warm | `engine/src/main.cpp` (+1 line), rebuild binary | Yes — immediate relief for symptom 1 |
| 2 | Swift timeout bump | `EngineManager.swift` (5s → 30s) | Yes — pairs with Phase 1 |
| 3 | AudioRingBuffer | new file + unit tests | Yes — TDD, pure data structure |
| 4 | AudioPipeline skeleton | new file + state machine + unit tests with mocks | Yes — no integration yet |
| 5 | AudioSession migration | `AudioSession.swift` refactor | Yes, behind `USE_RING_BUFFER_PIPELINE` feature flag in `Constants.swift` for rollback safety |
| 6 | AudioPipeline integration | `AppDelegate.connectAndRecord` uses AudioPipeline | Yes — Phase 2 monitor still coexists |
| 7 | Remove Phase 2 monitor | `EngineClient.swift` cleanup | Yes — after Phase 6 proven stable |
| 8 | SubtitlePanel | new file + `RecordingWindow.swift` wiring | Yes — independent of phases 3-7 |
| 9 | Live-subtitle diagnosis | instrumentation + root-cause fix if needed | Yes — independent |

**Recommended merge order:**
- PR 1: Phases 1+2 (engine fix + Swift timeout) — ship first, gets biggest UX win fastest
- PR 2: Phase 3 (AudioRingBuffer)
- PR 3: Phase 4 (AudioPipeline)
- PR 4: Phase 5 (AudioSession migration, feature flag on)
- PR 5: Phase 6 (integration)
- PR 6: Phase 7 (Phase 2 monitor removal; remove feature flag)
- PR 7: Phase 8 (SubtitlePanel)
- PR 8: Phase 9 (live-subtitle diagnosis)

Phases 8 and 9 can run in parallel with phases 3-7 if desired.

### Bug-fix audit (pre-Phase 6)

Affected files contain ~40 "Bug N:" comments (numbers up to 176 observed). Before Phase 6 integration, classify each:

| Category | Action |
|----------|--------|
| Still applicable in new architecture | Port comment + regression test |
| Obsolete (affected code removed) | Delete comment |
| Pattern-covered by new mechanism | Verify new code handles same case; add a negative test asserting the invariant |
| Engine-side (not in scope of this refactor) | Untouched |

This audit is a task within the implementation plan (`writing-plans`), not a prerequisite of this spec.

---

## Risks and Rollback

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| AudioSession migration breaks capture silently | Medium | High (audio loss) | Feature flag on Phase 5. Integration test `FirstRecordingFullAudio` must pass before flag flip. |
| Rebuilt engine not picked up by bundled binary | Low | Medium (runs old engine) | Rebuild checklist in PR description; `ov` shell function documented. |
| AudioPipeline state transitions have bugs | Medium | High | TDD — all transitions unit-tested before integration. |
| SubtitlePanel mispositioned on multi-monitor setup | Low | Low | Use `NSScreen.main`; observe screen configuration changes. |
| Memory-pressure unload breaks active session | Low | Medium | Integration test + AudioPipeline retry from buffer after reconnect. |
| Phase 2 monitor removal leaves dangling error path | Medium | High (silent engine errors) | Phase 7 only after Phase 6 verified in production for ≥1 week. Integration test `EngineCrashRecovery`. |
| 30 s poll timeout too long on slow hardware | Low | Low | Observable in logs; configurable via `AppSettings` if needed. |

### Rollback

Each phase is a single commit. `git revert <commit>` restores the previous phase.

- **Phase 1 (engine fix):** Fully self-contained. Revert is safe.
- **Phase 5 (AudioSession migration):** Feature flag in `Constants.swift` (`USE_RING_BUFFER_PIPELINE: Bool = true`). Flip to `false` to restore old path. Flag removed in Phase 7 cleanup.
- **Phase 7 (Phase 2 monitor removal):** Destructive — old code deleted. Before Phase 7, spend ≥1 week in "coexist" mode (Phase 6) to confirm AudioPipeline error detection is complete.

---

## Open Questions

Items deferred to implementation; tracked in the plan:

1. Bug-fix audit outcome for the ~40 "Bug N:" comments in affected files.
2. Root cause of current live-subtitle failure (instrument and discover in Phase 9).
3. Ring-buffer default capacity — is 60 s sufficient? Make configurable via `AppSettings.maxRingBufferSeconds`?
4. SubtitlePanel typography details — exact font size, weight, color; confirmed iteratively via user feedback.
5. Proactive memory-pressure recovery — add explicit ensure-loaded-on-pressure-signal, or lazy-reload on next session? Default: lazy reload.

---

## Done Criteria

The refactor is considered complete when:

- [ ] `IntegrationTwoBackToBackSessions` passes. Two consecutive recordings return non-empty transcripts.
- [ ] `IntegrationFirstRecordingFullAudio` passes. First recording after launch contains the beginning of the utterance.
- [ ] `IntegrationLivePartialsFlow` passes. `partial_result` messages reach `livePartialText` during speech.
- [ ] Manual test: launch app → wait ~10 s → ⌥Space → speak 5 s → ⌥Space → result is complete (no warm-up loss).
- [ ] Manual test: 5 consecutive recordings without pauses → all 5 produce non-empty results.
- [ ] `SubtitlePanel` shows live text during recording.
- [ ] `bugs.md` updated: any "Bug N:" comment not migrated is re-opened with explanation.
- [ ] All existing integration and unit tests pass (no regressions).
- [ ] Code review + spec review loop passed.

---

## Future Enhancements (out of scope)

- **Disk-backed persistence** (Option C from brainstorm). Would push capture guarantee from 99.99 % to 100 % (surviving app crash) but adds privacy considerations and complexity. Revisit if the current design shows real-world crash-related audio loss.
- **Editable transcript post-inferring.** User could open `SubtitlePanel` as a text field after `.inferring` completes, edit, and re-inject. Requires new interaction model and potential re-inference flow.
- **Adaptive ring-buffer sizing** based on available RAM.
- **Proactive model reload** after memory-pressure unload, detected via `NSProcessInfo` thermal/memory hooks.
