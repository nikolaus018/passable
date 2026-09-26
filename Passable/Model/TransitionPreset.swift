import Foundation

/// Ready-made stem choreographies. Each writes automation relative to the
/// moment B enters, measured in bars of the master (A) grid, so they land on
/// phrase boundaries whatever the tempo.
enum TransitionPreset: String, CaseIterable, Identifiable {
    case stemSwap, dropSwap, longBlend, echoOut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stemSwap: return "Stem Swap"
        case .dropSwap: return "Drop Swap"
        case .longBlend: return "Long Blend"
        case .echoOut: return "Echo Out"
        }
    }

    var summary: String {
        switch self {
        case .stemSwap:
            return "B's drums build in under a high-pass, melody follows, basses swap hard on the half, A washes out, B's vocal arrives last."
        case .dropSwap:
            return "B's drums build filtered, then everything swaps at once on the drop while A's melody and vocal echo away."
        case .longBlend:
            return "A slow EQ blend: B fades up with its low end killed, the lows trade places mid-way, A filters out."
        case .echoOut:
            return "A echoes out over the bar(s) before B's entry, then B slams in on the downbeat. No overlap, no clashes."
        }
    }

    var defaultBars: Int {
        switch self {
        case .stemSwap: return 16
        case .dropSwap: return 8
        case .longBlend: return 32
        case .echoOut: return 1
        }
    }
}

struct TransitionBuilder {
    /// Master-timeline seconds where B enters (bar 0 of the transition).
    let start: Double
    let barSeconds: Double
    let bars: Int
    /// Bar (from B's entry) where B's vocal comes in; nil = end of the blend.
    let vocalBar: Int?
    private(set) var lanes: [Lane]

    init(lanes: [Lane], start: Double, barSeconds: Double, bars: Int, vocalBar: Int? = nil) {
        self.lanes = lanes
        self.start = start
        self.barSeconds = barSeconds
        self.bars = bars
        self.vocalBar = vocalBar
    }

    static func build(_ preset: TransitionPreset, lanes: [Lane], start: Double, barSeconds: Double, bars: Int,
                      vocalBar: Int? = nil) -> [Lane] {
        var builder = TransitionBuilder(lanes: lanes, start: start, barSeconds: barSeconds, bars: bars, vocalBar: vocalBar)
        builder.clearAll()
        builder.write(preset)
        return builder.lanes
    }

    private mutating func clearAll() {
        for i in lanes.indices {
            for p in LaneParameter.allCases { lanes[i][p].removeAll() }
        }
    }

    /// Writes `points` (bar, value, curve-leaving-this-point) on one lane.
    private mutating func automate(_ side: DeckSide, _ stem: StemKind, _ parameter: LaneParameter,
                                   _ points: [(Double, Double, CurveShape)]) {
        guard let i = lanes.firstIndex(where: { $0.side == side && $0.stem == stem }) else { return }
        for (bar, value, curve) in points {
            lanes[i][parameter].insert(AutomationPoint(time: start + bar * barSeconds, value: value, curve: curve))
        }
    }

