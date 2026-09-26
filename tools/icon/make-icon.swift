// Draws Passable's app icon: a waveform crossfading from deck A's blue to
// deck B's orange, with the two fade curves crossing where one song passes
// to the next. Run: swift tools/icon/make-icon.swift <out.png>
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
let blue = (0.36, 0.62, 1.0), orange = (1.0, 0.52, 0.32)
func mix(_ t: Double, _ a: Double = 1) -> CGColor {
    rgb(blue.0 + (orange.0 - blue.0) * t, blue.1 + (orange.1 - blue.1) * t, blue.2 + (orange.2 - blue.2) * t, a)
}

// macOS icon grid: an 824 pt rounded square centred on the canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(shape); ctx.setFillColor(rgb(0.06, 0.07, 0.13)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// Night-club dark, a touch lighter at the top.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0.13, 0.14, 0.27), rgb(0.04, 0.04, 0.09)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// Each deck's glow on its own side.
for (x, t) in [(300.0, 0.0), (724.0, 1.0)] {
    let glow = CGGradient(colorsSpace: space, colors: [mix(t, 0.30), mix(t, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: x, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: x, y: 512), endRadius: 380, options: [])
}

// The waveform: A loud on the left, B loud on the right, both sharing the
// middle, like a blend. Mirrored around the centre line.
let count = 15
let left = 196.0, right = 828.0
let step = (right - left) / Double(count - 1)
let barWidth = step * 0.56
let shapeNoise: [Double] = [0.62, 0.88, 0.7, 1.0, 0.78, 0.93, 0.66, 0.84, 0.72, 0.97, 0.8, 0.9, 0.68, 0.95, 0.74]
for i in 0..<count {
    let t = Double(i) / Double(count - 1)
    let x = left + Double(i) * step
    // Equal-power crossfade: the sum of the two decks stays full.
    let a = cos(t * .pi / 2), b = sin(t * .pi / 2)
    let level = max(a, b) * 0.78 + 0.22
    let h = 470 * level * shapeNoise[i]
    let rect = CGRect(x: x - barWidth / 2, y: 470 - h / 2, width: barWidth, height: h)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.clip()
    let bar = CGGradient(colorsSpace: space, colors: [mix(t, 0.9), mix(t, 0.5)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bar, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()
}

// The two fade curves, crossing at the handover.
func curve(_ fadeIn: Bool) -> CGPath {
    let p = CGMutablePath()
    for i in 0...100 {
        let t = Double(i) / 100
        let v = fadeIn ? sin(t * .pi / 2) : cos(t * .pi / 2)
        let pt = CGPoint(x: 196 + t * 632, y: 360 + v * 390)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    return p
}
ctx.setLineCap(.round)
for (fadeIn, t) in [(false, 0.0), (true, 1.0)] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: mix(t, 1))
    ctx.addPath(curve(fadeIn)); ctx.setStrokeColor(mix(t == 0 ? 0.08 : 0.92)); ctx.setLineWidth(22); ctx.strokePath()
    ctx.addPath(curve(fadeIn)); ctx.setStrokeColor(rgb(1, 1, 1, 0.55)); ctx.setLineWidth(7); ctx.strokePath()
    ctx.restoreGState()
}
// The pass point.
let cross = CGPoint(x: 196 + 0.5 * 632, y: 360 + cos(Double.pi / 4) * 390)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: rgb(1, 1, 1, 0.9))
ctx.setFillColor(rgb(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: cross.x - 30, y: cross.y - 30, width: 60, height: 60))
ctx.restoreGState()

// A thin rim of light, like glass.
ctx.addPath(shape); ctx.setStrokeColor(rgb(1, 1, 1, 0.10)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
