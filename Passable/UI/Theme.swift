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
    static func save(name: String, _ handler: (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { handler(url) }
    }
}
