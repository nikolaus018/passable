import Foundation

/// How a segment travels from one automation point to the next.
enum CurveShape: String, Codable, CaseIterable, Identifiable {
    case linear
    /// Slow start, fast finish — natural for fade-ins.
    case exponential
    /// Fast start, slow finish — natural for fade-outs.
    case logarithmic
    /// Ease in and out; the smoothest sounding filter sweeps.
    case sCurve
    /// Stay put, then jump at the next point: a hard cut on the beat.
    case hold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .exponential: return "Exponential"
        case .logarithmic: return "Logarithmic"
        case .sCurve: return "S-Curve"
        case .hold: return "Hold (Cut)"
        }
    }

    /// Maps progress 0…1 through the segment to interpolation 0…1.
    func shape(_ u: Double) -> Double {
        switch self {
        case .linear: return u
        case .exponential: return (exp(4 * u) - 1) / (exp(4) - 1)
        case .logarithmic: return 1 - (exp(4 * (1 - u)) - 1) / (exp(4) - 1)
        case .sCurve: return u * u * (3 - 2 * u)
        case .hold: return 0
        }
    }
}

struct AutomationPoint: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Seconds on the master timeline.
    var time: Double
    /// Normalised 0…1; see `LaneParameter` for the mapping to real units.
    var value: Double
    /// Shape of the segment leaving this point.
    var curve: CurveShape = .linear
}

struct Envelope: Codable, Equatable {
    private(set) var points: [AutomationPoint] = []

    var isEmpty: Bool { points.isEmpty }

    func value(at time: Double, default fallback: Double) -> Double {
        guard let first = points.first else { return fallback }
        if time <= first.time { return first.value }
        guard let last = points.last, time < last.time else { return points.last!.value }
        // Binary search for the segment containing `time`.
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let span = b.time - a.time
        guard span > 0 else { return b.value }
        let u = a.curve.shape((time - a.time) / span)
        return a.value + (b.value - a.value) * u
    }

    mutating func insert(_ point: AutomationPoint) {
        var p = point
        p.value = min(1, max(0, p.value))
        let index = points.firstIndex { $0.time > p.time } ?? points.count
        points.insert(p, at: index)
    }

    mutating func update(_ id: UUID, time: Double, value: Double) {
        guard let i = points.firstIndex(where: { $0.id == id }) else { return }
        var p = points.remove(at: i)
        p.time = time
        p.value = min(1, max(0, value))
        insert(p)
    }

    mutating func setCurve(_ id: UUID, _ curve: CurveShape) {
        guard let i = points.firstIndex(where: { $0.id == id }) else { return }
        points[i].curve = curve
    }

    mutating func remove(_ id: UUID) {
        points.removeAll { $0.id == id }
    }

    mutating func removeAll() { points.removeAll() }

    /// Removes points inside `range` (inclusive), used when a preset
    /// rewrites a region.
    mutating func clear(_ range: ClosedRange<Double>) {
        points.removeAll { range.contains($0.time) }
    }
}

/// Everything automatable on a stem channel. Values are stored normalised
/// 0…1 so one envelope editor can draw them all.
enum LaneParameter: Int, CaseIterable, Codable, Identifiable {
    case volume, filter, low, mid, high, reverb, delay

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .volume: return "Volume"
        case .filter: return "Filter"
        case .low: return "EQ Low"
        case .mid: return "EQ Mid"
        case .high: return "EQ High"
        case .reverb: return "Reverb Send"
        case .delay: return "Delay Send"
        }
    }

    var shortName: String {
        switch self {
        case .volume: return "VOL"
        case .filter: return "FLT"
        case .low: return "LOW"
        case .mid: return "MID"
        case .high: return "HI"
        case .reverb: return "REV"
        case .delay: return "DLY"
        }
    }

    var defaultValue: Double {
        switch self {
        case .volume: return 1
        case .filter, .low, .mid, .high: return 0.5
        case .reverb, .delay: return 0
        }
    }

    // MARK: Mappings (shared by the renderer and the UI)

    /// Linear gain. The top of the range is unity; fades are shaped by the
    /// curve, so the law itself stays linear and predictable.
    static func gain(_ v: Double) -> Float { Float(max(0, min(1, v))) }

    /// DJ-style single-knob filter: below centre is a low-pass sweeping down
    /// from 20 kHz to 60 Hz, above centre a high-pass sweeping up from 20 Hz
    /// to 10 kHz. A small dead zone around centre is a true bypass.
    enum FilterSetting: Equatable {
        case bypass
        case lowPass(Double)
        case highPass(Double)
    }

    static func filter(_ v: Double) -> FilterSetting {
        let d = v - 0.5
        if abs(d) < 0.01 { return .bypass }
        if d < 0 {
            let t = min(1, (-d - 0.01) / 0.49)
            return .lowPass(20_000 * pow(60.0 / 20_000, t))
        }
        let t = min(1, (d - 0.01) / 0.49)
        return .highPass(20 * pow(10_000.0 / 20, t))
    }

    /// EQ band gain in dB: centre is flat, up to +6 dB boost, down to a
    /// −40 dB "kill" (the classic DJ bass swap).
    static func eqDecibels(_ v: Double) -> Double {
        v >= 0.5 ? (v - 0.5) * 12 : (v - 0.5) * 80
    }

    func format(_ v: Double) -> String {
        switch self {
        case .volume, .reverb, .delay:
            let g = Double(Self.gain(v))
            return g <= 0.0001 ? "−∞ dB" : String(format: "%.1f dB", 20 * log10(g))
        case .filter:
            switch Self.filter(v) {
            case .bypass: return "Off"
            case .lowPass(let hz): return "LP \(Self.hz(hz))"
            case .highPass(let hz): return "HP \(Self.hz(hz))"
            }
        case .low, .mid, .high:
            let db = Self.eqDecibels(v)
            return db <= -39.5 ? "Kill" : String(format: "%+.1f dB", db)
        }
    }

    private static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }
}

enum DeckSide: String, Codable, CaseIterable, Identifiable {
    case a = "A", b = "B"
    var id: String { rawValue }
}

/// One of the eight stem channels on the timeline.
struct Lane: Identifiable, Equatable, Codable {
    let side: DeckSide
    let stem: StemKind
    var envelopes: [Envelope] = Array(repeating: Envelope(), count: LaneParameter.allCases.count)
    var isMuted = false
    var isSoloed = false
    var visibleParameter: LaneParameter = .volume

    var id: String { "\(side.rawValue).\(stem.rawValue)" }
    var title: String { "\(side.rawValue) · \(stem.displayName)" }

    subscript(parameter: LaneParameter) -> Envelope {
        get { envelopes[parameter.rawValue] }
        set { envelopes[parameter.rawValue] = newValue }
    }

    func value(_ parameter: LaneParameter, at time: Double) -> Double {
        envelopes[parameter.rawValue].value(at: time, default: parameter.defaultValue)
    }

    /// A and B of each stem sit next to each other, so a swap reads as one
    /// line going down while its neighbour comes up.
    static func allLanes() -> [Lane] {
        StemKind.laneOrder.flatMap { stem in DeckSide.allCases.map { Lane(side: $0, stem: stem) } }
    }
}
