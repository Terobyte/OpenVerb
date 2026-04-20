import Foundation
import AppKit
import Carbon
import ApplicationServices
import IOKit
import os

// ---------------------------------------------------------------------------
// HotkeyManager — global ⌥Space hotkey + Escape cancel gesture.
//
// ⌥Space:
//   Registered via CGEvent.tapCreate with .listenOnly (passive).
//   Requires Input Monitoring permission (System Settings › Privacy &
//   Security › Input Monitoring).  If tapCreate returns nil, the manager
//   checks IOHIDCheckAccess and shows an appropriate alert.
//
// Escape:
//   Two monitors are registered on IDLE→PREPARING so cancel works during
//   the cold-start window:
//   (1) NSEvent.addGlobalMonitorForEvents — catches Escape when the panel
//       is NOT the key window (typical nonactivatingPanel case).
//   (2) NSEvent.addLocalMonitorForEvents — catches Escape when the panel
//       IS key (rare but possible).
//   Both are deregistered on every transition to IDLE.
//
// Debounce: 300 ms — prevents state corruption from rapid double-taps.
//
// Hotkey conflict: if tapCreate fails but Input Monitoring IS granted,
//   show NSAlert offering three fixed alternatives (⌥\`, ⌃Space, ⌥⇧Space).
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "HotkeyManager")

@MainActor
final class HotkeyManager {

    // -----------------------------------------------------------------------
    // Callbacks wired up by OpenVerbApp
    // -----------------------------------------------------------------------

    var onToggleRecording:  (() -> Void)?
    var onCancelRecording:  (() -> Void)?
    var onAbortAndRestart:  (() -> Void)?

    // -----------------------------------------------------------------------
    // Private — hotkey configuration
    // -----------------------------------------------------------------------

    private struct HotKey {
        let virtualKey: CGKeyCode
        let flags: CGEventFlags

        static let altSpace     = HotKey(virtualKey: 0x31, flags: .maskAlternate)
        static let altBacktick  = HotKey(virtualKey: 0x32, flags: .maskAlternate)
        static let ctrlSpace    = HotKey(virtualKey: 0x31, flags: .maskControl)
        static let altShiftSpace = HotKey(virtualKey: 0x31, flags: [.maskAlternate, .maskShift])
    }

    private var hotKey: HotKey = .altSpace

    // Bug 18 fix: read user-configured hotkey from AppSettings instead of
    // hardcoding ⌥Space.  Applied on register() so the manager picks up the
    // latest preference each time the tap is (re)installed.
    private let settings = AppSettings.shared

    // -----------------------------------------------------------------------
    // Private — CGEvent tap state
    // -----------------------------------------------------------------------

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdogTimer: DispatchSourceTimer?

    // -----------------------------------------------------------------------
    // Private — Escape monitors
    // -----------------------------------------------------------------------

    private var globalEscapeMonitor: Any?
    private var localEscapeMonitor: Any?

    // -----------------------------------------------------------------------
    // Private — debounce
    // -----------------------------------------------------------------------

    private var lastToggleTime: Date = .distantPast
    private let debounceDuration: TimeInterval = 0.3

    // -----------------------------------------------------------------------
    // Register — installs the ⌥Space tap (Escape monitors are lazy).
    // -----------------------------------------------------------------------

    func register() {
        // Bug 18 fix: pull the user-configured hotkey from AppSettings so the
        // preference panel actually has an effect.  Falls back to ⌥Space if the
        // stored values match the default.
        hotKey = HotKey(virtualKey: settings.hotkeyKeyCode,
                        flags: settings.hotkeyModifiers)
        installEventTap(key: hotKey)
        // Always start the watchdog — it retries tap installation if permissions
        // are granted after startup (user may grant without relaunching the app).
        if eventTap == nil {
            startRetryWatchdog()
        }
    }

    /// Updates the active hotkey and reinstalls the CGEvent tap immediately.
    /// Call from a Combine observer to apply Preferences changes live without
    /// requiring an app restart.
    func configure(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        installEventTap(key: HotKey(virtualKey: keyCode, flags: modifiers))
    }

    private func installEventTap(key: HotKey) {
        // Remove any existing tap first.
        removeEventTap()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        // C function pointers cannot capture context.  Pass self as an
        // unretained raw pointer via userInfo; HotkeyManager lives for
        // the app's lifetime so the pointer is always valid.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                if let userInfo = userInfo {
                    let manager = Unmanaged<HotkeyManager>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    guard let copy = event.copy() else {
                        return Unmanaged.passUnretained(event)
                    }
                    DispatchQueue.main.async { manager.handleCGKeyEvent(copy) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )

        guard let tap = tap else {
            handleTapCreateFailure()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        hotKey = key
        startWatchdog(tap: tap)
        logger.info("Event tap installed (key: \(key.virtualKey), flags: \(key.flags.rawValue))")
    }

    private func removeEventTap() {
        stopWatchdog()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            // Bug 83: invalidate the Mach port so the kernel reclaims it.
            // Without this, each configure() call leaks one Mach port; the
            // per-process limit (~2048) is exhausted after ~2048 reconfigurations,
            // causing CGEvent.tapCreate to return nil and the hotkey to die silently.
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // -----------------------------------------------------------------------
    // Escape monitors — registered on IDLE→PREPARING, removed on →IDLE.
    // -----------------------------------------------------------------------

    func registerEscapeMonitors() {
        guard globalEscapeMonitor == nil else { return }

        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.handleEscape() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.handleEscape() }
            return event
        }
    }

