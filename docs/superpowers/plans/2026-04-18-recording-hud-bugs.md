# RecordingHUD — Timer / Waveform / Live Transcript Fix Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 3 regressions introduced by the uncommitted RecordingHUD design-system code that currently lives (untracked) in the main worktree:

1. Elapsed-seconds timer stuck at `00:00`.
2. Waveform bars appear static despite amplitudes flowing through the view model.
3. Live partial transcript never renders in the panel while the user dictates.

**State of the repo at plan time:**
- All Claude worktrees are at commit `523141e` (`main`). No design-system commit exists in any local or remote branch.
- **The design-system work IS present — as uncommitted edits in the MAIN worktree** at `/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/`. `RecordingWindow.swift`, `OpenVerbApp.swift`, `WaveformView.swift`, and a few preferences files carry the HUD (400×160 panel, moss/dolomite glass, `HUDStatusDot`, `HUDLoadingBar`, Stop button, `elapsedSeconds`, `onStop` callback, moss-green waveform).
- The canonical design is `/Users/terobyte/Downloads/ui_kits/recording-hud/` (React demo built from `docs/DESIGN_SYSTEM_1_RecordingUILibrary.md`). Sizing, colours, and pulse timings in the Swift code already match that spec — the 3 bugs are implementation defects, not design drift.

**Execution location:** This plan runs against the **MAIN worktree** (`/Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/`), because that is where the uncommitted HUD code lives. Do NOT apply these changes inside `.claude/worktrees/xenodochial-buck-5f25c5/` — that tree has a clean pre-HUD baseline and the edits would evaporate.

**Architecture:**
- Commit the existing uncommitted HUD code as a baseline first, so any mis-step is trivially revertible.
- One TDD-style failing test per bug (Red), one minimal fix per bug (Green), one commit per fix.
- All three bugs have specific, evidence-backed root causes that do not require touching the engine, IPC, Phase 2 monitor, or the `drainResult` loop — the transcript pipeline already works end-to-end.

**Tech Stack:**
- Swift 5.9 / SwiftUI on macOS 13+
- AppKit `NSPanel` (`.nonactivatingPanel`, `.borderless`, floating level)
- Existing `WaveformViewModel` / `ProcessingViewModel` / `AppState` (all `@MainActor`, `@Published`)
- XCTest with the source-grep pattern already established in `OpenBugsNegativeTests.swift`

---

## Root-Cause Analysis (systematic-debugging Phase 1 — read-only evidence)

### Bug A — Timer stuck at 00:00

**Location:** [RecordingWindow.swift:251](../../../app/OpenVerb/UI/RecordingWindow.swift) (path is relative to the main worktree).

```swift
.onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
    if appState.state == .recording { elapsedSeconds += 1 }
}
```

**Why it fails:** `Timer.publish(...)` is re-evaluated on every SwiftUI body evaluation. Each body pass produces a fresh `Publishers.Autoconnect<Timer.TimerPublisher>` *instance*. SwiftUI's diffing sees a new publisher identity, tears down the previous subscription, and starts a new one from t=0. A state change that re-evaluates the body — e.g. `appState.preparingSubtitle` being set, `showRecording` flipping, `waveformVM.amplitudes` being appended — happens far more often than once per second. The 1-second interval therefore never completes, and `elapsedSeconds += 1` is never reached.

`.nonactivatingPanel` does NOT cause this. Run-loop mode `.common` is correct.

**Minimal fix:** hoist the publisher to `@State` so its identity is stable across body re-evaluations.

### Bug B — Waveform bars appear static

**Location:** [RecordingWindow.swift:274-275](../../../app/OpenVerb/UI/RecordingWindow.swift) (main worktree).

```swift
.animation(.easeInOut(duration: 0.2), value: showRecording)
.animation(.easeInOut(duration: 0.2), value: showInferring)
```

**Why it fails:** These two modifiers sit on the outer `ZStack` that contains the `WaveformView`. SwiftUI's implicit-animation propagation applies an enclosing `.animation` to every state change inside that view subtree UNLESS an inner modifier takes ownership via `value:`. `WaveformView` has its own `.animation(.linear(duration: 0.05), value: viewModel.amplitudes)` (WaveformView.swift:82), but the outer modifier's `value:` key (`showRecording` / `showInferring`) is unrelated to `amplitudes`, so every amplitude-driven update inherits the outer 0.2 s easeInOut as well. The bars DO update — but at 0.2 s ease, each update is visually indistinguishable from the previous frame, so the chart looks frozen.

