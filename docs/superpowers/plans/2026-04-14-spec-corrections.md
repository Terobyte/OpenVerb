# Spec Corrections: 10 Architecture Issues

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 10 contradictions and gaps in `docs/superpowers/specs/2026-04-13-openverb-architecture-design.md` before implementation begins.

**Architecture:** Direct edits to spec only. No source files touched.

**Tech Stack:** Markdown spec edits.

---

## Issue Summary

| # | Section | Problem | Severity |
|---|---------|---------|----------|
| 1 | MVP Phases | Commands split MVP1/3/5 — MVP5 name wrong | High |
| 2 | ProcessingView vs progress JSON | "not precise" contradicts progress percent | Medium |
| 3 | Phase 2 abort | No cancel gesture defined (only abort-by-disconnect) | High |
| 4 | WaveformView | Data source not specified — implies engine sends amplitude | Medium |
| 5 | MVP3 context | No Accessibility in MVP3 — tailoring won't work, not documented | High |
| 6 | Pre-buffer race | "Waiting for model load" UI state not described | Medium |
| 7 | ⌘V order | NSPanel focus order undefined — ⌘V will fire on panel | High |
| 8 | delete_last | No keystroke mapping defined for CommandExecutor | High |
| 9 | MVP3 model download | No model → app unusable; onboarding deferred to MVP5 | High |
| 10 | client/ vs app/ | No migration plan; duplication of EngineClient/Manager/Protocol | Medium |

---

## Chunk 1: MVP Phasing Issues (1, 5, 9, 10)

### Fix 1: MVP5 Commands phase rename + MVP3 clarification

**Problem:** MVP5 = "Commands + Distribution" but commands/parser is in MVP1 and CommandExecutor belongs in MVP3 (required for text injection). By MVP5, commands are already implemented. MVP5 should be "Distribution + Polish."

- [ ] **Edit MVP Phases section** — rename MVP5:

Current (line 678):
```
### MVP 5: Commands + Distribution (Weeks 18–22)
Voice commands. Preferences UI. Onboarding. `brew install --cask openverb` on clean Mac.
```
Replace with:
```
### MVP 5: Distribution + Polish (Weeks 18–22)
Preferences UI. Onboarding wizard. Homebrew cask. `brew install --cask openverb` on clean Mac.
Note: Voice command parsing (commands/parser.h/.cpp) ships in MVP1. CommandExecutor.swift
ships in MVP3 as part of text injection. MVP5 adds Preferences for command customization only.
```

- [ ] **Edit MVP3 description** — add CommandExecutor and command flow:

Current (line 672):
```
### MVP 3: Hotkey + UI + Text Injection (Weeks 11–14)
Full macOS UX: ⌥Space → waveform window → speak → ⌥Space → text at cursor in any app.
```
Replace with:
```
### MVP 3: Hotkey + UI + Text Injection (Weeks 11–14)
Full macOS UX: ⌥Space → waveform window → speak → ⌥Space → text at cursor in any app.
Includes: HotkeyManager, RecordingWindow, WaveformView, ProcessingView, TextInjector.swift,
CommandExecutor.swift (executes delete_last/undo/newline commands from engine result).
Context limitation: no Accessibility API (MVP4) — context JSON = {app: from NSWorkspace,
window: empty, clipboard: from NSPasteboard}. Prompt tailoring works but style = app-name
fallback only (no window title, no selected text). MVP3 is a functional but context-minimal
proof of the full injection pipeline.
```

- [ ] **Commit** — `git commit -m "fix: rename mvp5 to Distribution+Polish, clarify CommandExecutor in mvp3"`

---

### Fix 5: MVP3 context = context-less (Accessibility deferred to MVP4)

Already partially addressed in Fix 1. Add explicit data-flow note in the spec body.

- [ ] **Edit Context section** (after the ContextBuilder bullet in app structure) — add MVP phase note:

After `ContextBuilder.swift` line, add:
```
│                                    # MVP 3: collects app name (NSWorkspace.frontmostApp)
│                                    #   + clipboard (NSPasteboard). No Accessibility.
│                                    # MVP 4: adds AccessibilityReader for window title
│                                    #   and selected text. Context richness doubles.
│                                    # Graceful degradation is identical to Accessibility
│                                    #   denied: App name from NSWorkspace, Style from
│                                    #   app-name lookup, clipboard if permitted, no selection.
```

- [ ] **Commit** — `git commit -m "clarify: mvp3 context = nsworkspace+clipboard only, accessibility = mvp4"`

---

### Fix 9: MVP3 minimal model download

**Problem:** Onboarding (with model download UI) is MVP5. But MVP3 = first full UX that requires the model. Without a model the app is unusable.

- [ ] **Edit MVP3 description** — add model check requirement:

