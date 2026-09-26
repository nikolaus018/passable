import AppKit
import Combine
import SwiftUI

/// Which slice of the master timeline is on screen.
///
/// The timeline draws only what's visible into a fixed-size viewport rather
/// than laying out one enormous scrolling canvas: a four-minute mix zoomed to
/// beat level would be tens of thousands of points wide, past what a layer
/// can back.
@MainActor
final class TimelineViewport: ObservableObject {
    @Published var start: Double = 0
    @Published var pixelsPerSecond: Double = 20
    /// Lane-area frame in window coordinates, for routing scroll events.
    var frameInWindow: CGRect = .zero
    var width: Double = 800

    static let zoomRange = 2.0...600.0

    var visibleDuration: Double { width / pixelsPerSecond }

    func x(_ seconds: Double) -> CGFloat { CGFloat((seconds - start) * pixelsPerSecond) }
    func seconds(_ x: CGFloat) -> Double { start + Double(x) / pixelsPerSecond }

    func zoom(by factor: Double, around x: CGFloat) {
        let anchor = seconds(x)
        pixelsPerSecond = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, pixelsPerSecond * factor))
        start = anchor - Double(x) / pixelsPerSecond
    }

    func show(_ range: ClosedRange<Double>) {
        let span = max(1, range.upperBound - range.lowerBound)
        pixelsPerSecond = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, width / (span * 1.15)))
        start = range.lowerBound - span * 0.075
    }
}

struct TimelineArea: View {
    @EnvironmentObject private var session: Session
    @StateObject private var viewport = TimelineViewport()
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { outer in
            let laneHeight = max(44, (outer.size.height - Theme.rulerHeight - 40) / CGFloat(session.lanes.count))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        zoomControls.frame(height: Theme.rulerHeight)
                        ForEach(session.lanes) { lane in
                            LaneHeader(lane: lane).frame(height: laneHeight)
                        }
                    }
                    .frame(width: Theme.headerWidth)
                    Divider()
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                RulerView(viewport: viewport).frame(height: Theme.rulerHeight)
                                ForEach(session.lanes) { lane in
                                    LaneCanvas(lane: lane, viewport: viewport).frame(height: laneHeight)
                                }
                            }
                            PlayheadOverlay(viewport: viewport)
                                .allowsHitTesting(false)
                        }
                        .clipped()
                        .onAppear { updateFrame(geo) }
                        .onChange(of: geo.frame(in: .global)) { _, _ in updateFrame(geo) }
                    }
                }
                Divider()
                OverviewBar(viewport: viewport).frame(height: 40)
            }
        }
        .onAppear(perform: installMonitor)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
        .onReceive(session.transport.$seconds, perform: follow)
        .onChange(of: session.matched != nil) { _, ready in if ready { frameTransition() } }
        .onChange(of: session.entryBar) { _, _ in frameTransition() }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { viewport.zoom(by: 1 / 1.5, around: CGFloat(viewport.width / 2)) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { viewport.zoom(by: 1.5, around: CGFloat(viewport.width / 2)) } label: { Image(systemName: "plus.magnifyingglass") }
            Button("Fit") { frameTransition() }
                .help("Zoom to the transition")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updateFrame(_ geo: GeometryProxy) {
        viewport.width = geo.size.width
        viewport.frameInWindow = geo.frame(in: .global)
    }

    private func frameTransition() {
        guard let g = session.masterGrid, session.matched != nil else {
            viewport.show(0...max(10, session.lengthSeconds))
            return
        }
        let lead = session.preset == .echoOut ? 4.0 : 2.0
        viewport.show((session.transitionStart - lead * g.barSeconds)...(session.transitionEnd + 2 * g.barSeconds))
    }

    /// Page the view along with the playhead, like a DAW.
    private func follow(_ seconds: Double) {
        guard session.transport.isPlaying else { return }
        let x = viewport.x(seconds)
        if x > CGFloat(viewport.width) * 0.92 || x < 0 {
            viewport.start = seconds - viewport.visibleDuration * 0.08
        }
    }

    /// Two-finger scroll pans, ⌘-scroll and pinch zoom — routed by hand
    /// because the lanes are drawn, not scrolled.
    private func installMonitor() {
        guard monitor == nil else { return }
        let viewport = self.viewport
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard let window = event.window, let content = window.contentView else { return event }
            let loc = event.locationInWindow
            let point = CGPoint(x: loc.x, y: content.bounds.height - loc.y)
            let frame = viewport.frameInWindow
            guard frame.contains(point) else { return event }
            let localX = point.x - frame.minX
            MainActor.assumeIsolated {
                if event.type == .magnify {
                    viewport.zoom(by: 1 + event.magnification, around: localX)
                } else if event.modifierFlags.contains(.command) {
                    viewport.zoom(by: exp(event.scrollingDeltaY * 0.01), around: localX)
                } else {
                    let scale = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
                    let dx = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                    viewport.start -= dx * scale / viewport.pixelsPerSecond
                }
            }
            return nil
        }
    }
}

