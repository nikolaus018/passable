import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let deckA = Color(red: 0.36, green: 0.62, blue: 1.0)
    static let deckB = Color(red: 1.0, green: 0.52, blue: 0.32)
    static let laneHeight: CGFloat = 70
    static let rulerHeight: CGFloat = 30
    static let headerWidth: CGFloat = 176

    static func color(_ side: DeckSide) -> Color { side == .a ? deckA : deckB }

    static func time(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// Keeps the window inside the screen's visible area (clear of the menu
/// bar and the Dock) when it opens, so the transport is never hidden.
struct WindowFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum OpenPanel {
    @MainActor
    static func choose(_ handler: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { handler(url) }
    }

    @MainActor
    static func chooseMany(_ handler: ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, !panel.urls.isEmpty { handler(panel.urls) }
    }

    @MainActor
    static func save(name: String, _ handler: (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { handler(url) }
    }
}