    func removeEscapeMonitors() {
        if let m = globalEscapeMonitor { NSEvent.removeMonitor(m) }
        if let m = localEscapeMonitor  { NSEvent.removeMonitor(m) }
        globalEscapeMonitor = nil
        localEscapeMonitor = nil
    }

    // -----------------------------------------------------------------------
    // CGEvent key handler (main thread)
    // -----------------------------------------------------------------------

    private func handleCGKeyEvent(_ event: CGEvent) {
        let flags    = event.flags
        let keyCode  = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        guard keyCode == hotKey.virtualKey else { return }

        // For ⌥Space: flags must contain .maskAlternate and NOT other modifiers
        // (cmd, ctrl, shift) to avoid colliding with system shortcuts.
        // For custom keys the exact flag mask is matched.
        let relevant = flags.intersection([.maskAlternate, .maskControl, .maskShift, .maskCommand])
        guard relevant == hotKey.flags else { return }

        // 300 ms debounce.
        let now = Date()
        guard now.timeIntervalSince(lastToggleTime) >= debounceDuration else {
            logger.debug("Hotkey debounced")
            return
        }
        lastToggleTime = now

        logger.debug("⌥Space fired")
        onToggleRecording?()
    }

    // -----------------------------------------------------------------------
    // Escape handler (main thread via NSEvent monitor dispatch)
    // -----------------------------------------------------------------------

    private var escapeHandled = false   // per-event dedup flag

    private func handleEscape() {
        // Both global and local monitors may fire for the same keypress.
        // The escapeHandled flag is reset synchronously between events on the
        // main thread, so a simple boolean is sufficient (no lock needed on
        // @MainActor).
        guard !escapeHandled else { return }
        escapeHandled = true
        // Reset on next run loop turn so future events work correctly.
        DispatchQueue.main.async { [weak self] in self?.escapeHandled = false }

        logger.debug("Escape fired")
        onCancelRecording?()
    }

    // -----------------------------------------------------------------------
    // Unregister — called on deinit or when app terminates.
    // -----------------------------------------------------------------------

    func unregister() {
        removeEventTap()
        removeEscapeMonitors()
    }

    deinit {
        // removeEventTap and removeEscapeMonitors touch AppKit/CF objects.
        // HotkeyManager is owned exclusively by @MainActor objects so deinit
        // always runs on the main actor — unconditional cleanup is safe.
        MainActor.assumeIsolated {
            removeEventTap()
            removeEscapeMonitors()
        }
    }

    // -----------------------------------------------------------------------
    // Watchdog — re-enables the tap if macOS silently disables it.
    // -----------------------------------------------------------------------

    // Retry watchdog: used when tap creation failed at startup due to missing
    // permissions. Polls every 2 seconds until permissions are granted, then
    // installs the tap. Cancels itself once the tap is live.
    private func startRetryWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.eventTap == nil else {
                // Tap installed by someone else — stop retrying
                self.stopWatchdog()
                return
            }
            let axOk  = AXIsProcessTrusted()
            let hidOk = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            if axOk && hidOk {
                logger.info("Permissions now granted — installing event tap")
                self.installEventTap(key: self.hotKey)
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func startWatchdog(tap: CFMachPort) {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                logger.warning("Event tap disabled by macOS — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // -----------------------------------------------------------------------
    // Permission / conflict handling
    // -----------------------------------------------------------------------

    private func handleTapCreateFailure() {
        // Check Accessibility trust first — tapCreate requires AXIsProcessTrusted()
        // in addition to Input Monitoring. Missing either one returns nil with no error.
        if !AXIsProcessTrusted() {
            showAccessibilityAlert()
            return
        }
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access != kIOHIDAccessTypeGranted {
            showInputMonitoringAlert()
        } else {
            // Both permissions granted but tap still failed — likely a key conflict.
            showConflictAlert()
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            OpenVerb needs Accessibility permission to register the global ⌥Space hotkey.
            Please grant access in System Settings › Privacy & Security › Accessibility,
            then relaunch OpenVerb.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showInputMonitoringAlert() {
        let alert = NSAlert()
        alert.messageText = "Input Monitoring Permission Required"
        alert.informativeText = """
            OpenVerb needs Input Monitoring permission to detect the global ⌥Space hotkey.
            Please grant access in System Settings › Privacy & Security › Input Monitoring,
            then relaunch OpenVerb.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showConflictAlert() {
        guard let newKey = pickAlternativeHotkey() else { return }
        logger.info("Switching hotkey to alternative: \(newKey.virtualKey)")
        installEventTap(key: newKey)
        settings.hotkeyKeyCode = newKey.virtualKey
        settings.hotkeyModifiers = newKey.flags
    }

    private func pickAlternativeHotkey() -> HotKey? {
        let alert = NSAlert()
        alert.messageText = "⌥Space Is Already in Use"
        alert.informativeText = "Another app is using ⌥Space. Choose an alternative hotkey:"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        popup.addItems(withTitles: ["⌥` (backtick)", "⌃Space", "⌥⇧Space"])
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Selected Key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let alternatives: [HotKey] = [.altBacktick, .ctrlSpace, .altShiftSpace]
        let selected = popup.indexOfSelectedItem
        guard selected >= 0 && selected < alternatives.count else { return nil }
        return alternatives[selected]
    }
}