// MARK: - Lane header

struct LaneHeader: View {
    @EnvironmentObject private var session: Session
    let lane: Lane

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Theme.color(lane.side)).frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(lane.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    toggle("M", on: lane.isMuted, tint: .orange) { session.updateLane(lane.id) { $0.isMuted.toggle() } }
                    toggle("S", on: lane.isSoloed, tint: .yellow) { session.updateLane(lane.id) { $0.isSoloed.toggle() } }
                    Menu {
                        ForEach(LaneParameter.allCases) { p in
                            Button {
                                session.updateLane(lane.id) { $0.visibleParameter = p }
                            } label: {
                                Text(p.displayName + (lane[p].isEmpty ? "" : "  •"))
                            }
                        }
                    } label: {
                        Text(lane.visibleParameter.displayName).font(.system(size: 10))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background(Theme.color(lane.side).opacity(0.04))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toggle(_ label: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? tint : Color.primary.opacity(0.08)))
                .foregroundStyle(on ? Color.black : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Grid drawing shared by ruler and lanes

@MainActor
private func drawGrid(_ context: GraphicsContext, size: CGSize, viewport: TimelineViewport, grid: BeatGrid?, labels: Bool) {
    guard let g = grid else { return }
    let beatPx = g.beatSeconds * viewport.pixelsPerSecond
    let barPx = beatPx * 4
    // Thin out bar lines when zoomed far out.
    let barStep = barPx >= 18 ? 1 : barPx >= 5 ? 4 : 16
    let firstBar = Int(((viewport.start - g.firstDownbeat) / g.barSeconds).rounded(.down)) - 1
    let lastBar = Int(((viewport.seconds(size.width) - g.firstDownbeat) / g.barSeconds).rounded(.up)) + 1
    var bar = firstBar - ((firstBar % barStep) + barStep) % barStep
    while bar <= lastBar {
        let x = viewport.x(g.downbeat(bar))
        let phrase = bar % 16 == 0
        let strong = bar % 4 == 0
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(.primary.opacity(phrase ? 0.35 : strong ? 0.2 : 0.09)), lineWidth: phrase ? 1 : 0.5)
        if labels && bar >= 0 && (barPx >= 26 || strong) {
            context.draw(Text("\(bar + 1)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                         at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
        }
        if beatPx >= 14 {
            for beat in 1..<4 {
                let bx = viewport.x(g.downbeat(bar) + Double(beat) * g.beatSeconds)
                var p = Path()
                p.move(to: CGPoint(x: bx, y: labels ? size.height * 0.6 : 0))
                p.addLine(to: CGPoint(x: bx, y: size.height))
                context.stroke(p, with: .color(.primary.opacity(0.05)), lineWidth: 0.5)
            }
        }
        bar += barStep
    }
}

// MARK: - Ruler

struct RulerView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject var viewport: TimelineViewport

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.03)))
            if session.matched != nil {
                let x0 = viewport.x(session.transitionStart), x1 = viewport.x(session.transitionEnd)
                context.fill(Path(CGRect(x: min(x0, x1), y: 0, width: max(2, abs(x1 - x0)), height: size.height)),
                             with: .color(Theme.deckB.opacity(0.12)))
                context.draw(Text("B in").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.deckB),
                             at: CGPoint(x: x0 + 3, y: size.height - 3), anchor: .bottomLeading)
            }
            drawGrid(context, size: size, viewport: viewport, grid: session.masterGrid, labels: true)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            session.seek(to: viewport.seconds(value.location.x))
        })
        .overlay(alignment: .bottom) { Divider() }
        .help("Click or drag to move the playhead")
    }
}

