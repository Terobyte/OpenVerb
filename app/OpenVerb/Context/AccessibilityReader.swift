import ApplicationServices
import AppKit
import os

protocol AccessibilityReadable {
    func readWindowTitle(for app: NSRunningApplication) -> String?
    func readSelectedText(for app: NSRunningApplication) -> String?
    /// Returns the text immediately before and after the cursor in the focused
    /// text field, using kAXValueAttribute and kAXSelectedTextRangeAttribute.
    /// Returns (before: "", after: "") when the surrounding text is unavailable.
    func readCursorSurroundingText(for app: NSRunningApplication) -> (before: String, after: String)
}

struct AccessibilityReader: AccessibilityReadable {
    private let logger = Logger(subsystem: "io.openverb.app", category: "AccessibilityReader")

    func readWindowTitle(for app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard err == .success, let window = focusedWindow else {
            logger.debug("readWindowTitle: no focused window for pid \(pid), error \(err.rawValue)")
            return nil
        }
        guard CFGetTypeID(window as CFTypeRef) == AXUIElementGetTypeID() else {
            logger.debug("readWindowTitle: focusedWindow is not AXUIElement")
            return nil
        }

        var title: AnyObject?
        let titleErr = AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXTitleAttribute as CFString,
            &title
        )
        guard titleErr == .success else {
            logger.debug("readWindowTitle: no title attribute, error \(titleErr.rawValue)")
            return nil
        }

        return title as? String
    }

    func readSelectedText(for app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard err == .success, let element = focusedElement else {
            logger.debug("readSelectedText: no focused element for pid \(pid), error \(err.rawValue)")
            return nil
        }
        guard CFGetTypeID(element as CFTypeRef) == AXUIElementGetTypeID() else {
            logger.debug("readSelectedText: focusedElement is not AXUIElement")
            return nil
        }

        var selectedText: AnyObject?
        let selErr = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )
        guard selErr == .success else {
            logger.debug("readSelectedText: no selected text, error \(selErr.rawValue)")
            return nil
        }

        let text = selectedText as? String
        if let text, !text.isEmpty {
            return text
        }
        return nil
    }

    func readCursorSurroundingText(for app: NSRunningApplication) -> (before: String, after: String) {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard err == .success,
              let element = focusedElement,
              CFGetTypeID(element as CFTypeRef) == AXUIElementGetTypeID() else {
            logger.debug("readCursorSurroundingText: no focused element for pid \(pid)")
            return (before: "", after: "")
        }

        let axElement = element as! AXUIElement

        // Read the full text content of the field via kAXValueAttribute.
        var valueObj: AnyObject?
        guard AXUIElementCopyAttributeValue(axElement,
                                             kAXValueAttribute as CFString,
                                             &valueObj) == .success,
              let fullText = valueObj as? String else {
            logger.debug("readCursorSurroundingText: no value attribute for pid \(pid)")
            return (before: "", after: "")
        }

        // Read the cursor range via kAXSelectedTextRangeAttribute.
        var rangeObj: AnyObject?
        guard AXUIElementCopyAttributeValue(axElement,
                                             kAXSelectedTextRangeAttribute as CFString,
                                             &rangeObj) == .success else {
            logger.debug("readCursorSurroundingText: no selected-text-range for pid \(pid)")
            return (before: "", after: "")
        }

        // Unpack the CFRange from the AXValue.
        // AXValue is a CoreFoundation type; verify via CFTypeID before force-casting.
        var cfRange = CFRange()
        guard let rangeValue = rangeObj,
              CFGetTypeID(rangeValue as CFTypeRef) == AXValueGetTypeID() else {
            logger.debug("readCursorSurroundingText: range attribute is not AXValue for pid \(pid)")
            return (before: "", after: "")
        }
        let axValue = rangeValue as! AXValue
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else {
            logger.debug("readCursorSurroundingText: failed to unpack CFRange for pid \(pid)")
            return (before: "", after: "")
        }

        // cfRange.location is a UTF-16 code unit offset.
        let nsString = fullText as NSString
        let totalLen = nsString.length

        // Clamp cursor position to valid range.
        let cursorPos = min(max(cfRange.location, 0), totalLen)

        let beforeNS  = nsString.substring(to: cursorPos)
        let afterStart = min(cursorPos + max(cfRange.length, 0), totalLen)
        let afterNS   = nsString.substring(from: afterStart)

        return (before: beforeNS, after: afterNS)
    }
}
