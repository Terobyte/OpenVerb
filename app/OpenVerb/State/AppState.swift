import Foundation
import AppKit
import os

// ---------------------------------------------------------------------------
// AppState — single source of truth for the OpenVerb UI state machine.
//
// Valid transitions:
//   IDLE        → PREPARING  (⌥Space pressed)
//   PREPARING   → RECORDING  (session.ready received)
//   PREPARING   → ERROR      (connection failed)
//   PREPARING   → IDLE       (Escape cancel during cold-start window)
//   RECORDING   → INFERRING  (second ⌥Space press)
//   RECORDING   → IDLE       (Escape cancel)
//   INFERRING   → IDLE       (result received)
//   INFERRING   → PREPARING  (abort+restart — preserves targetApp)
//   any         → ERROR      (engine error, hardware failure)
//   ERROR       → PREPARING  (⌥Space during error auto-clear window)
//   ERROR       → IDLE       (5-second auto-clear timer fired)
//
// Invalid transitions assert in DEBUG builds and are silently ignored in RELEASE.
// ERROR→ERROR is explicitly ignored to prevent duplicate error callbacks.
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "AppState")

@MainActor
final class AppState: ObservableObject {

    // -----------------------------------------------------------------------
    // State enum
    // -----------------------------------------------------------------------

