import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// SubtitlePanel — floating child panel that shows live partial transcription
// text below the RecordingWindow HUD.
//
// Lifecycle:
//   • Created once by RecordingWindow on first show(); reused across sessions.
//   • Attached as a child window (ordered above) so it moves with the parent
//     and is hidden automatically when the parent hides.
//   • deinit removes itself from the parent to break the AppKit retain cycle.
//
// Positioning: horizontally centred below the parent, with 8 pt gap.
// ---------------------------------------------------------------------------

final class SubtitlePanel: NSPanel {

    // -----------------------------------------------------------------------
    // Init
    // -----------------------------------------------------------------------

    init(appState: AppState, settings: AppSettings) {
        let rect = NSRect(origin: .zero, size: NSSize(width: 360, height: 56))
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isOpaque = false
        self.appearance = nil
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let content = SubtitleContentView(appState: appState, settings: settings)
        let hosting = NSHostingView(rootView: content)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        self.contentView = hosting
    }

    deinit {
        if let parent = self.parent {
            parent.removeChildWindow(self)
        }
    }

    // -----------------------------------------------------------------------
    // attach — adds self as a child of parent and positions below it.
    // Safe to call multiple times (NSPanel ignores duplicate addChildWindow).
    // -----------------------------------------------------------------------

    func attach(to parent: NSWindow) {
        if self.parent == nil {
            parent.addChildWindow(self, ordered: .above)
        }
        reposition(relativeTo: parent)
    }

    // -----------------------------------------------------------------------
    // reposition — centres the panel below parent with an 8 pt gap.
    // -----------------------------------------------------------------------

    func reposition(relativeTo parent: NSWindow) {
        let pf = parent.frame
        let origin = NSPoint(
            x: pf.midX - frame.width / 2,
            y: pf.minY - frame.height - 8
        )
        setFrameOrigin(origin)
    }
}

// ---------------------------------------------------------------------------
// SubtitleContentView — SwiftUI content embedded in SubtitlePanel.
// ---------------------------------------------------------------------------

private struct SubtitleContentView: View {

    @ObservedObject var appState: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            if settings.showSubtitlePanel && !appState.livePartialText.isEmpty {
                Text(appState.livePartialText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
                    .animation(.easeInOut(duration: 0.12), value: appState.livePartialText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