Append to MVP3 description:
```
Model requirement: MVP3 must include a minimal model check at app launch — before starting
the engine, EngineManager checks if the GGUF model exists at DEFAULT_MODEL_DIR. If missing:
show a modal alert "Model not found. Download it with: scripts/download-model.sh" and exit.
This is not the full Onboarding UI (MVP5) — just a blocking check with a CLI instruction.
ModelDownloader.swift is NOT included in MVP3 — it is introduced in MVP5 alongside
OnboardingView.swift. The download script from MVP1 covers developers; end-user download
experience is deferred.
```

- [ ] **Commit** — `git commit -m "fix: add model-missing check to mvp3, defer full onboarding to mvp5"`

---

### Fix 10: client/ → app/ migration contract

**Problem:** MVP2 creates `client/` (CLI Swift). MVP3 creates `app/OpenVerb/`. No plan for how EngineClient.swift, EngineManager.swift, EngineProtocol.swift migrate.

- [ ] **Edit MVP2 description** — add migration note:

Append to MVP2:
```
client/ is a throwaway prototype. The three IPC files (EngineClient.swift,
EngineManager.swift, EngineProtocol.swift) from client/ are the design reference for MVP3,
not copy-paste source. MVP3 rewrites them for app/OpenVerb/Engine/ with proper Swift
concurrency (async/await), Foundation stream abstractions, and SwiftUI state bindings.
The client/ directory is retained in the repo for reference but is NOT part of app/ build.
```

- [ ] **Add to app/OpenVerb/Engine/ directory structure** — clarify the IPC source:

In the file structure listing for `app/OpenVerb/Engine/`, add:
```
# Note: these are fresh implementations for the app, NOT copies from client/.
# client/ (MVP2 CLI prototype) serves as behavioral reference only.
# App versions use async/await, @MainActor, and ObservableObject patterns.
```

- [ ] **Commit** — `git commit -m "clarify: client/ is prototype, app/ rewrites ipc layer with swift concurrency"`

---

## Chunk 2: Protocol and Data Flow Issues (3, 4, 6)

### Fix 3: Phase 2 cancel gesture

**Problem:** Phase 2 (binary streaming) has no in-band cancel. Socket close = only abort mechanism. But spec defines only ⌥Space as toggle (finish → sentinel). No gesture defined for "cancel recording without finishing."

**Decision:** Escape key = cancel (discards audio, closes socket, resets to IDLE). ⌥Space = always confirm (sends sentinel). This is the cleanest mapping — two distinct keys, no ambiguity.

- [ ] **Edit Phase 2 abort rule** — add Escape gesture:

Current (line 130):
```
# PHASE 2 ABORT RULE: There is no in-band control channel during Phase 2
# (binary mode). To abort a session during streaming, the client MUST
# close the TCP/Unix socket connection.
```
Replace with:
```
# PHASE 2 ABORT RULE: There is no in-band control channel during Phase 2
# (binary mode). To abort a session during streaming, the client MUST
# close the Unix socket connection. Engine detects EOF/ECONNRESET, cancels
# buffered audio, resets to IDLE.
#
# User gestures:
#   ⌥Space (while recording) = CONFIRM — Swift sends zero-length sentinel → inference starts
#   Escape (while recording) = CANCEL — Swift closes socket → engine resets to IDLE, app hides window
#   ⌥Space (while inferring) = ABORT + restart — Swift closes+reconnects socket, starts new session
#
# No long-press or alternate hotkey for cancel. Escape is the universal macOS cancel gesture.
# HotkeyManager must register Escape as a local monitor during recording only
# (NSEvent.addLocalMonitorForEvents — does not require Input Monitoring permission for
# events in the app's own window; RecordingWindow being key window means local monitoring works).
```

- [ ] **Edit Data Flow section** — update step descriptions to include cancel:

After step 5 (User presses ⌥Space → recording OFF), add:
```
5b. [Alternative] User presses Escape → Swift closes socket connection → engine resets to IDLE
    → recording window hides → no result, no error shown. Audio discarded.
```

- [ ] **Edit HotkeyManager.swift entry** — add Escape documentation:

Append to HotkeyManager.swift line:
```
│                                    # Also: local Escape monitor during active recording
│                                    # (NSEvent.addLocalMonitorForEvents) — cancel gesture.
│                                    # Local monitor fires only when RecordingWindow is key.
```

- [ ] **Commit** — `git commit -m "fix: add escape=cancel gesture for phase 2 abort, distinct from altspace=confirm"`

---

### Fix 4: WaveformView data source

**Problem:** WaveformView = "Real-time audio amplitude" but engine never sends amplitude data back. Implies engine is the source.

- [ ] **Edit WaveformView.swift entry** (line 502):

