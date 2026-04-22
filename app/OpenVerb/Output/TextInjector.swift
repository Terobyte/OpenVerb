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
//   (4) activate — targetApp.activate(options: .activateIgnoringOtherApps)
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

    @MainActor
    static func inject(
        text: String,
        targetApp: NSRunningApplication,
        window: RecordingWindow
    ) async {
        guard !targetApp.isTerminated else { window.orderOut(nil); return }

        let pasteboard = NSPasteboard.general

        if isSecureField() { window.orderOut(nil); return }

        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        // Bug 156: session-unique token instead of changeCount (wraps).
        let restoreTokenType = NSPasteboard.PasteboardType("io.openverb.restore-token")
        let restoreToken = UUID().uuidString

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(restoreToken, forType: restoreTokenType)

        window.orderOut(nil)

        // Bug 154: guard targetApp.activate — abort on focus-transfer fail.
        guard targetApp.activate(options: .activateIgnoringOtherApps) else {
            // !targetApp.activate branch: restore clipboard and bail before ⌘V.
            pasteboard.clearContents()
            if let items = savedItems, !items.isEmpty { pasteboard.writeObjects(items) }
            return
        }

        try? await Task.sleep(for: .milliseconds(50))

        // Bug 157: re-check isTerminated before posting ⌘V.
        guard !targetApp.isTerminated else {
            pasteboard.clearContents()
            if let items = savedItems, !items.isEmpty { pasteboard.writeObjects(items) }
            return
        }

        postPasteEvent()

        // Bug 155: 600 ms delay for Electron apps (≥500 ms needed).
        try? await Task.sleep(for: .milliseconds(600))

        if pasteboard.string(forType: restoreTokenType) == restoreToken {
            pasteboard.clearContents()
            if let items = savedItems, !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    // Extracted secure-field probe (Bug 158): checks AXRole and kAXSecure.
    @MainActor
    private static func isSecureField() -> Bool {
        guard let focusedApp = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(focusedApp.processIdentifier)
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else { return false }
        let axElement = element as! AXUIElement
        var roleValue: CFTypeRef?
        let roleOk = AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success
        let role = (roleOk ? (roleValue as? String) : nil) ?? ""
        if role == "AXSecureTextField" { return true }
        // Bug 158: kAXSecure attribute catches browser password fields that
        // use AXTextArea + a secure flag instead of the AXSecureTextField role.
        let kAXSecure = "AXSecure" as CFString
        var secureValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXSecure, &secureValue) == .success,
           let flag = secureValue as? Bool, flag {
            return true
        }
        return false
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
        // key-up — guard so a nil result is never silently dropped (Bug 89)
        guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            logger.error("TextInjector: key-up CGEvent creation failed — V key may be stuck")
            return
        }
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
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
    /// Shift detection uses an explicit shiftedPunctuation set (Bug 94 fix).
    /// Shifted punctuation has no lowercase form so a lowercased() comparison
    /// would always return false. Letters still use isUppercase for Shift detection.
    static func keyCodeAndFlags(for char: String) -> (UInt16, CGEventFlags)? {
        guard let scalar = char.unicodeScalars.first else { return nil }
        // Check direct hit first (handles shifted punctuation entries in the map)
        if let (code, needsShift) = Self.charToKeyCode[scalar] {
            let flags: CGEventFlags = needsShift ? .maskShift : CGEventFlags(rawValue: 0)
            return (code, flags)
        }
        // For letters: look up lowercase version and derive Shift from case change
        guard let lowerScalar = char.lowercased().unicodeScalars.first,
              let (code, _) = Self.charToKeyCode[lowerScalar] else { return nil }
        // Use shiftedPunctuation set for explicit shift detection (Bug 94 fix)
        let isUppercaseLetter = char.first?.isLetter == true && char.first?.isUppercase == true
        let needsShift = Self.shiftedPunctuation.contains(char) || isUppercaseLetter
        let flags: CGEventFlags = needsShift ? .maskShift : CGEventFlags(rawValue: 0)
        return (code, flags)
    }

    /// Explicit set of characters that require the Shift key (Bug 94 fix).
    /// Using a lookup set avoids the broken lowercased() comparison heuristic.
    private static let shiftedPunctuation: Set<String> = [
        "!", "@", "#", "$", "%", "^", "&", "*", "(", ")", "_", "+",
        "{", "}", "|", ":", "\"", "<", ">", "?", "~"
    ]

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
        if !targetApp.activate(options: .activateIgnoringOtherApps) {
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
        // Shifted punctuation entries (Bug 94 fix): needsShift = true
        // These are the Shift+<key> characters on ANSI US layout.
        let shiftedKeys: [(Unicode.Scalar, UInt16)] = [
            ("!", 0x12), ("@", 0x13), ("#", 0x14), ("$", 0x15),
            ("%", 0x17), ("^", 0x16), ("&", 0x1A), ("*", 0x1C),
            ("(", 0x19), (")", 0x1D), ("_", 0x1B), ("+", 0x18),
            ("{", 0x21), ("}", 0x1E), ("|", 0x2A), (":", 0x29),
            ("\"", 0x27), ("<", 0x2B), (">", 0x2F), ("?", 0x2C),
            ("~", 0x32),
        ]
        for (char, code) in shiftedKeys { map[char] = (code, true) }
        return map
    }()
}
