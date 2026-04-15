import AppKit
import os

// ---------------------------------------------------------------------------
// StatusBarItem — NSStatusBar menu bar item with state-driven icon updates.
//
// States:
//   idle      — plain microphone icon (mic.fill)
//   recording — red tinted icon (recording in progress)
//   inferring — template icon with pulsing alpha (inference running)
//   error     — yellow exclamation overlay
//
// Menu:
//   About OpenVerb
//   Engine status (dynamic label, disabled)
//   ─────────────
//   Quit OpenVerb
// ---------------------------------------------------------------------------

private let logger = Logger(subsystem: "io.openverb.app", category: "StatusBarItem")

@MainActor
final class StatusBarItem {

    // -----------------------------------------------------------------------
    // Private — status item
    // -----------------------------------------------------------------------

    private let item: NSStatusItem
    private var stateObserver: Any?
    private var engineObserver: Any?
    private var pulseTimer: Timer?
    private var pulsePhase: Bool = false

    // -----------------------------------------------------------------------
    // Init
    // -----------------------------------------------------------------------

    init(appState: AppState, engineManager: EngineManager) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        applyIcon(for: appState.state)

        // Observe AppState changes.
        stateObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyIcon(for: appState.state)
        }

        // Observe engine status via KVO is not straightforward; use a polling
        // approach via the published property.  In practice the full app wires
        // this up via Combine subscribers in AppDelegate.
    }

    deinit {
        if let obs = stateObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // -----------------------------------------------------------------------
    // showStatus / clearStatus — temporary status message on the menu bar item.
    // -----------------------------------------------------------------------

    func showStatus(_ text: String) {
        guard let button = item.button else { return }
        button.toolTip = text
    }

    func clearStatus() {
        guard let button = item.button else { return }
        button.toolTip = nil
    }

    // -----------------------------------------------------------------------
    // updateState — called by AppDelegate when AppState.state changes.
    // -----------------------------------------------------------------------

    func updateState(_ state: AppState.State) {
        applyIcon(for: state)
    }

    // -----------------------------------------------------------------------
    // updateEngineStatus — called by AppDelegate when EngineManager.status changes.
    // -----------------------------------------------------------------------

    func updateEngineStatus(_ status: EngineManager.EngineStatus) {
        updateEngineMenuItem(for: status)
    }

    // -----------------------------------------------------------------------
    // Private — icon rendering
    // -----------------------------------------------------------------------

    private func applyIcon(for state: AppState.State) {
        guard let button = item.button else { return }

        switch state {
        case .idle, .preparing:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "OpenVerb")
            button.image?.isTemplate = true
            button.contentTintColor = nil

        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed

        case .inferring:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Processing")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            startPulsing()

        case .error:
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemYellow, .white])
            button.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Error"
            )?.withSymbolConfiguration(config)
            button.image?.isTemplate = false
            button.contentTintColor = nil
        }

        // Restore alpha for non-inferring states.
        if case .inferring = state { } else {
            button.alphaValue = 1.0
            stopPulsing()
        }
    }

    // -----------------------------------------------------------------------
    // Private — pulsing animation for inferring state.
    // -----------------------------------------------------------------------

    private func startPulsing() {
        stopPulsing()
        pulsePhase = false
        guard let button = item.button else { return }
        button.alphaValue = 1.0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let button = self.item.button else { return }
            self.pulsePhase.toggle()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                ctx.allowsImplicitAnimation = true
                button.alphaValue = self.pulsePhase ? 0.35 : 1.0
            }
        }
    }

    private func stopPulsing() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    // -----------------------------------------------------------------------
    // Private — menu construction
    // -----------------------------------------------------------------------

    private func buildMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About OpenVerb",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(engineStatusMenuItem())
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit OpenVerb",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu
    }

    private func engineStatusMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Engine: stopped", action: nil, keyEquivalent: "")
        item.tag = 1   // Used to find and update this item later.
        item.isEnabled = false
        return item
    }

    private func updateEngineMenuItem(for status: EngineManager.EngineStatus) {
        guard let menu = item.menu,
              let engineItem = menu.item(withTag: 1) else { return }
        switch status {
        case .stopped:  engineItem.title = "Engine: stopped"
        case .starting: engineItem.title = "Loading model..."
        case .running:  engineItem.title = "Engine: running"
        case .error(let msg): engineItem.title = "Engine error: \(msg)"
        }
    }

    // -----------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
