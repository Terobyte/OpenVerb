import Foundation
import AppKit
import ApplicationServices
import os

// ---------------------------------------------------------------------------
// TextInjector — pastes transcribed text into the target app via clipboard
// simulation + CGEvent ⌘V.
//
// Operation order is CRITICAL for focus correctness:
//   (0) guard    — skip if target app was quit between recording and injection
//   (1) save     — save current clipboard string (before write)
//   (2) write    — put transcribed text on clipboard; record changeCount after
//   (3) hide     — window.orderOut(nil); release key-window status so the
//                  target app can reclaim focus
//   (4) activate — targetApp.activate(options: [])
//   (5) delay    — 50 ms minimum to cover async focus transfer under load
//   (6) paste    — CGEvent ⌘V key-down + key-up posted to HID stream
//   (7) delay    — 300 ms wait for target app to read clipboard before restore
//   (8) restore  — conditionally restore original clipboard (only if no other
//                  process wrote to it during the paste window)
//
// Requires Accessibility permission (AXIsProcessTrusted()) for CGEvent posting.
// Checked at launch in AppDelegate; if permission is absent the paste is lost.
// CGEvent per-character fallback for blocked-⌘V fields is deferred to MVP5.
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "TextInjector")

struct TextInjector {

    // -----------------------------------------------------------------------
    // inject — main entry point.
    //
    // All parameters are value/reference types that outlive the async scope;
    // RecordingWindow is an NSPanel and must be touched on the main thread,
    // which is guaranteed here because AppDelegate calls inject() from a
    // @MainActor Task.
    // -----------------------------------------------------------------------

    static func inject(
        text: String,
        targetApp: NSRunningApplication,
        window: RecordingWindow
    ) async {

        // (0) guard: skip injection if target app was quit
        guard !targetApp.isTerminated else {
            logger.warning("TextInjector: target app terminated before injection — aborting")
            window.orderOut(nil)
            return
        }

        let pasteboard = NSPasteboard.general

        // (1) save current clipboard string BEFORE our write
        let savedClipboard = pasteboard.string(forType: .string)

        // (2) write text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Capture changeCount AFTER our own write so the restore guard at step (8)
        // only fires when another process modifies the clipboard during the paste
        // window — not because of our own clearContents() / setString() calls.
        let savedChangeCount = pasteboard.changeCount
        logger.debug("TextInjector: clipboard loaded with \(text.count) chars")

        // (3) hide panel — releases key-window status so target app can refocus
        window.orderOut(nil)

        // (4) activate target app
        targetApp.activate(options: [])

        // (5) 50 ms focus-transfer delay
        // 0 ms works in microbenchmarks but fails intermittently under
        // system load; 50 ms is the empirical minimum for reliable delivery.
        try? await Task.sleep(for: .milliseconds(50))

        // (6) simulate ⌘V via CGEvent posted to the HID event stream
        //     virtualKey 0x09 = V key (ANSI scan code, not ASCII 0x56)
        postPasteEvent()

        // (7) 300 ms clipboard-read delay
        // Slow apps (Electron, Word) may take longer; 300 ms is best-effort.
        // If the clipboard is restored before the app reads it the paste is
        // lost — a known limitation of clipboard simulation (MVP3).
        try? await Task.sleep(for: .milliseconds(300))

        // (8) restore original clipboard ONLY IF changeCount unchanged
        // If another process wrote to the clipboard during the window skip
        // the restore to avoid overwriting their data.
        if pasteboard.changeCount == savedChangeCount {
            pasteboard.clearContents()
            if let saved = savedClipboard {
                pasteboard.setString(saved, forType: .string)
            }
            logger.debug("TextInjector: clipboard restored")
        } else {
            logger.debug("TextInjector: clipboard changed by another process — skipping restore")
        }
    }

    // -----------------------------------------------------------------------
    // Private — CGEvent ⌘V posting.
    // -----------------------------------------------------------------------

    private static func postPasteEvent() {
        // key-down
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        // key-up
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
    }
}