// MARK: - Playhead

struct PlayheadOverlay: View {
    @EnvironmentObject private var transport: Transport
    @ObservedObject var viewport: TimelineViewport

    var body: some View {
        GeometryReader { geo in
            let x = viewport.x(transport.seconds)
            if x >= 0 && x <= geo.size.width {
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 1.5, height: geo.size.height)
                    .offset(x: x)
            }
        }
    }
}

// MARK: - Lane canvas

struct LaneCanvas: View {
    @EnvironmentObject private var session: Session
    let lane: Lane
    @ObservedObject var viewport: TimelineViewport
    @State private var hoverID: UUID?
    @State private var dragID: UUID?
    @State private var dragActive = false

    private var parameter: LaneParameter { lane.visibleParameter }
    private var envelope: Envelope { lane[parameter] }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            Canvas { context, size in draw(context, size) }
                .contentShape(Rectangle())
                .gesture(editGesture(height: height))
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hoverID = hit(p, height) } else { hoverID = nil }
                }
        }
        .background(Theme.color(lane.side).opacity(lane.isMuted ? 0.01 : 0.035))
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu { menu }
    }

    // MARK: Geometry

    private let inset: CGFloat = 6

    private func y(_ value: Double, _ height: CGFloat) -> CGFloat {
        inset + CGFloat(1 - value) * (height - 2 * inset)
    }

    private func value(_ y: CGFloat, _ height: CGFloat) -> Double {
        min(1, max(0, 1 - Double((y - inset) / (height - 2 * inset))))
    }

    private func hit(_ p: CGPoint, _ height: CGFloat) -> UUID? {
        envelope.points.first { point in
            let dx = viewport.x(point.time) - p.x
            let dy = y(point.value, height) - p.y
            return dx * dx + dy * dy < 81
        }?.id
    }

    // MARK: Editing

    private func editGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !dragActive {
                    dragActive = true
                    if let id = hit(drag.startLocation, height) {
                        dragID = id
                    } else {
                        let point = AutomationPoint(time: snappedTime(drag.startLocation.x),
                                                    value: value(drag.startLocation.y, height))
                        dragID = point.id
                        session.updateLane(lane.id) { $0[parameter].insert(point) }
                        return
                    }
                    session.checkpoint()
                }
                guard let id = dragID else { return }
                let t = snappedTime(drag.location.x)
                let v = value(drag.location.y, height)
                session.updateLane(lane.id, undoable: false) { $0[parameter].update(id, time: t, value: v) }
            }
            .onEnded { _ in
                dragActive = false
                dragID = nil
            }
    }

    /// Snaps to beats, or 16ths when zoomed in; hold ⌥ for free placement.
    private func snappedTime(_ x: CGFloat) -> Double {
        let t = viewport.seconds(x)
        if NSEvent.modifierFlags.contains(.option) { return t }
        let beatPx = (session.masterGrid?.beatSeconds ?? 0.5) * viewport.pixelsPerSecond
        return session.snap(t, division: beatPx > 60 ? 4 : 1)
    }

    @ViewBuilder private var menu: some View {
        if let id = hoverID, let point = envelope.points.first(where: { $0.id == id }) {
            Text("\(parameter.displayName): \(parameter.format(point.value))")
            Menu("Curve to Next Point") {
                ForEach(CurveShape.allCases) { shape in
                    Button {
                        session.updateLane(lane.id) { $0[parameter].setCurve(id, shape) }
                    } label: {
                        Text(shape.displayName + (point.curve == shape ? "  ✓" : ""))
                    }
                }
            }
            Button("Delete Point") { session.updateLane(lane.id) { $0[parameter].remove(id) } }
            Divider()
        }
        Button("Clear \(parameter.displayName) Automation") { session.updateLane(lane.id) { $0[parameter].removeAll() } }
        Button("Clear All Automation on \(lane.title)") {
            session.updateLane(lane.id) { l in LaneParameter.allCases.forEach { l[$0].removeAll() } }
        }
    }

    // MARK: Drawing

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let color = Theme.color(lane.side)

        if session.matched != nil || lane.side == .a {
            let x0 = viewport.x(session.transitionStart), x1 = viewport.x(session.transitionEnd)
            context.fill(Path(CGRect(x: min(x0, x1), y: 0, width: abs(x1 - x0), height: size.height)),
                         with: .color(Theme.deckB.opacity(0.05)))
        }
        drawGrid(context, size: size, viewport: viewport, grid: session.masterGrid, labels: false)

        if let peaks = session.peaks(for: lane) {
            drawWaveform(context, size, peaks: peaks, offset: session.laneOffset(lane), color: color)
        }
        drawAutomation(context, size, color: color)
    }

    /// Drawn twice: faintly as the raw stem, and solid scaled by the lane's
    /// fader automation — so the transition's shape is visible at a glance.
    private func drawWaveform(_ context: GraphicsContext, _ size: CGSize, peaks: [Float], offset: Double, color: Color) {
        let mid = size.height / 2
        let half = size.height / 2 - 3
        let hop = Double(TrackProcessor.peakHop) / AudioIO.sampleRate
        let width = Int(size.width)
        guard width > 0, !peaks.isEmpty else { return }
        var raw = [CGFloat](repeating: -1, count: width + 1)
        var faded = raw
        for px in 0...width {
            let t0 = viewport.seconds(CGFloat(px)) - offset
            let t1 = viewport.seconds(CGFloat(px + 1)) - offset
            var i0 = Int(t0 / hop), i1 = max(i0 + 1, Int(t1 / hop))
            guard i1 > 0, i0 < peaks.count else { continue }
            i0 = max(0, i0); i1 = min(peaks.count, i1)
            var peak: Float = 0
            for i in i0..<i1 where peaks[i] > peak { peak = peaks[i] }
            // Stems are rarely near full scale; a gentle curve keeps quiet
            // ones readable.
            let a = CGFloat(pow(min(1, peak * 1.2), 0.7))
            raw[px] = a
            let gain = lane.isMuted ? 0 : Double(LaneParameter.gain(lane.value(.volume, at: t0 + offset)))
            faded[px] = a * CGFloat(gain)
        }
        func shape(_ amps: [CGFloat]) -> Path {
            var path = Path()
            var px = 0
            while px <= width {
                guard amps[px] >= 0 else { px += 1; continue }
                let start = px
                while px <= width && amps[px] >= 0 { px += 1 }
                path.move(to: CGPoint(x: CGFloat(start), y: mid - amps[start] * half))
                for x in start..<px { path.addLine(to: CGPoint(x: CGFloat(x), y: mid - amps[x] * half)) }
                for x in (start..<px).reversed() { path.addLine(to: CGPoint(x: CGFloat(x), y: mid + amps[x] * half)) }
                path.closeSubpath()
            }
            return path
        }
        context.fill(shape(raw), with: .color(color.opacity(0.16)))
        context.fill(shape(faded), with: .color(color.opacity(lane.isMuted ? 0.15 : 0.62)))
    }

    private func drawAutomation(_ context: GraphicsContext, _ size: CGSize, color: Color) {
        let h = size.height
        var line = Path()
        let step: CGFloat = 2
        var x: CGFloat = 0
        while x <= size.width {
            let v = lane.value(parameter, at: viewport.seconds(x))
            let p = CGPoint(x: x, y: y(v, h))
            if x == 0 { line.move(to: p) } else { line.addLine(to: p) }
            x += step
        }
        let isDefault = envelope.isEmpty
        context.stroke(line, with: .color(isDefault ? Color.primary.opacity(0.25) : .yellow),
                       style: StrokeStyle(lineWidth: isDefault ? 1 : 1.6, dash: isDefault ? [3, 3] : []))

        for point in envelope.points {
            let px = viewport.x(point.time)
            guard px > -10 && px < size.width + 10 else { continue }
            let active = point.id == hoverID || point.id == dragID
            let r: CGFloat = active ? 5.5 : 3.8
            let rect = CGRect(x: px - r, y: y(point.value, h) - r, width: 2 * r, height: 2 * r)
            context.fill(Path(ellipseIn: rect), with: .color(.yellow))
            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.6)), lineWidth: 1)
            if active {
                let label = Text(parameter.format(point.value)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                context.draw(label.foregroundColor(.primary),
                             at: CGPoint(x: px + 8, y: max(8, min(h - 8, y(point.value, h)))), anchor: .leading)
            }
        }

        context.draw(Text(parameter.shortName).font(.system(size: 9, weight: .bold)).foregroundColor(.yellow.opacity(0.8)),
                     at: CGPoint(x: size.width - 6, y: 4), anchor: .topTrailing)
    }
}

