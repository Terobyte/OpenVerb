import SwiftUI
import AppKit
import ApplicationServices
import os

// ---------------------------------------------------------------------------
// ShortcutRecorderView — SwiftUI wrapper for ShortcutCaptureView.
//
// Displays the currently recorded key combo (via hotkeyDescription computed
// from keyCode + modifiers) and listens for a new key combo when focused.
//
// Usage in PreferencesView:
//   ShortcutRecorderView(keyCode: $settings.hotkeyKeyCode,
//                        modifiers: Binding(...))
//   .frame(height: 28)
// ---------------------------------------------------------------------------

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var keyCode: UInt16
    @Binding var modifiers: CGEventFlags

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.onCapture = { code, mods in
            keyCode = code
            modifiers = mods
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {}
}

// ---------------------------------------------------------------------------
// ShortcutCaptureView — NSView that captures a key combo on click.
//
// Click → enters recording mode → shows "Press a key combo… (Esc to cancel)".
// Any key + modifier captured → fires onCapture callback → exits recording mode.
// Escape → cancels recording without updating the hotkey.
//
// Requires at least one modifier (⌥/⌃/⇧/⌘) to avoid capturing bare letter
// keys that would break normal text input in other fields.
// ---------------------------------------------------------------------------

final class ShortcutCaptureView: NSView {

    var onCapture: ((UInt16, CGEventFlags) -> Void)?

    private var isRecording = false
    private var localMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isRecording { startRecording() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg: NSColor = isRecording
            ? .controlAccentColor.withAlphaComponent(0.15)
            : .controlBackgroundColor
        bg.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()

        let text = isRecording
            ? "Press a key combo\u{2026} (Esc to cancel)"
            : "Click to record"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    private func startRecording() {
        isRecording = true
        needsDisplay = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {  // Escape
                self.stopRecording()
                return nil
            }
            let mods = event.modifierFlags
            let hasMod = mods.contains(.option) || mods.contains(.control)
                || mods.contains(.shift) || mods.contains(.command)
            if hasMod {
                var flags = CGEventFlags(rawValue: 0)
                if mods.contains(.option)  { flags.insert(.maskAlternate) }
                if mods.contains(.control) { flags.insert(.maskControl) }
                if mods.contains(.shift)   { flags.insert(.maskShift) }
                if mods.contains(.command) { flags.insert(.maskCommand) }
                self.onCapture?(event.keyCode, flags)
                self.stopRecording()
            }
            return nil  // consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        needsDisplay = true
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}
