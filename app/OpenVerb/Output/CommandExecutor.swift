import Foundation
import AppKit
import ApplicationServices
import os

// ---------------------------------------------------------------------------
// CommandExecutor — executes engine voice commands as CGEvent key combos.
//
// Supported actions (engine → key event):
//   "delete_last"        → ⌘Z  (undo the TextInjector ⌘V paste)
//   "undo"               → ⌘Z  (same key; semantic distinction only)
//   "insert_newline"     → Return
//   "insert_newparagraph"→ Return + Return (50 ms apart)
//   unknown / ""         → no-op (warning logged)
//
// Focus sequence (same as TextInjector for reliability):
//   window.orderOut(nil) → targetApp.activate() → 50 ms delay → CGEvent post
//
// Note: CGEvent posting requires Accessibility permission.  Checked at launch.
// Punctuation (".", ",") is NOT a command — the engine outputs it as text and
// TextInjector handles it.
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "CommandExecutor")

// ---------------------------------------------------------------------------
// EventPoster — protocol for posting key events.
// The production implementation uses CGEvent; tests inject a mock recorder.
// ---------------------------------------------------------------------------

protocol EventPoster {
    func postKeyDown(virtualKey: CGKeyCode, flags: CGEventFlags)
}

// ---------------------------------------------------------------------------
// CGEventPoster — real CGEvent implementation.
// ---------------------------------------------------------------------------

struct CGEventPoster: EventPoster {
    func postKeyDown(virtualKey: CGKeyCode, flags: CGEventFlags) {
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}

// ---------------------------------------------------------------------------
// KeyAction — a single virtual key press with modifier flags.
// ---------------------------------------------------------------------------

struct KeyAction {
    let keyCode: CGKeyCode
    let flags:   CGEventFlags
}

// ---------------------------------------------------------------------------
// CommandExecutor
// ---------------------------------------------------------------------------

struct CommandExecutor {

    // -----------------------------------------------------------------------
    // action(for:) — pure mapping from Command → [KeyAction].
    //
    // Returns nil for unknown or empty actions (caller treats as no-op).
    // This method is intentionally side-effect-free so unit tests can verify
    // the mapping without requiring Accessibility permission or a real display.
    // -----------------------------------------------------------------------

    static func action(for command: Command) -> [KeyAction]? {
        switch command.action {

        case "delete_last", "undo":
            // ⌘Z — undo the TextInjector paste (delete_last) or arbitrary undo
            return [KeyAction(keyCode: 6, flags: .maskCommand)]   // 6 = Z key

        case "insert_newline":
            // Return key (kVK_Return = 0x24 = 36 decimal)
            return [KeyAction(keyCode: 0x24, flags: [])]

        case "insert_newparagraph":
            // Two Return presses; CommandExecutor.execute() inserts a 50 ms gap
            return [
                KeyAction(keyCode: 0x24, flags: []),
                KeyAction(keyCode: 0x24, flags: []),
            ]

        default:
            // Empty action or unknown command — no-op.
            return nil
        }
    }

    // -----------------------------------------------------------------------
    // execute — public entry point; uses real CGEventPoster.
    // -----------------------------------------------------------------------

    static func execute(
        command: Command,
        targetApp: NSRunningApplication,
        window: RecordingWindow
    ) async {
        await execute(
            command:   command,
            targetApp: targetApp,
            window:    window,
            poster:    CGEventPoster()
        )
    }

    // -----------------------------------------------------------------------
    // execute(poster:) — testable overload with injected EventPoster.
    // -----------------------------------------------------------------------

    static func execute(
        command:   Command,
        targetApp: NSRunningApplication,
        window:    RecordingWindow,
        poster:    EventPoster
    ) async {

        guard !targetApp.isTerminated else {
            logger.warning("CommandExecutor: target app terminated — aborting")
            window.orderOut(nil)
            return
        }

        guard let actions = action(for: command) else {
            logger.warning("CommandExecutor: unknown action '\(command.action)' — no-op")
            // Dismiss the floating panel so it is never left visible on screen.
            window.orderOut(nil)
            return
        }

        // Focus sequence (same as TextInjector)
        window.orderOut(nil)
        if !targetApp.activate(options: []) {
            logger.warning("CommandExecutor: activate() failed for \(targetApp.bundleIdentifier ?? targetApp.localizedName ?? "unknown")")
        }
        try? await Task.sleep(for: .milliseconds(50))

        // Post each key action; 50 ms gap between sequential events
        // (needed for insert_newparagraph double-Return so apps see them
        //  as two distinct key-down events rather than a held key).
        for (i, a) in actions.enumerated() {
            poster.postKeyDown(virtualKey: a.keyCode, flags: a.flags)
            if i < actions.count - 1 {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        logger.debug("CommandExecutor: executed '\(command.action)' (\(actions.count) key event(s))")
    }
}
