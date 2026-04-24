# OpenVerb HUD Redesign — Expanding Pod + Streaming Polish

Date: 2026-04-23
Status: Draft, revised after first review + 10-angle bug sweep
Reference mock: `docs/mocks/openverb-redesign-mock.html`
Reference product: Google AI Edge Eloquent (Gemma-powered, offline)

## Goal

Replace the center-screen recording HUD and the separate `SubtitlePanel` with
a single expanding "recorder pod" that:

1. Shows a **warming** state (amber dot + spinner ring + "Loading local
   engine…") while the engine loads the model.
2. Streams the raw ASR transcript inside the pod during recording — no
   separate subtitle window.
3. When the user stops, plays a **live correction animation** driven by a new
   streaming polish protocol from the engine: wrong words strike through,
   moss-green replacements fade in, one diff update per polish chunk, until
   the polish stream ends and the final text pastes into the target app.

Waveform visual is **not changed** — `WaveformView` is reused unmodified.

## Non-Goals (explicit)

Settings shown in the mock but not backed by real functionality are omitted
from this redesign:

- Start at login
- Show menu bar icon toggle (always on)
- Auto punctuation toggle (engine punctuates unconditionally)
- Microphone device picker
- Noise reduction toggle
- Save transcripts to folder

Behavioural out-of-scope:

- **Live polish during recording** (Level 2 from brainstorm). Engine still
  runs polish only after user stops.
- **Structural rewrites / filler-word removal** beyond what the existing
  polish prompt already does. Engine polish-prompt is not touched.
- **Feature flag / dual-HUD coexistence.** For a local macOS app without
  server-side flags, rollback = `git revert` + rebuild. The cost of
  maintaining two HUDs exceeds the benefit. Rollback confidence comes from
  unit tests + `ov_smoke` rather than from a runtime kill switch.

## Current state (what we build on)

**FSM** — `AppState` (`app/OpenVerb/State/AppState.swift`):
`idle → preparing → recording → inferring → (idle | error)`. All paths
`preparing → error`, `recording → error`, `inferring → error`, `error →
preparing`, `error → idle` already exist (AppState.swift:209-218). No FSM
changes in this design.

**Live text plumbing:**
- `AppState.livePartialText: String` — appended (`+=`) from each
  `partial_result` event during `.recording`/`.inferring`. Emissions are
  incremental, not revised in place.
- `AppState.polishedText: String?` — atomic; set once via
  `appState.setPolishedText(text)` when `polished_result` arrives.

**Engine protocol** — `app/OpenVerb/Engine/EngineProtocol.swift`:
- `.partialResult(text, chunkId, isFinal)` — streamed (EngineProtocol.swift:145).
- `.polishStarted` — emitted when polish pass begins
  (EngineProtocol.swift:39, decoded :163). This design keeps the event.
- `.polishedResult(text)` — atomic final (EngineProtocol.swift:166). This
  design **keeps** it as a fallback sentinel and **adds a new streaming
  event next to it**.

**HUD layer:**
- `RecordingWindow` (NSPanel 400×160, nonactivating, centered on mouse
  screen; `RecordingWindow.swift:35-76`).
- `SubtitlePanel` — **actively instantiated** in `RecordingWindow.init`
  (RecordingWindow.swift:75) and attached on `show()` (`:85-86`). **This is
  not dead code.** The redesign removes the instantiation and the `attach`
  call explicitly.
- `ProcessingViewModel` (`app/OpenVerb/UI/ProcessingView.swift:21`) — owned
  by `OpenVerbApp` (lazy, initialised `OpenVerbApp.swift:66,138`),
  `isPolishing` flipped in `ProcessingView.swift:91,95,108` from the
  `.polishStarted` event path (`Pipeline/AudioPipeline.swift:362`).
- `TextInjector` — clipboard + ⌘V paste; currently hides the pod internally
  (`TextInjector.swift:75`). This design keeps that coupling (see § Error
  handling); we audit it but do not refactor it now.

Engine does **not** emit warm-up progress. Warming UI is time-only
(indeterminate).

## State mapping (mock ↔ code)

| Mock `data-state` | `AppState.State` | Extra signal |
|-------------------|------------------|--------------|
| `warming`         | `.preparing`     | — |
| `recording`       | `.recording`     | — |
| `processing`      | `.inferring`     | `ProcessingViewModel.isPolishing == false` |
| `polishing`       | `.inferring`     | `ProcessingViewModel.isPolishing == true` (set by `.polishStarted`) |
| `done`            | UI-only overlay  | final polish chunk received, before pod hides |
| `error`           | `.error(...)`    | — |

**Priority when multiple phases overlap:** `.error` beats `.done`. If an
`.error` transition fires while the 400 ms "Inserted" overlay is on screen,
the overlay is cancelled immediately and the error HUD takes over.

**isPolishing drift safety:** `isPolishing` can desync from `AppState` if the
engine crashes after `.polishStarted` but before `.polishedResult`. The 3-second
polish stall timer (see § Error handling) force-clears `isPolishing` when it
fires, so the UI cannot hang in the polishing state.

## Architecture overview

```
RecordingWindow (NSPanel 400×320, nonactivating)
 └── RecordingContentView
      ├── PodHeader        dot + label + timer/percent + Stop
      ├── WaveformView     (unchanged)                visible in .recording
      ├── HUDLoadingBar    (unchanged)                visible in .inferring
      └── LiveStreamView                              collapsed when empty
           └── TokenChip...                           driven by animation ops
                                                     emitted by PolishDiffEngine
```

The `SubtitlePanel` instantiation and `attach` call are removed. The class
file stays for one release to avoid merging pain; a follow-up commit deletes
the file entirely.

### New component: `PolishDiffEngine` (pure logic, no SwiftUI)

Lives in `app/OpenVerb/Pipeline/PolishDiffEngine.swift`. Owns the LCS diff
and emits ordered animation operations. **Not a SwiftUI View** — testable
with plain XCTest without SwiftUI previews.

**Interface:**

```swift
@MainActor
final class PolishDiffEngine: ObservableObject {

    struct TokenState: Identifiable, Equatable {
        let id: UUID
        var display: String       // preserves original punctuation + case
        var normalizedKey: String // lowercase + stripped punctuation; used for LCS
        var status: Status        // .confirmed / .pending / .wrong / .correction / .polished
        var transientRemoval: Bool  // set briefly while fading out
    }

    enum Status { case confirmed, pending, wrong, correction, polished }

    @Published private(set) var tokens: [TokenState] = []

    /// Called when a raw ASR chunk arrives (during .recording).
    /// Appends new tokens as .pending; they auto-promote to .confirmed.
    func appendRaw(_ chunk: String)

    /// Called when a polish_delta chunk arrives. Runs bounded diff and
    /// emits ordered token mutations. Safe to call repeatedly with
    /// monotonically growing accumulated polish text.
    func applyPolishStream(_ accumulated: String)

    /// Called when polish stream ends (polish_delta done=true or legacy
    /// polished_result). Transitions all remaining tokens to .polished.
    func finalizePolish(_ finalText: String)

    /// Called when session ends (idle transition). Cancels all pending
    /// promotion/removal tasks and clears state.
    func reset()
}
```

**Concurrency model:**

- `appendRaw` and `applyPolishStream` are cheap path operations that run on
  MainActor.
- The **LCS computation** inside `applyPolishStream` is dispatched to a
  `Task.detached(priority: .userInitiated)` when either side exceeds 150
  tokens. The detached task returns a plain `Diff` struct; the result is
  applied back on MainActor. For short transcripts (≤150 tokens), the diff
  runs inline — the overhead of spinning a Task is worse than the diff
  itself. This keeps the MainActor unblocked per the §Memory & Performance
  finding.
- All promotion / removal delays are modelled as a single
  `TaskGroup` per session; `reset()` cancels the group so lingering
  `Task.sleep` calls cannot write into the next session's tokens. Addresses
  the "200+ Task.sleep without cancellation scope" finding.

### Component: `LiveStreamView` (thin view)

After extracting diff logic to `PolishDiffEngine`, the view is display-only.

```swift
struct LiveStreamView: View {
    @ObservedObject var diff: PolishDiffEngine
    let phase: Phase            // .warming | .recording | .processing | .polishing | .done | .error
    let errorMessage: String?   // only used in .error
}
```

The view reads `diff.tokens` and renders them with animations mapped to
`TokenState.status`. Animations themselves are CSS-inspired:

| Status      | Visual |
|-------------|--------|
| .confirmed  | neutral ink colour |
| .pending    | red-soft, ~260 ms; auto-promotes to .confirmed |
| .wrong      | red-dark + strike-through sweeping 180 ms; then fade out |
| .correction | moss-green bold; fades in; after 500 ms → .polished |
| .polished   | neutral ink, `is-polished` font-weight |

In `.warming`, the view ignores `diff.tokens` and shows a static "Loading
local engine…" line with a dots-loop.

### Diff normalization (addresses "false .wrong" finding)

**Normalized key** = lowercase + Unicode-punctuation-stripped + leading/
trailing whitespace trimmed.

```
"Hello,"       → "hello"
"Hello"        → "hello"   → LCS keeps both as match
"don't"        → "dont"
"do not"       → two tokens "do" and "not" (whitespace split after norm)
"  spaced  "   → "spaced"
```

If two tokens' normalized keys are equal, **the polished one wins the
display**: the `display` field on the surviving TokenState is replaced
with the polished variant (so "Hello" visually becomes "Hello," without
going through the `.wrong` animation). Only **content differences**
animate the strike-through. Case / punctuation / whitespace fixes just
swap the display string in-place.

This replaces the generic LCS-on-raw-tokens approach from the first
draft, which produced visual noise on every punctuation tweak.

### Streaming diff stabilization (addresses "thrashing" finding)

During polish streaming, an early chunk can make a token look wrong, then a
later chunk can prove it right again (e.g. raw `"A B C"`, polish chunk 1
`"A X"`, chunk 2 `"A X C"` — `C` would flicker to `.wrong` and back).

**Stabilization rule:** a raw-side token is marked `.wrong` only if it is
absent from the polish accumulator for at least **2 consecutive polish
chunks** (or if the stream has ended — `finalizePolish` forces marking).
Tokens flagged "probably wrong" in the interim are rendered with a soft
amber underline (not the red strike-through), giving the user a preview
without committing to the animation.

This is the one subtle piece of logic; `PolishDiffEngine` unit tests cover
it explicitly (see § Testing).

### Animation choreography (addresses "940 × 50 = 47 s" finding)

- Per-token animation: strike-through 180 ms + fade 260 ms + correction
  fade-in 320 ms + settle 200 ms ≈ 960 ms total end-to-end for one change.
- Multiple concurrent changes stagger **40 ms** apart. Visually this reads
  as a wave sweeping left-to-right rather than simultaneous chaos.
- **Total visual envelope is capped at 800 ms** regardless of change count.
  If the scheduler sees more changes than fit in 800 ms at 40 ms stride
  (i.e. >20), it drops the stagger and runs them in parallel with the
  per-token timing unchanged. A 50-change polish completes visually in
  ~1000 ms max, not 47 seconds.
- If a final `polished_result` arrives while animations are still running,
  the animations finish naturally (≤960 ms from the last scheduling point)
  before the pod hides. `TextInjector.inject` is gated on
  "animations settled" via a small signal on `PolishDiffEngine`.

### Warming UI

`HUDStatusDot` gains a `.warming` variant: amber fill + a rotating
`Circle().stroke()` ring (indeterminate, same pattern as
`ProcessingView.IndeterminateRing`). No percent label because the engine
does not emit warm-up progress.

On re-recording with an already-warm engine, `preparing` resolves to
`recording` in well under the 500 ms `preparingSubtitleDelay` (AppState.swift
already handles this); the warming visuals simply do not appear.

### "Done" overlay

- Triggered by polish-stream completion (`polish_delta.done == true` or
  legacy `polishedResult` fallback) after `PolishDiffEngine` reports
  animations settled.
- Visual: `HUDStatusDot` flips to moss-green; label changes to "Inserted";
  a small `.accessibilityAnnouncement` fires (see § Accessibility).
- Duration: **400 ms** (up from the 250 ms in the first draft; VoiceOver
  can't read 250 ms). Pod then hides; `TextInjector.inject` proceeds with
  the buffered final text.
- `.error` during the 400 ms window cancels the overlay immediately.

### PreferencesView redesign

Replace `TabView` with `NavigationSplitView` (macOS 13+; confirmed target
is `.v13` in `Package.swift:14`).

**Sidebar sections:**

| Section   | Rows |
|-----------|------|
| Recording | `showWaveform`, `showLiveTranscript`, `maxRecordingDuration` |
| Text      | `language`, `includeClipboard` |
| Shortcuts | Hotkey via existing `ShortcutRecorderView` |
| Backend   | `backend` picker, `modelDirectory` (browse) |
| **Reset** | **Bottom of sidebar**, outside the Backend section. Row label: *"Reset all settings..."*. Tap → confirmation sheet → calls existing `AppSettings.reset()`. |

The Reset row is explicitly separated because `AppSettings.reset()` wipes
*every* setting (hotkey, language, clipboard, waveform, backend,
modelDirectory — AppSettings.swift:297-326). Placing it inside the Backend
section in the first draft was misleading.

The `General` and `Audio` groups from the mock are omitted because they
have no real backing settings.

**Settings migration:**
- `settings.showLiveTranscript`: semantics clarified — now controls the
  in-pod `LiveStreamView` visibility exclusively. Users who had it ON keep
  seeing text (now in-pod). Users who had it OFF still see no text. No
  data migration needed; existing persisted values are read as-is.
- `settings.showSubtitlePanel`: UI toggle removed; the `AppSettings`
  property is **deleted** (not left orphaned). `AppSettings.init()` and
  `reset()` no longer reference the key. A one-time cleanup writes
  `defaults.removeObject(forKey: "app.settings.showSubtitlePanel")` on
  first launch of the new version to avoid leaving stranded keys in
  user defaults. Addresses the "orphaned setting" finding.

## Data flow — single source of truth

```
Engine subprocess
   │ partial_result (incremental)
   ▼
EngineClient.onPartialResult
   ▼
OpenVerbApp (@MainActor):
   appState.livePartialText += delta
   polishDiffEngine.appendRaw(delta)       ← drives LiveStreamView (via @ObservedObject)

─── user hits stop ───
AppState: .recording → .inferring
Engine: polish_started
   ▼
EngineClient.onPolishStarted
   ▼
OpenVerbApp:
   processingVM.startPolishing()           ← flips isPolishing → UI header = "Полирую…"
   startPolishStallTimer(timeout: 3s)      ← timer armed on polish_started, not on stop

Engine: polish_delta (streaming chunks)
   ▼
EngineClient.onPolishDelta
   ▼
OpenVerbApp:
   streamedPolish += chunk                 ← authoritative buffer; LIVES HERE
   resetPolishStallTimer()
   polishDiffEngine.applyPolishStream(streamedPolish)

   if done == true:
       stopPolishStallTimer()
       finalText = streamedPolish
       await polishDiffEngine.finalizePolish(finalText)
       await polishDiffEngine.waitAnimationsSettled()
       showDoneOverlay(duration: 400ms)
       // TextInjector.inject handles: pod hide + activate + paste
       await TextInjector.inject(text: finalText, targetApp: ..., window: ...)
       appState.transition(to: .idle)      ← LAST, after paste returns
       polishDiffEngine.reset()
```

**Single source of truth for polish text**: `streamedPolish` in
`OpenVerbApp`. `LiveStreamView` does **not** own a polish buffer; it reads
`PolishDiffEngine.tokens`. `AppState.polishedText` is **no longer written
during the streaming path** (only set once as a legacy fallback if a build
sends `polishedResult` without `polish_delta`). This removes the three-way
drift called out in the review.

## Engine change: streaming polish tokens

`EngineProtocol.EventType` gains:

```swift
case polishDelta(chunk: String, done: Bool)
```

Decoded from a new `type: "polish_delta"` JSON message with fields
`{ "chunk": String, "done": Bool }`. `EngineClient` gains
`onPolishDelta: (chunk, done) -> Void`.

The engine subprocess emits `polish_delta` per generated token group
(coalesced if the model is producing tokens faster than the pipe can
flush; no strict 1-token-1-message requirement). On polish completion it
emits a final `polish_delta` with `done == true`.

**Message volume**: a typical 200-word polish run yields 50–150
`polish_delta` messages. Each message is JSON-line (~40-80 bytes) through
the existing Unix-domain socket. Measured burst pressure against the
current `SO_SNDBUF` of 128 KiB (commit c125f24) is negligible. Pipe
throughput is not a concern.

**Legacy `polishedResult`**: the engine continues emitting it for one
release as a safety net. If a client receives `polishedResult` without any
preceding `polish_delta`, it is treated as a single-chunk stream with
`done == true`. After one release of confirmed-stable behaviour the
engine can drop the redundant event.

**Ordering guarantee**: the engine emits `polish_delta(done: true)`
*before* any final `polishedResult`. The client treats `polish_delta(done:
true)` as authoritative; a later `polishedResult` is ignored (same text
anyway). If they disagree (shouldn't happen), `polish_delta` wins.

## Error handling

- **Engine crash after `polish_started`**: stall timer (§ below) fires →
  fallback pastes `appState.livePartialText` (best effort raw), shows
  transient `.error` with message "Polish failed, raw text pasted". Log
  warning.
- **Stall timer**: armed on `.polishStarted`, reset on every `polish_delta`.
  Fires after **3 seconds of silence** (no delta). Separately, if no
  `polish_started` arrives within 3 seconds of stop-hotkey, a fallback
  timer pastes the raw text and transitions to `.idle`. Addresses the
  "late polish_started" false positive finding.
- **`polish_delta` before `polish_started`**: treat as if
  `.polishStarted` arrived at the time of the first delta; flip
  `isPolishing` defensively. No animation lost.
- **`TextInjector.inject` failure** (target app quit, Accessibility
  revoked, secure field, activate() returned false): currently hides the
  pod silently. Redesign: before hiding the pod, set a 2-second error
  chip in `LiveStreamView` reading "Could not paste — text copied to
  clipboard" (the clipboard already contains the polished text at the
  moment of failure by construction of `TextInjector`). This gives the
  user a recovery path. The error chip is implemented by the view
  subscribing to a `@Published` `lastInjectError: InjectError?` on the
  controller. Addresses the "potential text loss" finding.
- **Diff worst case** (>500 tokens either side): skip the animation, do a
  150 ms crossfade of the whole stream to the final polished text. Also
  addresses the `tokens[]` memory cap concern — if cap trips, the view
  renders just the final polished text, not the full history.
- **String `+=` quadratic in `streamedPolish`**: accumulate into a
  `ContiguousArray<Character>` and bridge to `String` on each
  `applyPolishStream` call. For 200-token polish this is a non-issue;
  documented here for transcript-of-minutes length sessions.

## Accessibility

- `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` respected.
  When true: strike-through / fade / collapse animations are replaced
  with instant state changes; spinner becomes static dot.
- `NSAccessibility.post(element:, notification: .announcementRequested,
  userInfo: [.announcement: ...])` on major phase transitions:
  "Recording started", "Processing", "Polishing", "Inserted", "Error:
  <message>".
- Every `TokenState` status has a text label exposed via
  `.accessibilityLabel("corrected from 'lunch' to 'launch'")` for
  `.correction` state; VoiceOver rotor walk exposes the sequence.
- Colours are backed by text labels (not colour-only state). Bug 184's
  `.accessibilityLabel("Stop recording")` is already present; the new
  `LiveStreamView` and `HUDStatusDot` get labels too.
- **Non-goals** for accessibility in this design: custom VoiceOver rotors
  for token navigation, Braille display tuning.

## Platform & positioning

- Pod is positioned on the screen containing the **mouse cursor**
  (existing `recenterOnMouseScreen()` logic retained). Full-screen
  target apps: `.canJoinAllSpaces` collection behaviour (already set)
  makes the pod appear on whatever Space is foregrounded. Verified
  manually against Safari fullscreen and Stage Manager in smoke tests.

## Testing

**Unit** (extend `OpenVerbTests`):

- `PolishDiffEngineTests` — LCS diff correctness including:
  - Punctuation-only delta ("Hello," vs "Hello") emits *no* `.wrong` ops.
  - Case-only delta ("hello" vs "Hello") emits no `.wrong` ops.
  - Contractions ("don't" vs "do not") emits a single replace op (display
    "don't" → "do not") not three separate ops.
  - Whitespace normalisation (leading/trailing/multiple spaces).
  - Streaming composition: feed chunks sequentially, assert early-chunk
    safety (position > streamed length is not marked wrong).
  - Stabilization rule: a token that appears wrong at chunk N then
    correct at chunk N+1 is never visually marked `.wrong`.
  - >500-token input triggers crossfade path.
- `PolishDiffEngine_ConcurrencyTests` — `reset()` cancels pending
  promotion/removal tasks; post-reset no TokenState writes.
- `LiveStreamViewSnapshotTests` (ViewInspector or SwiftUI preview
  capture) — static renders for each phase.

**Integration / smoke** (extend `ov_smoke`):

- Cold start: warming visuals appear and resolve to recording.
- Warm start: warming does not flash.
- Polish stream completes → animations settle → paste happens.
- Polish stall → fallback paste of raw text + error chip.
- TextInjector failure (simulated via quit target app mid-session) →
  error chip visible, clipboard contains polished text.

**Regression** — existing `AppState` FSM tests unchanged (no FSM edits).
No `OpenBugsNegativeTests.swift` entries invalidated by this redesign.

## Rollout

Two commits on one PR (`hud-redesign`):

1. `engine`: add `polishDelta` event type, engine-side streaming emission,
   keep legacy `polishedResult` as fallback. `EngineClient.onPolishDelta`
   wired. No UI changes in this commit — `OpenVerbApp` logs the deltas but
   still consumes `polishedResult` for paste.
2. `ui`: `PolishDiffEngine`, `LiveStreamView`, `RecordingWindow` size
   bump and pod content rewiring, `SubtitlePanel` instantiation removal,
   warming visuals, `NavigationSplitView` Preferences, Reset relocation,
   accessibility announcements, settings migration (drop
   `showSubtitlePanel`).

No feature flag. Rollback = revert the PR and ship a new build. CI smoke
suite must pass before merge.

## Open risks (explicitly accepted)

- Engine change required; if engine team is mid-refactor, coordinate
  branch point before starting commit #1.
- LCS for 500-token transcripts: measured ~1-2 ms on modern hardware;
  acceptable even when inline. Validate in `ov_smoke`.
- Stage Manager + fullscreen: pod behaviour has not been exhaustively
  tested on every macOS 13–15 combination. Manual QA on each target OS
  before release.
- Accessibility: basic-tier implementation only. Deeper a11y (Braille,
  custom rotors) is a separate project.