**Minimal fix:** Move the outer `.animation(...)` modifiers so they no longer wrap the waveform. Applying them only to the container that actually animates the crossfade (the conditional `if showRecording { WaveformView(...) }` branch via `.transition(.opacity)` — which is already in place at line 170) is sufficient.

### Bug C — Live partial transcript never renders

**Location:** [AppSettings.swift:121](../../../app/OpenVerb/Settings/AppSettings.swift) (main worktree).

```swift
@Published var showLiveTranscript: Bool = false { ... }
```

**Why it fails:** The end-to-end pipeline is intact:
- During `.recording`, EngineClient's Phase 2 monitor forwards `partial_result` messages via `onPartialResult?(t, id, f)` (EngineClient.swift:617).
- During `.inferring`, `drainResult` does the same (OpenVerbApp.swift:842).
- The callback in OpenVerbApp.swift:265 appends each partial to `appState.livePartialText` on the MainActor.
- RecordingContentView renders `appState.livePartialText` inside the panel (RecordingWindow.swift:237).

But the `if settings.showLiveTranscript, …` gate at line 234 short-circuits because the user-visible preference defaults to `false`. The text accumulates in state but is never drawn.

**Minimal fix:** flip the default to `true`. Users who want the minimal HUD can uncheck it in Preferences; the `@AppStorage` / `UserDefaults` key is untouched so anyone who already explicitly saved `false` keeps that preference.

---

## File Structure

**Modified (in MAIN worktree):**
- `app/OpenVerb/UI/RecordingWindow.swift` — Timer publisher hoist (Bug A), outer animation narrowing (Bug B).
- `app/OpenVerb/Settings/AppSettings.swift` — flip `showLiveTranscript` default (Bug C).

**Created:**
- `app/OpenVerbTests/RecordingHUDBugsTests.swift` — three source-grep + state tests following the pattern in `OpenBugsNegativeTests.swift`.

No new views, no new view models, no new production files. The HUD architecture stays as-is.

---

## Pre-flight

- [ ] **Step 0.1: Switch to the main worktree**

Run: `cd /Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb`
Verify: `pwd` prints that exact path. If another `cd` landed you inside `.claude/worktrees/*`, the plan will not see the uncommitted HUD code.

- [ ] **Step 0.2: Confirm the uncommitted HUD code is present**

Run:
```bash
git -C /Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb diff --stat HEAD -- app/OpenVerb/UI/RecordingWindow.swift app/OpenVerb/Settings/AppSettings.swift
grep -c "HUDStatusDot\|HUDLoadingBar\|elapsedSeconds" /Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb/app/OpenVerb/UI/RecordingWindow.swift
```
Expected: the diff shows non-zero changed lines in `RecordingWindow.swift` (and probably `AppSettings.swift`, `OpenVerbApp.swift`, `WaveformView.swift`). The grep returns ≥ 3. If either is empty, the baseline described in this plan is not present — stop and reconcile with the user before continuing.

- [ ] **Step 0.3: Full build + full test run on the as-is baseline**

Run: `cd app && swift build 2>&1 | tail -10`
Expected: BUILD SUCCESS.
Run: `swift test 2>&1 | tail -15`
Expected: All tests GREEN. Record the pass count (e.g. "47 tests passed"). The plan must finish with a strictly greater count.

---

## Chunk 1: Commit the baseline so fixes are revertible

### Task 1: Commit the uncommitted HUD code as the baseline

**Rationale:** the HUD edits have been sitting as working-tree changes on `main` with no commit. Each subsequent fix is easier to review, bisect, and revert if the HUD work itself is a single commit rather than bundled with bug fixes.

- [ ] **Step 1.1: Stage only the source-code HUD edits**

Run: `git -C /Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb status --short | grep -v '^\s*[?]*\s*app/\.build/' | grep -v '^\s*[?]*\s*app/OpenVerb\.xcodeproj/project\.pbxproj\s*$'`
Expected: a short list of real source files (`app/OpenVerb/UI/RecordingWindow.swift`, `app/OpenVerb/Settings/AppSettings.swift`, etc.). DO NOT `git add -A` — that would stage `.build/` binaries and potentially pbxproj changes that CLAUDE.md forbids touching.

- [ ] **Step 1.2: Stage the source files by name**

Run (adjust list to match Step 1.1 output; do not add `.build/`, do not add `.xcodeproj`):
```bash
cd /Users/terobyte/Desktop/Projects/Active/scripts/OpenVerb
git add app/OpenVerb/UI/RecordingWindow.swift \
        app/OpenVerb/UI/WaveformView.swift \
        app/OpenVerb/Settings/AppSettings.swift \
        app/OpenVerb/App/OpenVerbApp.swift
# Add any further source files surfaced in Step 1.1; omit anything unfamiliar.
```

