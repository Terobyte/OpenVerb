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
        if !targetApp.activate(options: []) {
            logger.warning("TextInjector: activate() failed for \(targetApp.bundleIdentifier ?? targetApp.localizedName ?? "unknown")")
        }

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

    // -----------------------------------------------------------------------
    // CGEvent per-character fallback (MVP5)
    //
    // Used when ⌘V is blocked (some terminal emulators, secure input fields).
    // Only supports ASCII printable characters — CJK/emoji have no ANSI key
    // code and are silently skipped. ~5 ms per character (hardware event rate).
    // -----------------------------------------------------------------------

    /// Map a single character to its ANSI (keyCode, needsShift) tuple.
    /// Returns nil for characters with no physical ANSI key position.
    static func keyCodeForCharacter(_ char: String) -> (UInt16, Bool)? {
        guard char.count == 1, let scalar = char.unicodeScalars.first else { return nil }
        return Self.charToKeyCode[scalar]
    }

    /// Returns (keyCode, flags) with .maskShift set for uppercase/shifted chars.
    ///
    /// The charToKeyCode map stores lowercase key positions (needsShift always
    /// false in the map). We look up the lowercase version of the character, then
    /// derive shift from whether the original char differs from its lowercase form.
    static func keyCodeAndFlags(for char: String) -> (UInt16, CGEventFlags)? {
        guard let scalar = char.lowercased().unicodeScalars.first,
              let (code, _) = Self.charToKeyCode[scalar] else { return nil }
        let needsShift = char != char.lowercased()
        let flags: CGEventFlags = needsShift ? .maskShift : CGEventFlags(rawValue: 0)
        return (code, flags)
    }

    /// Inject text character by character via CGEvent keystrokes.
    /// Slow (~5 ms/char) but works where ⌘V is blocked.
    ///
    /// Bug 30: hide the floating panel and activate the target app BEFORE
    /// posting any keystrokes. Without this the panel keeps key-window
    /// status and every character is delivered back to OpenVerb instead
    /// of the user's app. Mirrors the focus-transfer order used by inject().
    static func injectPerCharacter(
        _ text: String,
        targetApp: NSRunningApplication,
        window: RecordingWindow
    ) async {

        // (0) guard: skip injection if target app was quit between recording
        //     and injection.  Mirrors inject().
        guard !targetApp.isTerminated else {
            logger.warning("TextInjector: target app terminated before per-character injection — aborting")
            window.orderOut(nil)
            return
        }

        // (1) hide panel — releases key-window status so target app can refocus.
        window.orderOut(nil)

        // (2) activate target app.
        if !targetApp.activate(options: []) {
            logger.warning("TextInjector: activate() failed for \(targetApp.bundleIdentifier ?? targetApp.localizedName ?? "unknown")")
        }

        // (3) 50 ms focus-transfer delay — empirical minimum for reliable
        //     keystroke delivery to the newly-frontmost app under load.
        try? await Task.sleep(for: .milliseconds(50))

        // (4) post one CGEvent pair per character.
        for char in text {
            guard let (keyCode, flags) = keyCodeAndFlags(for: String(char)) else {
                logger.debug("TextInjector: skipping unsupported char: \(String(char))")
                continue
            }
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
                if flags != CGEventFlags(rawValue: 0) { down.flags = flags }
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
                if flags != CGEventFlags(rawValue: 0) { up.flags = flags }
                up.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // ANSI key code lookup table (lowercase + special chars)
    private static let charToKeyCode: [Unicode.Scalar: (UInt16, Bool)] = {
        var map: [Unicode.Scalar: (UInt16, Bool)] = [:]
        let keys: [(Unicode.Scalar, UInt16)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03),
            ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
            ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C),
            ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10),
            ("t", 0x11), ("1", 0x12), ("2", 0x13), ("3", 0x14),
            ("4", 0x15), ("6", 0x16), ("5", 0x17), ("=", 0x18),
            ("9", 0x19), ("7", 0x1A), ("-", 0x1B), ("8", 0x1C),
            ("0", 0x1D), ("]", 0x1E), ("o", 0x1F), ("u", 0x20),
            ("[", 0x21), ("i", 0x22), ("p", 0x23), ("l", 0x25),
            ("j", 0x26), ("'", 0x27), ("k", 0x28), (";", 0x29),
            ("\\", 0x2A), (",", 0x2B), ("/", 0x2C), ("n", 0x2D),
            ("m", 0x2E), (".", 0x2F), ("`", 0x32),
        ]
        for (char, code) in keys { map[char] = (code, false) }
        map[" "]  = (0x31, false)   // Space
        map["\t"] = (0x30, false)   // Tab
        map["\n"] = (0x24, false)   // Return
        return map
    }()
}