    private mutating func write(_ preset: TransitionPreset) {
        let n = Double(bars)
        // Never before A's vocal is out (the swap), never after the end.
        let v = min(n, max(n / 2, Double(vocalBar ?? bars)))
        switch preset {
        case .stemSwap:
            let q = n / 4
            // B drums build in, high-passed so they don't fight A's kick.
            automate(.b, .drums, .volume, [(0, 0, .exponential), (q, 1, .linear)])
            automate(.b, .drums, .filter, [(0, 0.82, .sCurve), (2 * q, 0.5, .linear)])
            // B melody follows.
            automate(.b, .other, .volume, [(q, 0, .exponential), (2 * q, 1, .linear)])
            // Hard bass swap on the half-way downbeat: two basses never overlap.
            automate(.a, .bass, .volume, [(2 * q, 1, .hold), (2 * q + 0.001, 0, .linear)])
            automate(.b, .bass, .volume, [(2 * q, 0, .hold), (2 * q + 0.001, 1, .linear)])
            // A vocal echoes out just before the swap.
            automate(.a, .vocals, .delay, [(2 * q - 1, 0, .linear), (2 * q - 0.25, 0.8, .hold), (2 * q + 1, 0, .linear)])
            automate(.a, .vocals, .volume, [(2 * q - 1, 1, .logarithmic), (2 * q, 0, .linear)])
            // A melody dissolves: low-pass sweep, then fade into a reverb wash.
            automate(.a, .other, .filter, [(2 * q, 0.5, .sCurve), (4 * q, 0.14, .linear)])
            automate(.a, .other, .reverb, [(3 * q, 0, .linear), (4 * q - 0.5, 0.7, .linear), (4 * q + 2, 0, .linear)])
            automate(.a, .other, .volume, [(3 * q, 1, .logarithmic), (4 * q, 0, .linear)])
            // A drums thin out and hand over.
            automate(.a, .drums, .filter, [(3 * q, 0.5, .sCurve), (4 * q, 0.78, .linear)])
            automate(.a, .drums, .volume, [(3 * q, 1, .logarithmic), (4 * q, 0, .linear)])
            // B vocal lands on the new phrase (or takes over at the swap).
            automate(.b, .vocals, .volume, [(v, 0, .hold), (v + 0.001, 1, .linear)])

        case .dropSwap:
            let h = n / 2
            automate(.b, .drums, .volume, [(0, 0, .exponential), (h, 1, .linear)])
            automate(.b, .drums, .filter, [(0, 0.9, .exponential), (h - 0.001, 0.62, .hold), (h, 0.5, .linear)])
            for stem in [StemKind.bass, .other] {
                automate(.b, stem, .volume, [(h, 0, .hold), (h + 0.001, 1, .linear)])
            }
            automate(.b, .vocals, .volume, [(v, 0, .hold), (v + 0.001, 1, .linear)])
            for stem in [StemKind.drums, .bass] {
                automate(.a, stem, .volume, [(h, 1, .hold), (h + 0.001, 0, .linear)])
            }
            automate(.a, .other, .reverb, [(h - 1, 0, .linear), (h, 0.8, .hold), (h + 0.001, 0, .linear)])
            automate(.a, .other, .volume, [(h, 1, .hold), (h + 0.001, 0, .linear)])
            automate(.a, .vocals, .delay, [(h - 1, 0, .linear), (h - 0.25, 0.85, .hold), (h + 0.001, 0, .linear)])
            automate(.a, .vocals, .volume, [(h, 1, .hold), (h + 0.001, 0, .linear)])

        case .longBlend:
            let q = n / 4
            // B's low end starts killed so it can come up under A's bass.
            automate(.b, .bass, .low, [(2 * q, 0, .hold), (2 * q + 0.001, 0.5, .linear)])
            automate(.b, .drums, .low, [(2 * q, 0, .hold), (2 * q + 0.001, 0.5, .linear)])
            automate(.a, .bass, .low, [(2 * q, 0.5, .hold), (2 * q + 0.001, 0, .linear)])
            automate(.a, .drums, .low, [(2 * q, 0.5, .hold), (2 * q + 0.001, 0, .linear)])
            for stem in [StemKind.drums, .bass] {
                automate(.b, stem, .volume, [(0, 0, .exponential), (q, 1, .linear)])
            }
            automate(.b, .other, .volume, [(0, 0, .exponential), (2 * q, 1, .linear)])
            automate(.b, .other, .filter, [(0, 0.16, .sCurve), (2 * q, 0.5, .linear)])
            automate(.a, .vocals, .volume, [(q, 1, .logarithmic), (2 * q, 0, .linear)])
            automate(.a, .other, .filter, [(2 * q, 0.5, .sCurve), (4 * q, 0.76, .linear)])
            automate(.a, .other, .volume, [(2 * q, 1, .logarithmic), (4 * q, 0, .linear)])
            for stem in [StemKind.drums, .bass] {
                automate(.a, stem, .volume, [(3 * q, 1, .sCurve), (4 * q, 0, .linear)])
            }
            if v < n {
                automate(.b, .vocals, .volume, [(v, 0, .hold), (v + 0.001, 1, .linear)])
            } else {
                automate(.b, .vocals, .volume, [(3 * q, 0, .exponential), (4 * q, 1, .linear)])
            }

        case .echoOut:
            // A spends the bar before B's entry echoing away; B slams in on
            // the downbeat. `bars` is how long the echo gets.
            let e = max(1, min(n, 4))
            for stem in StemKind.allCases {
                automate(.a, stem, .delay, [(-e, 0, .exponential), (-0.02, 0.9, .hold), (0, 0, .linear)])
                automate(.a, stem, .volume, [(-e / 4, 1, .logarithmic), (0, 0, .linear)])
                automate(.b, stem, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
            }
            automate(.a, .other, .reverb, [(-e, 0, .linear), (0, 0.6, .hold), (0.001, 0, .linear)])
            automate(.a, .drums, .filter, [(-e, 0.5, .exponential), (0, 0.85, .linear)])
        }
    }
}