- [ ] **Step 1.3: Commit with a honest description of the baseline**

```bash
git commit -m "recording hud design system (baseline; three known bugs follow)"
```

- [ ] **Step 1.4: Confirm working tree clean of source, only build artefacts left**

Run: `git status --short | grep -v '^\s*M\s*app/\.build/' | head`
Expected: empty (or only pbxproj — leave that alone per CLAUDE.md).

---

## Chunk 2: Failing tests (systematic-debugging Phase 3 — Red)

### Task 2: Source-level regression tests

**Files:**
- Create: `app/OpenVerbTests/RecordingHUDBugsTests.swift`

- [ ] **Step 2.1: Write the three failing tests**

```swift
import XCTest
@testable import OpenVerb

// ---------------------------------------------------------------------------
// RecordingHUDBugsTests — one test per open HUD bug.
// Pattern mirrors OpenBugsNegativeTests.swift: assert CORRECT behaviour and
// fail while the bug exists. GREEN = bug fixed.
// ---------------------------------------------------------------------------

final class RecordingHUDBugsTests: XCTestCase {

    private func readSource(_ relativePath: String) -> String? {
        let direct = URL(fileURLWithPath: relativePath)
        return try? String(contentsOf: direct, encoding: .utf8)
    }

    // =======================================================================
    // Bug A — elapsed-seconds timer stuck at 00:00.
    //
    // Root cause: Timer.publish(...) is re-created inside body on every eval,
    // so SwiftUI replaces the subscription faster than 1 s can elapse.
    //
    // EXPECTED: the publisher is hoisted to @State so its identity is stable.
    // ACTUAL:   Timer.publish is used inline inside .onReceive in body.
    // =======================================================================

    func testBugA_ElapsedSecondsTimerPublisherIsHoistedToState() {
        guard let src = readSource("OpenVerb/UI/RecordingWindow.swift") else {
            XCTFail("Cannot read RecordingWindow.swift"); return
        }
        // The stable fix pattern is a @State-owned publisher named `ticker`
        // (or similar). Assert the file declares one.
        let hasStatePublisher = src.contains("@State private var ticker") ||
                                src.contains("@State private let ticker") ||
                                src.contains("@State private var elapsedTicker") ||
                                src.contains("@State private let elapsedTicker")
        XCTAssertTrue(hasStatePublisher,
            "Bug A: Timer.publish must be hoisted to a @State property so " +
            "SwiftUI does not re-subscribe on every body eval.")

        // Negative assertion: the inline usage pattern must not remain.
        XCTAssertFalse(
            src.contains(".onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect())"),
            "Bug A: inline Timer.publish(...).autoconnect() inside .onReceive keeps " +
            "re-subscribing and never fires.")
    }

    // =======================================================================
    // Bug B — waveform bars appear static.
    //
    // Root cause: outer .animation(.easeInOut(duration: 0.2), value: …)
    // wraps WaveformView and overrides its inner 0.05 s linear animation.
    //
    // EXPECTED: the outer easeInOut 0.2s animations are removed or scoped to
    //           a container that does NOT include WaveformView.
    // ACTUAL:   two such modifiers sit on the root ZStack.
    // =======================================================================

    func testBugB_OuterAnimationDoesNotEngulfWaveform() {
        guard let src = readSource("OpenVerb/UI/RecordingWindow.swift") else {
            XCTFail("Cannot read RecordingWindow.swift"); return
        }
        // The pre-fix version has these two lines together at the bottom of
        // body; the fix either removes them or moves them onto a narrower
        // container. Assert the offending pair no longer sits on the root.
        let pattern =
            ".animation(.easeInOut(duration: 0.2), value: showRecording)\n" +
            "        .animation(.easeInOut(duration: 0.2), value: showInferring)"
        XCTAssertFalse(src.contains(pattern),
            "Bug B: outer .animation(.easeInOut(0.2)) on the root ZStack " +
            "overrides WaveformView's 0.05 s linear and freezes the bars.")
    }

    // =======================================================================
    // Bug C — live partial transcript never shown.
    //
    // Root cause: AppSettings.showLiveTranscript defaults to false; the UI
    // gate never fires even though partial_result messages arrive and
    // appState.livePartialText accumulates correctly.
    //
    // EXPECTED: default is true so fresh installs see the live text.
    // ACTUAL:   default is false.
    // =======================================================================

    func testBugC_ShowLiveTranscriptDefaultsToTrue() {
        guard let src = readSource("OpenVerb/Settings/AppSettings.swift") else {
            XCTFail("Cannot read AppSettings.swift"); return
        }
        XCTAssertTrue(
            src.contains("var showLiveTranscript: Bool = true"),
            "Bug C: showLiveTranscript default must be true so live partial " +
            "text is visible out-of-the-box.")
        XCTAssertFalse(
            src.contains("var showLiveTranscript: Bool = false"),
            "Bug C: the old default literal is still in the file.")
    }
}
```

