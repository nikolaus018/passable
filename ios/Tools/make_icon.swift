import AppKit
import CoreGraphics

// Draws the app icon: two overlapping deck-coloured discs and a waveform.
let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)

// Background
let bg = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.07, green: 0.07, blue: 0.12, alpha: 1),
                                                  CGColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

func disc(cx: CGFloat, cy: CGFloat, r: CGFloat, color: CGColor) {
    ctx.saveGState()
    let g = CGGradient(colorsSpace: space, colors: [color.copy(alpha: 0.95)!, color.copy(alpha: 0.55)!] as CFArray, locations: [0, 1])!
    ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx - r * 0.3, y: cy + r * 0.3), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}
let blue = CGColor(red: 0.36, green: 0.62, blue: 1.0, alpha: 1)
let orange = CGColor(red: 1.0, green: 0.52, blue: 0.32, alpha: 1)
ctx.setBlendMode(.screen)
disc(cx: s * 0.37, cy: s * 0.5, r: s * 0.30, color: blue)
disc(cx: s * 0.63, cy: s * 0.5, r: s * 0.30, color: orange)
ctx.setBlendMode(.normal)

// Waveform bars across both discs
let bars = 15
let barW = s * 0.034, gap = s * 0.026
let total = CGFloat(bars) * barW + CGFloat(bars - 1) * gap
let heights: [CGFloat] = [0.10, 0.18, 0.30, 0.22, 0.42, 0.34, 0.56, 0.70, 0.52, 0.38, 0.46, 0.26, 0.32, 0.16, 0.09]
for i in 0..<bars {
    let h = heights[i] * s * 0.62
    let x = (s - total) / 2 + CGFloat(i) * (barW + gap)
    let rect = CGRect(x: x, y: (s - h) / 2, width: barW, height: h)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let data = rep.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