Current:
```
│   ├── WaveformView.swift           # Real-time audio amplitude
```
Replace with:
```
│   ├── WaveformView.swift           # Real-time audio amplitude — drawn from LOCAL PCM chunks
│                                    # produced by AudioSession before they are sent to engine.
│                                    # Engine never sends audio data back. AudioSession calls
│                                    # waveform callback (Data) → WaveformView reads RMS amplitude.
│                                    # No IPC involvement — purely local tap on the audio pipeline.
```

- [ ] **Commit** — `git commit -m "clarify: waveformview draws from local pcm, not from engine"`

---

### Fix 6: Pre-buffer UI state — "Waiting for model load"

**Problem:** Pre-buffer design is correct (accumulates ~131KB during 4s model load). But spec doesn't describe what UI shows during this 4s cold-start window. User sees waveform but no indication of engine readiness.

- [ ] **Edit Data Flow section** — add model-loading UI state:

After step 2 (starts AVAudioEngine capture into pre-buffer), add:
```
2b. Swift sends session.start immediately (before model is ready — engine will respond with
    session.ready after model loads, up to 4s on cold start). During this window:
    - WaveformView IS animated (showing audio amplitude from pre-buffer, reassuring user)
    - ProcessingView NOT shown (inference hasn't started)
    - RecordingWindow title / subtitle: "OpenVerb — Preparing..." if no session.ready yet
      (detected by timeout: if session.ready not received within 500ms of session.start)
    - On session.ready: RecordingWindow title returns to normal recording state
    This prevents a 4s silent waveform that looks broken. The "Preparing..." state is
    transient and most users will see it only on the very first recording after a long idle.
```

- [ ] **Edit AppState.swift entry** — add PREPARING state:

Append to `AppState.swift` line:
```
│                                    # States: IDLE, PREPARING (session.start sent, no ready yet),
│                                    # RECORDING (session.ready received), INFERRING, ERROR
│                                    # PREPARING → RECORDING on session.ready; PREPARING →
│                                    # ERROR on timeout (30s model load timeout)
```

- [ ] **Commit** — `git commit -m "fix: add preparing ui state for cold-start model load window"`

---

## Chunk 3: Text Injection Issues (7, 8)

### Fix 7: NSPanel focus order for ⌘V

**Problem:** RecordingWindow (NSPanel) may be the key window when ⌘V is simulated. Keystrokes go to the key window — so ⌘V fires on the panel, not the target app.

**Fix:** Explicit ordered sequence in TextInjector.swift spec:

- [ ] **Edit Text Injection section** (lines 519–529):

Current:
```
Primary: clipboard simulation
1. Record `NSPasteboard.changeCount` and save current clipboard contents
2. Write result to clipboard
3. Simulate ⌘V (keydown + keyup via CGEvent)
4. After 300ms: restore original clipboard...
```
Replace with:
```
Primary: clipboard simulation — STRICT OPERATION ORDER (order is critical for focus):
1. Capture `targetApp: NSRunningApplication` — the frontmost app at the time ⌥Space was
   first pressed (captured in HotkeyManager, passed through AppState to TextInjector).
   Do NOT re-query frontmost app at injection time — RecordingWindow may be foreground by then.
2. Record `NSPasteboard.changeCount` and save current clipboard contents.
3. Write result text to clipboard.
4. `RecordingWindow.orderOut(nil)` — hide panel (removes it from screen, releases key status).
5. `targetApp.activate(options: [])` — bring target app to foreground. This is synchronous
   signal but focus transfer is async — proceed immediately without sleep.
6. Simulate ⌘V via CGEvent (kCGEventKeyDown/Up, keyCode 9, flags .maskCommand):
   `CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)` — these events
   are posted to the HID event stream and delivered to the now-active target app.
7. After 300ms (DispatchQueue.main.asyncAfter): restore original clipboard ONLY IF
   `NSPasteboard.general.changeCount == savedChangeCount` — skip restore if another
   process wrote to clipboard during the window.

Fallback: CGEvent keystroke per character (for fields where ⌘V is blocked, e.g. some
terminal emulators, browser address bars). If ⌘V produces no effect (detected by no
changeCount change at target), fall back to character-by-character injection.

Note: `NSPanel` with `styleMask: .nonactivatingPanel` does NOT steal focus from other apps
when shown — this is the correct panel style for RecordingWindow. But it may still be
key window if user interacted with it. `orderOut` before activate is the safe pattern.
```

- [ ] **Edit RecordingWindow.swift entry** — add panel style note:

Append to RecordingWindow.swift line:
```
│                                    # Must use styleMask: .nonactivatingPanel to avoid
│                                    # stealing focus from target app during recording.
│                                    # Panel is ordered out (hidden) BEFORE ⌘V simulation.
```