    enum State: Equatable, CustomStringConvertible {
        case idle
        case preparing
        case recording
        case inferring
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.preparing, .preparing),
                 (.recording, .recording),
                 (.inferring, .inferring):
                return true
            case (.error(let l), .error(let r)):
                return l == r
            default:
                return false
            }
        }

        var description: String {
            switch self {
            case .idle:        return "idle"
            case .preparing:   return "preparing"
            case .recording:   return "recording"
            case .inferring:   return "inferring"
            case .error(let m): return "error(\(m))"
            }
        }
    }

    // -----------------------------------------------------------------------
    // Published state
    // -----------------------------------------------------------------------

    @Published private(set) var state: State = .idle

    /// The app that was frontmost when ⌥Space was first pressed in IDLE.
    /// Captured on IDLE→PREPARING; preserved on INFERRING→PREPARING (abort+restart);
    /// cleared on any transition to IDLE.
    @Published private(set) var targetApp: NSRunningApplication?

    /// Non-nil while the engine is still loading in the PREPARING state.
    /// Set to "Preparing..." after 500ms in PREPARING; "Reconnecting..." during
    /// abort+restart window. Cleared when PREPARING→RECORDING.
    @Published private(set) var preparingSubtitle: String?

    /// Remaining inference time in milliseconds as reported by the engine's
    /// queue_status heartbeats.  Non-nil only while in .inferring state and
    /// the engine has sent at least one queue_status message.  Cleared on
    /// every transition to .idle.
    @Published var remainingInferenceMs: Int?

    /// Accumulated live partial transcript text from streaming partial_result
    /// messages.  Updated while the hotkey is held (recording) and during
    /// inference.  Cleared on every transition to .idle.
    @Published var livePartialText: String = ""

    /// The polished (LLM-cleaned) transcript text.  Set when the engine's
    /// polished_result message arrives.  Cleared on transition to .idle.
    @Published var polishedText: String?

    // -----------------------------------------------------------------------
    // Dependency injection for testing
    // -----------------------------------------------------------------------

    /// Returns the current frontmost application. Override in tests to inject
    /// a mock NSRunningApplication.
    var frontmostApplicationProvider: () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    /// Called when an invalid transition is attempted.
    /// Defaults to `assertionFailure` (crashes in DEBUG builds).
    /// Override with `{ _ in }` in tests to prevent the crash.
    var invalidTransitionAction: (String) -> Void = { assertionFailure($0) }

    /// Duration before the error state auto-clears to idle.
    /// Override with a short value in tests to avoid real-time waits.
    var errorClearDelay: Duration = .seconds(5)

    /// How long to wait in PREPARING before showing the "Preparing…" subtitle.
    /// Override with a short value in tests to avoid real-time waits.
    var preparingSubtitleDelay: Duration = .milliseconds(500)

    // -----------------------------------------------------------------------
    // Private
    // -----------------------------------------------------------------------

    private var autoClearTimer: Task<Void, Never>?

    /// Fires after `preparingSubtitleDelay` to surface "Preparing…" in the UI.
    /// Cancelled immediately when PREPARING transitions to any other state.
    private var preparingSubtitleTimer: Task<Void, Never>?

    // -----------------------------------------------------------------------
    // Transition
    // -----------------------------------------------------------------------

    func transition(to newState: State) {
        // Guard: ERROR→ERROR is explicitly ignored (no crash, no double-callback).
        if case .error = state, case .error = newState {
            logger.debug("Ignoring ERROR→ERROR duplicate transition")
            return
        }

        // Validate the requested transition.
        guard isValidTransition(from: state, to: newState) else {
            let msg = "Invalid state transition: \(state) → \(newState)"
            logger.error("\(msg)")
            invalidTransitionAction(msg)
            return
        }

        logger.debug("Transition: \(self.state) → \(newState)")

        applyEntryEffects(from: state, to: newState)
        state = newState
    }

    // -----------------------------------------------------------------------
    // Private — transition table
    // -----------------------------------------------------------------------

    private func isValidTransition(from current: State, to next: State) -> Bool {
        switch (current, next) {
        // Happy path
        case (.idle, .preparing):      return true
        case (.preparing, .recording): return true
        case (.recording, .inferring): return true
        case (.inferring, .idle):      return true

        // Cancel flows
        case (.preparing, .idle):      return true  // Escape during preparing
        case (.recording, .idle):      return true  // Escape during recording

        // Abort + restart
        case (.inferring, .preparing): return true

        // Error handling
        case (.preparing, .error):     return true
        case (.recording, .error):     return true
        case (.inferring, .error):     return true
        case (.idle, .error):          return true

        // Error recovery
        case (.error, .preparing):     return true  // ⌥Space during error
        case (.error, .idle):          return true  // auto-clear timer

        default:                       return false
        }
    }

    // -----------------------------------------------------------------------
    // Private — side effects on state entry
    // -----------------------------------------------------------------------

    private func applyEntryEffects(from previous: State, to next: State) {
        switch next {

        case .preparing:
            // Cancel any pending auto-clear timer from a prior error state.
            autoClearTimer?.cancel()
            autoClearTimer = nil

            // Cancel any leftover subtitle timer (e.g. quick PREPARING→IDLE→PREPARING).
            preparingSubtitleTimer?.cancel()
            preparingSubtitleTimer = nil

            // Clear live transcript from previous session (abort+restart skips IDLE).
            livePartialText = ""
            polishedText = nil

            switch previous {
            case .idle:
                // Fresh session: capture the frontmost app right now (before
                // RecordingWindow becomes visible and steals frontmost status).
                targetApp = frontmostApplicationProvider()

                // Show "Preparing…" only if the engine hasn't replied within 500 ms.
                // If session.ready arrives sooner the PREPARING→RECORDING transition
                // clears this field and cancels the task.
                let delay = preparingSubtitleDelay
                preparingSubtitleTimer = Task<Void, Never> { [weak self] in
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        // Cancelled — PREPARING already left; nothing to do.
                        return
                    }
                    self?.preparingSubtitle = "Preparing..."
                }

            case .inferring:
                // Abort+restart: preserve targetApp (same dictation target).
                // Show "Reconnecting…" immediately — the user knows a session
                // was already running; "Preparing…" would feel misleading.
                preparingSubtitle = "Reconnecting..."

            case .error:
                // ⌥Space during error window: keep targetApp if set, otherwise re-capture.
                if targetApp == nil {
                    targetApp = frontmostApplicationProvider()
                }

                // Belt-and-suspenders: entering .error already clears
                // preparingSubtitle, but ensure it is nil here so a rapid
                // ERROR → PREPARING sequence cannot show a stale subtitle
                // before the 500 ms timer fires.
                preparingSubtitle = nil

                // Treat this like a fresh prepare — show subtitle after delay.
                let delay = preparingSubtitleDelay
                preparingSubtitleTimer = Task<Void, Never> { [weak self] in
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                    self?.preparingSubtitle = "Preparing..."
                }

            default:
                break
            }

        case .recording:
            // Engine is ready — cancel the delayed "Preparing…" task (if still pending)
            // and clear any subtitle that may have already been shown.
            preparingSubtitleTimer?.cancel()
            preparingSubtitleTimer = nil
            preparingSubtitle = nil

        case .idle:
            // Any transition to IDLE resets session state completely.
            preparingSubtitleTimer?.cancel()
            preparingSubtitleTimer = nil
            targetApp = nil
            preparingSubtitle = nil
            autoClearTimer?.cancel()
            autoClearTimer = nil
            remainingInferenceMs = nil
            livePartialText = ""
            polishedText = nil

        case .error:
            // Leaving PREPARING (or any state) for ERROR: stop the subtitle timer
            // and clear any subtitle that may already be displayed. RecordingWindow
            // renders preparingSubtitle regardless of state, so a stale
            // "Preparing..." would reappear immediately on ERROR → PREPARING
            // instead of waiting the required 500 ms.
            preparingSubtitleTimer?.cancel()
            preparingSubtitleTimer = nil
            preparingSubtitle = nil

            // Start the auto-clear timer (default 5 s; injectable for tests).
            // The task is isolated to @MainActor (created from @MainActor context),
            // so calling self.transition() is safe without an additional dispatch.
            autoClearTimer?.cancel()
            let delay = errorClearDelay
            let task = Task<Void, Never> { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Task was cancelled — another transition happened; stop here.
                    return
                }
                guard !Task.isCancelled else { return }
                self?.transition(to: .idle)
            }
            autoClearTimer = task

        case .inferring:
            break
        }
    }
}