- [ ] **Step 2.2: Run the new file; confirm all 3 tests FAIL**

Run: `cd app && swift test --filter RecordingHUDBugsTests 2>&1 | tail -20`
Expected: 3 failures, no compile errors. Each failure message should quote the root-cause description above.

- [ ] **Step 2.3: Commit the red tests**

```bash
git add app/OpenVerbTests/RecordingHUDBugsTests.swift
git commit -m "red: failing tests for timer / waveform / live-transcript bugs"
```

---

## Chunk 3: Bug A fix — hoist the timer publisher (Green for test A)

### Task 3: Make the tick publisher stable across body evaluations

**Files:**
- Modify: `app/OpenVerb/UI/RecordingWindow.swift`

- [ ] **Step 3.1: Add a `@State` ticker property to `RecordingContentView`**

Open `RecordingWindow.swift`. Locate the block near line 129-132:

```swift
    @State private var showRecording = false
    @State private var showInferring = false
    @State private var previousState: AppState.State = .idle
    @State private var elapsedSeconds = 0
```

Add immediately below:

```swift
    // Bug A: publisher must be @State so identity is stable across body evals,
    // otherwise SwiftUI cancels & re-subscribes every render and the 1 s
    // countdown never completes. autoconnect() makes it start on first receive.
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
```

- [ ] **Step 3.2: Replace the inline `.onReceive(Timer.publish(...)...)` with `.onReceive(ticker)`**

Around line 251 replace:

```swift
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if appState.state == .recording { elapsedSeconds += 1 }
        }
```

with:

```swift
        .onReceive(ticker) { _ in
            if appState.state == .recording { elapsedSeconds += 1 }
        }
```

- [ ] **Step 3.3: Build**

Run: `cd app && swift build 2>&1 | tail -5`
Expected: SUCCESS, no warnings touching `Timer.publish` or `ticker`.

- [ ] **Step 3.4: Run the failing test — now GREEN**

Run: `cd app && swift test --filter testBugA 2>&1 | tail -10`
Expected: `testBugA_ElapsedSecondsTimerPublisherIsHoistedToState` PASS. The two other bug tests still FAIL.

- [ ] **Step 3.5: Commit**

```bash
git add app/OpenVerb/UI/RecordingWindow.swift
git commit -m "fix timer frozen at 00:00 by hoisting ticker publisher to state"
```

---

## Chunk 4: Bug B fix — narrow the outer animation (Green for test B)

### Task 4: Remove the outer 0.2 s animations that swallow waveform updates

**Files:**
- Modify: `app/OpenVerb/UI/RecordingWindow.swift`

- [ ] **Step 4.1: Delete lines 274-275 from the `body`**

Locate the two lines at the end of `body` (around line 274):

```swift
        .animation(.easeInOut(duration: 0.2), value: showRecording)
        .animation(.easeInOut(duration: 0.2), value: showInferring)
```

**Delete both lines entirely.** The waveform's internal `.animation(.linear(duration: 0.05), value: viewModel.amplitudes)` is now the sole animation governing bar updates. Opacity transitions on conditional views already use `.transition(.opacity)` in the `if showRecording { … }` and `if showInferring { … }` branches (lines 170, 180), so the crossfade still works — it was driven by the `.transition` modifier, not by the outer `.animation`.

If a crossfade regresses after the deletion, wrap only the offending `if` branch with `.animation(.easeInOut(duration: 0.2), value: showRecording)` INSIDE that branch, not on the root `ZStack` — but verify the regression first rather than reintroducing the animation proactively.

- [ ] **Step 4.2: Build**

Run: `cd app && swift build 2>&1 | tail -5`
Expected: SUCCESS.

- [ ] **Step 4.3: Run Bug B test — GREEN**

Run: `cd app && swift test --filter testBugB 2>&1 | tail -10`
Expected: `testBugB_OuterAnimationDoesNotEngulfWaveform` PASS.

- [ ] **Step 4.4: Manual smoke of the waveform**

Run the app (via `ov` or Xcode), start a recording. Waveform bars should animate at ~20 fps with each RMS update (~every 50–100 ms). If bars still look static, rerun the systematic-debugging loop — possible secondary cause is a stale `@ObservedObject` binding or a misconfigured `AudioSession` callback.

