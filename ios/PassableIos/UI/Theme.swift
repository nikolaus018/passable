import SwiftUI
import UIKit

/// The look of Passable: the Mac app's two deck colours (blue, orange)
/// alternate from song to song, so the phone shows a blend the way the desk
/// does, as one colour handing over to the other.
enum Theme {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
        func mixed(with other: RGB, _ t: Double) -> RGB {
            let t = min(1, max(0, t))
            return RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }
    }

    static let deckARGB = RGB(r: 0.36, g: 0.62, b: 1.0)
    static let deckBRGB = RGB(r: 1.0, g: 0.52, b: 0.32)
    static let deckA = deckARGB.color
    static let deckB = deckBRGB.color

    static let background = Color(red: 0.035, green: 0.035, blue: 0.06)
    static let card = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.10)

    /// Even songs ride the blue deck, odd songs the orange one.
    static func deckRGB(_ songIndex: Int) -> RGB { songIndex.isMultiple(of: 2) ? deckARGB : deckBRGB }
    static func deck(_ songIndex: Int) -> Color { deckRGB(songIndex).color }

    /// 3:07 or 1:02:09.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "58 min" or "1 h 12 min".
    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(max(1, minutes)) min"
    }
}

enum Haptics {
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

extension String {
    /// A number that stays the same from launch to launch (Swift's own
    /// `hashValue` doesn't), so a song keeps its artwork.
    var stableHash: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return h
    }
}
