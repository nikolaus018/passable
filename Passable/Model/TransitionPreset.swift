import Foundation

/// Ready-made stem choreographies. Each writes automation relative to the
/// moment B enters, measured in bars of the master (A) grid, so they land on
/// phrase boundaries whatever the tempo.
enum TransitionPreset: String, CaseIterable, Codable, Identifiable {
    case stemSwap, dropSwap, longBlend, echoOut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stemSwap: return "Stem Swap"
        case .dropSwap: return "Drop Swap"
        case .longBlend: return "Long Blend"
        case .echoOut: return "Wash Out"
        }
    }

    var summary: String {
        switch self {
        case .stemSwap:
            return "B's drums and melody build in with their low end killed; kick and bass change hands on one downbeat (on B's drop if B is still building); A's vocal echoes out as B's vocal or low end takes over."
        case .dropSwap:
            return "B's drums build filtered, then everything swaps at once on the drop while A's melody and vocal echo away."
        case .longBlend:
            return "A slow EQ blend: B fades up with its low end killed, the lows trade places mid-way, A filters out."
        case .echoOut:
            return "For tempos too far apart to beat-match: A's beat sinks under a low-pass and its melody washes into reverb and echo while B's intro rises at its own tempo, then B's beat drops on the downbeat."
        }
    }

    var defaultBars: Int {
        switch self {
        case .stemSwap: return 16
        case .dropSwap: return 8
        case .longBlend: return 32
        case .echoOut: return 8
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
    /// The keys don't fit: melodies are swapped, never layered.
    let keysClash: Bool
    /// Bar (from B's entry) where kick and bass change hands; nil = half-way.
    let lowSwap: Int?
    /// The two drum parts groove together, so B's can build in under A's.
    /// If not, A's beat plays on alone and B's comes in whole on the swap.
    let drumsLayer: Bool
    /// Bars (from B's entry) where B's vocal is let in and A's taken out,
    /// placed between lines; nil = on the bar grid.
    let vocalIn: Double?, vocalOut: Double?
    private(set) var lanes: [Lane]

    init(lanes: [Lane], start: Double, barSeconds: Double, bars: Int, vocalBar: Int? = nil, keysClash: Bool = false,
         lowSwap: Int? = nil, drumsLayer: Bool = true, vocalIn: Double? = nil, vocalOut: Double? = nil) {
        self.lowSwap = lowSwap
        self.drumsLayer = drumsLayer
        self.vocalIn = vocalIn
        self.vocalOut = vocalOut
        self.lanes = lanes
        self.start = start
        self.barSeconds = barSeconds
        self.bars = bars
        self.vocalBar = vocalBar
        self.keysClash = keysClash
    }

    static func build(_ preset: TransitionPreset, lanes: [Lane], start: Double, barSeconds: Double, bars: Int,
                      vocalBar: Int? = nil, keysClash: Bool = false, lowSwap: Int? = nil,
                      drumsLayer: Bool = true, vocalIn: Double? = nil, vocalOut: Double? = nil) -> [Lane] {
        var builder = TransitionBuilder(lanes: lanes, start: start, barSeconds: barSeconds, bars: bars,
                                        vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap,
                                        drumsLayer: drumsLayer, vocalIn: vocalIn, vocalOut: vocalOut)
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
            let sw = min(n, max(2 * q, Double(lowSwap ?? Int(2 * q))))
            // The low end has one owner at a time: A's kick and bass until the
            // half-way downbeat, B's from there. B's drums come in with their
            // lows killed (hats, snares, percussion) and take the kick over in
            // the same instant A's drums hand it off.
            if drumsLayer {
                automate(.b, .drums, .volume, [(0, 0, .exponential), (q, 1, .linear)])
                automate(.b, .drums, .filter, [(0, 0.74, .sCurve), (2 * q, 0.5, .linear)])
            } else {
                automate(.b, .drums, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
            }
            // Melody stems carry low end too (synth bass, 808s): B's stays
            // killed, A's goes, on the same downbeat.
            for stem in [StemKind.drums, .other] {
                automate(.b, stem, .low, [(sw, 0, .hold), (sw + 0.001, 0.5, .linear)])
                if sw < n {
                    automate(.a, stem, .low, [(sw, 0.5, .hold), (sw + 0.001, 0, .linear)])
                }
            }
            // Hard bass swap on the same downbeat.
            automate(.a, .bass, .volume, [(sw, 1, .hold), (sw + 0.001, 0, .linear)])
            automate(.b, .bass, .volume, [(sw, 0, .hold), (sw + 0.001, 1, .linear)])
            // A's vocal echoes out as B's arrives or B takes the low end,
            // whichever comes first: pulled any earlier, it leaves a hole.
            let vin = vocalIn ?? v
            let out = min(vin, vocalOut ?? min(v, sw))
            automate(.a, .vocals, .delay, [(out - 1, 0, .linear), (out - 0.25, 0.8, .hold), (out + 1, 0, .linear)])
            automate(.a, .vocals, .volume, [(out - 1, 1, .logarithmic), (out, 0, .linear)])
            if keysClash {
                // Clashing melodies never overlap: A's washes out into a
                // reverb tail as B's lands on the swap.
                automate(.a, .other, .reverb, [(2 * q - 1, 0, .linear), (2 * q, 0.8, .hold), (2 * q + 0.001, 0, .linear)])
                automate(.a, .other, .volume, [(2 * q, 1, .hold), (2 * q + 0.001, 0, .linear)])
                automate(.b, .other, .volume, [(2 * q, 0, .hold), (2 * q + 0.001, 1, .linear)])
            } else if sw < n {
                // B melody follows the drums; A's dissolves once B owns the
                // low end: low-pass sweep, then a fade into a reverb wash.
                automate(.b, .other, .volume, [(q, 0, .exponential), (2 * q, 1, .linear)])
                automate(.a, .other, .filter, [(2 * q, 0.5, .sCurve), (4 * q, 0.14, .linear)])
                automate(.a, .other, .reverb, [(3 * q, 0, .linear), (4 * q - 0.5, 0.7, .linear), (4 * q + 2, 0, .linear)])
                automate(.a, .other, .volume, [(3 * q, 1, .logarithmic), (4 * q, 0, .linear)])
            } else {
                // B is still building: A keeps driving at full power and is
                // thrown into a reverb tail on B's drop, never faded under it.
                automate(.b, .other, .volume, [(q, 0, .exponential), (2 * q, 1, .linear)])
                automate(.a, .other, .reverb, [(4 * q - 1, 0, .linear), (4 * q, 0.8, .hold), (4 * q + 0.001, 0, .linear)])
                automate(.a, .other, .volume, [(4 * q, 1, .hold), (4 * q + 0.001, 0, .linear)])
            }
            if !drumsLayer {
                // One beat at a time: A's hands straight over to B's.
                automate(.a, .drums, .volume, [(sw, 1, .hold), (sw + 0.001, 0, .linear)])
            } else if sw < n {
                // A's tops thin out and hand over.
                automate(.a, .drums, .filter, [(3 * q, 0.5, .sCurve), (4 * q, 0.78, .linear)])
                automate(.a, .drums, .volume, [(3 * q, 1, .logarithmic), (4 * q, 0, .linear)])
            } else {
                // A's beat carries the build and cuts on B's drop.
                automate(.a, .drums, .volume, [(4 * q, 1, .hold), (4 * q + 0.001, 0, .linear)])
            }
            if vocalIn != nil {
                // Let in on the breath before its next line: the line then
                // starts exactly as it does in the song.
                automate(.b, .vocals, .volume, [(vin - 0.25, 0, .exponential), (vin, 1, .linear)])
            } else {
                // No pause to use: the voice would jump in mid-sentence, so
                // it rises over a bar instead, opening up from a filter.
                automate(.b, .vocals, .volume, [(vin, 0, .exponential), (vin + 1, 1, .linear)])
                automate(.b, .vocals, .filter, [(vin, 0.68, .sCurve), (vin + 1, 0.5, .linear)])
            }

        case .dropSwap:
            let h = n / 2
            automate(.b, .drums, .volume, [(0, 0, .exponential), (h, 1, .linear)])
            automate(.b, .drums, .filter, [(0, 0.9, .exponential), (h - 0.001, 0.62, .hold), (h, 0.5, .linear)])
            // No second kick before the drop.
            automate(.b, .drums, .low, [(h, 0, .hold), (h + 0.001, 0.5, .linear)])
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
            automate(.a, .vocals, .volume, [(q, 1, .logarithmic), (2 * q, 0, .linear)])
            if keysClash {
                automate(.a, .other, .reverb, [(2 * q - 1, 0, .linear), (2 * q, 0.8, .hold), (2 * q + 0.001, 0, .linear)])
                automate(.a, .other, .volume, [(2 * q, 1, .hold), (2 * q + 0.001, 0, .linear)])
                automate(.b, .other, .volume, [(2 * q, 0, .hold), (2 * q + 0.001, 1, .linear)])
            } else {
                automate(.b, .other, .volume, [(0, 0, .exponential), (2 * q, 1, .linear)])
                automate(.b, .other, .filter, [(0, 0.16, .sCurve), (2 * q, 0.5, .linear)])
                automate(.a, .other, .filter, [(2 * q, 0.5, .sCurve), (4 * q, 0.76, .linear)])
                automate(.a, .other, .volume, [(2 * q, 1, .logarithmic), (4 * q, 0, .linear)])
            }
            for stem in [StemKind.drums, .bass] {
                automate(.a, stem, .volume, [(3 * q, 1, .sCurve), (4 * q, 0, .linear)])
            }
            if v < n {
                automate(.b, .vocals, .volume, [(v, 0, .hold), (v + 0.001, 1, .linear)])
            } else {
                automate(.b, .vocals, .volume, [(3 * q, 0, .exponential), (4 * q, 1, .linear)])
            }

        case .echoOut:
            // The tempos can't be matched, so the songs never share a beat:
            // over `bars` before B's downbeat A's beat sinks under a
            // low-pass and fades, its melody and vocal wash into reverb and
            // echo, and B's intro (its own tempo, filtered) rises into the
            // gap. B's beat drops on the downbeat as A's tails ring out.
            // A stays at full level (a filtered crossfade, not a fade to
            // silence), so the floor never empties.
            let e = max(1, min(n, 8)), rise = min(4, e / 2)
            for stem in [StemKind.drums, .bass] {
                automate(.a, stem, .filter, [(-e, 0.5, .sCurve), (-1, 0.3, .linear), (0, 0.15, .linear)])
                automate(.a, stem, .volume, [(-1, 1, .logarithmic), (-0.25, 0, .linear)])
            }
            automate(.a, .drums, .delay, [(-2, 0, .exponential), (-0.25, 0.7, .hold), (0, 0, .linear)])
            automate(.a, .other, .reverb, [(-2, 0, .linear), (-0.5, 0.75, .hold), (0.001, 0, .linear)])
            automate(.a, .other, .volume, [(-1, 1, .logarithmic), (0, 0, .linear)])
            let out = max(-e, min(0, vocalOut ?? -1))
            automate(.a, .vocals, .delay, [(out - 1, 0, .linear), (out - 0.25, 0.85, .hold), (out + 2, 0, .linear)])
            automate(.a, .vocals, .volume, [(out - 0.5, 1, .logarithmic), (out, 0, .linear)])
            automate(.b, .other, .volume, [(-rise, 0, .exponential), (0, 1, .linear)])
            automate(.b, .other, .filter, [(-rise, 0.64, .sCurve), (0, 0.5, .linear)])
            for stem in [StemKind.drums, .bass] {
                automate(.b, stem, .volume, [(0, 0, .hold), (0.001, 1, .linear)])
            }
            automate(.b, .vocals, .volume, [(-0.25, 0, .exponential), (0, 1, .linear)])
        }
    }
}