- [ ] **Commit** — `git commit -m "fix: specify exact nswindow focus order before cmd-v in textinjector"`

---

### Fix 8: delete_last keystroke mapping

**Problem:** Spec says CommandExecutor handles "delete, newline" (line 509) but delete_last has no defined keystroke.

**Decision:** "delete that" in dictation = delete the last injected phrase. Since OpenVerb injects via ⌘V, the last action is a paste. The correct operation is ⌘Z (undo last paste). BUT "undo" is already a separate command. Two options:
- Option A: delete_last = ⌘Z (same as undo — simplest, relies on app's undo stack)
- Option B: delete_last = ⇧⌥← (select one word left) + ⌫ — deletes last word

**Choose Option A** (⌘Z): More reliable across apps (every text editor supports undo), and "delete that" semantically means "undo what I just said." The distinction from "undo" is only semantic — both map to ⌘Z. This is how Apple's dictation and Dragon work.

- [ ] **Edit Structural Voice Commands table** — add keystroke column:

Current:
```
| Gemma output | Action |
|-------------|--------|
| "delete that" | command: delete_last |
| "undo" | command: undo (⌘Z) |
| "new line" | command: insert \n |
| "new paragraph" | command: insert \n\n |
```
Replace with:
```
| Gemma output | Action | Keystroke (CommandExecutor.swift) |
|-------------|--------|----------------------------------|
| "delete that" | command: delete_last | ⌘Z — undo last paste (same as undo). Rationale: OpenVerb injected via ⌘V; undo reverses it cleanly in all standard text editors. Semantic distinction from "undo" is intentional but keystroke is identical. |
| "undo" | command: undo | ⌘Z |
| "new line" | command: insert_newline | Return (kVK_Return, no modifiers) |
| "new paragraph" | command: insert_newparagraph | Return + Return (two sequential CGEvents with 50ms between) |
```

- [ ] **Edit CommandExecutor.swift entry** (line 509):

Current:
```
│   └── CommandExecutor.swift        # CGEvent: undo, delete, newline
```
Replace with:
```
│   └── CommandExecutor.swift        # CGEvent execution of engine commands:
│                                    #   delete_last → ⌘Z (undo last paste)
│                                    #   undo → ⌘Z
│                                    #   insert_newline → Return
│                                    #   insert_newparagraph → Return + Return (50ms apart)
│                                    # All CGEvents target frontmost app (captured before recording).
│                                    # RecordingWindow must be hidden before firing CGEvents.
```

- [ ] **Commit** — `git commit -m "fix: define delete_last = cmd-z, add keystroke mappings to command table"`

---

## Chunk 4: UI/Progress Contradiction (2)

### Fix 2: ProcessingView description vs progress percent

**Problem:** ProcessingView = "not precise progress bar" implies it ignores progress percent. But engine sends non-monotonic float progress every ~500ms. The UI should use the data.

**Resolution:** ProcessingView IS an animated indicator driven by progress percent, but does NOT show a numeric countdown (because values aren't monotonic). It animates a ring/bar using percent as input — smoothed, not tick-exact. "Not precise progress bar" means no "42% done" label, not "ignores progress data."

- [ ] **Edit ProcessingView.swift entry** (line 503):

Current:
```
│   ├── ProcessingView.swift         # Activity indicator during inference (not precise progress bar)
```
Replace with:
```
│   ├── ProcessingView.swift         # Animated indicator during inference. Driven by progress
│                                    # percent from engine {"type":"progress","percent":N}.
│                                    # NOT a precise countdown (progress is non-monotonic estimate
│                                    # for Path A — may go 42.5 → 38 → 61). Instead: animate a
│                                    # circular ring fill using percent as smoothed input (clamp
│                                    # to [lastPercent, 100], never go backward in UI).
│                                    # No numeric label shown. Falls back to spinner if no
│                                    # progress messages received within first 2s of inference.
```

- [ ] **Edit progress semantics note** (line 170/331) — add UI guidance:

After "Clients should treat it as an activity indicator, not a precise countdown.", add:
```
UI guidance: clamp displayed progress to be monotonically non-decreasing (update only if
new value > current UI value). This hides Path A's non-monotonic estimates without
blocking updates. The user sees smooth forward progress, not backtracking.
```

- [ ] **Commit** — `git commit -m "clarify: processingview uses clamped progress percent, not pure spinner"`

---

## Human: Review + Verify

- [ ] Read full updated spec top-to-bottom
- [ ] Check all 10 issues are resolved (no new contradictions introduced)
- [ ] Verify phase descriptions don't conflict with existing MVP plans
- [ ] Commit corrections document:
  `git add docs/superpowers/plans/2026-04-14-spec-corrections.md && git commit -m "add spec corrections plan for 10 architecture issues"`