// MARK: - Overview

/// The whole mix in miniature, with the visible window outlined. Click or
/// drag to move the view.
struct OverviewBar: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var transport: Transport
    @ObservedObject var viewport: TimelineViewport

    var body: some View {
        GeometryReader { geo in
            let total = max(1, session.lengthSeconds)
            let scale = geo.size.width / total
            Canvas { context, size in
                for side in DeckSide.allCases {
                    let lanes = session.lanes.filter { $0.side == side }
                    guard let first = lanes.first, session.peaks(for: first) != nil else { continue }
                    let offset = side == .a ? 0 : session.offsetB
                    var path = Path()
                    let hop = Double(TrackProcessor.peakHop) / AudioIO.sampleRate
                    let mid = size.height / 2
                    for px in 0..<Int(size.width) {
                        let t0 = Double(px) / scale - offset, t1 = Double(px + 1) / scale - offset
                        let i0 = max(0, Int(t0 / hop))
                        var peak: Float = 0
                        for lane in lanes {
                            guard let peaks = session.peaks(for: lane) else { continue }
                            let i1 = min(peaks.count, Int(t1 / hop))
                            guard i1 > i0 else { continue }
                            let gain = LaneParameter.gain(lane.value(.volume, at: t0 + offset))
                            for i in stride(from: i0, to: i1, by: 4) { peak = max(peak, peaks[i] * gain) }
                        }
                        guard peak > 0 else { continue }
                        let a = CGFloat(min(1, peak)) * (mid - 2)
                        path.addRect(CGRect(x: CGFloat(px), y: mid - a, width: 1, height: 2 * a))
                    }
                    context.fill(path, with: .color(Theme.color(side).opacity(0.55)))
                }
                let vx = CGFloat(viewport.start) * scale
                let vw = CGFloat(viewport.visibleDuration) * scale
                let rect = CGRect(x: vx, y: 1, width: max(4, vw), height: size.height - 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.primary.opacity(0.07)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(.primary.opacity(0.5)), lineWidth: 1)
                let px = CGFloat(transport.seconds) * scale
                context.fill(Path(CGRect(x: px, y: 0, width: 1, height: size.height)), with: .color(.primary))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                viewport.start = Double(value.location.x / scale) - viewport.visibleDuration / 2
            })
        }
        .background(Color.primary.opacity(0.03))
    }
}
