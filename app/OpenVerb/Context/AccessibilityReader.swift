import ApplicationServices
import AppKit
import os

protocol AccessibilityReadable {
    func readWindowTitle(for app: NSRunningApplication) -> String?
    func readSelectedText(for app: NSRunningApplication) -> String?
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
}
