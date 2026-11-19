import SwiftUI

/// Cover art made from a name: a gradient, a glow and the rings of a record.
/// The same text always gives the same picture.
struct ArtworkView: View {
    let seed: String

    private struct Palette {
        let a: Color, b: Color, c: Color
        let dx: Double, dy: Double

        init(_ seed: String) {
            let h = seed.stableHash
            func unit(_ shift: UInt64) -> Double { Double((h >> shift) & 0xFF) / 255 }
            let hue = unit(0)
            let spread = 0.10 + unit(8) * 0.12
            a = Color(hue: hue, saturation: 0.62 + unit(16) * 0.22, brightness: 0.88)
            b = Color(hue: (hue + spread).truncatingRemainder(dividingBy: 1), saturation: 0.80, brightness: 0.52)
            c = Color(hue: (hue + 0.5 + spread / 2).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.95)
            dx = unit(24) * 2 - 1
            dy = unit(32) * 2 - 1
        }
    }

    var body: some View {
        let p = Palette(seed)
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                LinearGradient(colors: [p.a, p.b], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(p.c.opacity(0.50))
                    .frame(width: s * 0.85).blur(radius: s * 0.13)
                    .offset(x: s * 0.26 * p.dx, y: s * 0.24 * p.dy)
                Circle().fill(p.b.opacity(0.65))
                    .frame(width: s * 0.6).blur(radius: s * 0.10)
                    .offset(x: -s * 0.28 * p.dx, y: -s * 0.20 * p.dy)
                ForEach(0..<7, id: \.self) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.045 + 0.012 * Double(i % 3)), lineWidth: max(0.5, s * 0.004))
                        .frame(width: s * (0.30 + 0.115 * Double(i)))
                }
                Circle().fill(Color.black.opacity(0.28)).frame(width: s * 0.17)
                Circle().fill(Color.white.opacity(0.92)).frame(width: s * 0.022)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack {
        ArtworkView(seed: "Daft Punk - One More Time")
        ArtworkView(seed: "Blue Monday")
        ArtworkView(seed: "Strings of Life")
    }
    .padding()
    .background(Theme.background)
}