- [ ] **Step 4.5: Commit**

```bash
git add app/OpenVerb/UI/RecordingWindow.swift
git commit -m "fix static waveform by removing outer animations that swallow amplitude updates"
```

---

## Chunk 5: Bug C fix — flip live transcript default (Green for test C)

### Task 5: Make live partial transcript visible by default

**Files:**
- Modify: `app/OpenVerb/Settings/AppSettings.swift`

- [ ] **Step 5.1: Flip the default at line 121**

Locate:

```swift
    @Published var showLiveTranscript: Bool = false {
```

Replace with:

```swift
    @Published var showLiveTranscript: Bool = true {
```

**Do NOT change** the reset-to-defaults line (`showLiveTranscript = false` near line 269) — wait, actually re-read that block: a reset-to-defaults should mirror the declared default. Fix both:

- [ ] **Step 5.2: Align the reset-to-defaults branch**

Locate around line 269:

```swift
        showLiveTranscript = false
```

Replace with:

```swift
        showLiveTranscript = true
```

Check nothing else in the same file assigns `showLiveTranscript = false` unconditionally (grep inside the edit: if there's a `defaults.object(forKey:) != nil` branch that loads a previously-saved user value, leave it untouched — only the fall-back default needs to flip).

- [ ] **Step 5.3: Build + tests**

Run: `cd app && swift build 2>&1 | tail -5`
Expected: SUCCESS.
Run: `cd app && swift test --filter testBugC 2>&1 | tail -10`
Expected: `testBugC_ShowLiveTranscriptDefaultsToTrue` PASS.

- [ ] **Step 5.4: Commit**

```bash
git add app/OpenVerb/Settings/AppSettings.swift
git commit -m "show live partial transcript by default"
```

---

## Chunk 6: Full verification (superpowers:verification-before-completion)

### Task 6: Guarantee all 3 bugs fixed, no regressions

- [ ] **Step 6.1: Full test suite**

Run: `cd app && swift test 2>&1 | tail -20`
Expected: ALL tests GREEN. New pass count = baseline pass count (from Step 0.3) + 3.

- [ ] **Step 6.2: Xcode build (the one that signs & runs the menu-bar app)**

Run: `ov 2>&1 | tail -15`
Expected: BUILD SUCCEEDED. No new warnings.

- [ ] **Step 6.3: Manual end-to-end smoke**

Start the app. Open TextEdit (or any text field). Press `⌥Space`, speak for 6-8 seconds covering at least two pauses, press `⌥Space` again. Verify:

1. Timer advances `00:00 → 00:01 → … → 00:07` during recording. (Bug A)
2. Waveform bars visibly react to voice, updating roughly every 80 ms. (Bug B)
3. Live partial text renders under the waveform as you speak — even if it stutters or revises — and keeps rendering through the `.inferring` phase. (Bug C)
4. Final transcription is injected into TextEdit. (regression check — not a bug in this plan, but trivial to verify.)

- [ ] **Step 6.4: Regression check on previously-fixed bugs that touch the same surface**

Run: `cd app && swift test --filter Bug54 --filter Bug55 --filter Bug16 --filter Bug17 2>&1 | tail -15`
Expected: all GREEN. These cover clipboard capture (54), live partial forwarding (55), and drain generation (16/17) — the closest guardrails to the code we touched.

- [ ] **Step 6.5: Tidy commit if any wiring leftover**

Run: `git status --short`
If only `.build/` artefacts remain: do nothing.
Otherwise stage just the deliberate bits and commit with a short, honest message.

---

## Post-completion notes

- The three fixes above are intentionally tiny (three lines of production code total). Do NOT bundle other "while I'm here" cleanup into these commits — the baseline HUD commit from Chunk 1 already carries significant visual change, and mixing behaviour fixes with cleanup makes a post-hoc bisect miserable.
- If Bug B's deletion visibly breaks the recording→inferring crossfade, reintroduce the animation **only** around the conditional HUDLoadingBar branch, not on the root ZStack. Verify with a manual smoke before committing.
- **DO NOT touch `app/OpenVerb.xcodeproj/project.pbxproj`** (see CLAUDE.md § "🚨 DO NOT TOUCH: Code Signing Configuration 🚨"). If Xcode needs file membership updates after this plan, do it via the Xcode GUI manually.
- Record Bug A's root cause pattern (publisher re-identity breaks `Timer.publish` inside `body`) somewhere durable — it's the kind of trap that bites every new SwiftUI agent once.
