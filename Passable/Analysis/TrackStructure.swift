import Accelerate

/// Bar-by-bar activity of each stem, which is most of what a DJ reads off a
/// track when choosing where to mix: where the drums come in, where the
/// vocal starts, where it finally stops.
struct TrackStructure: Codable, Equatable {
    /// Per stem, per bar: RMS relative to that stem's loud bars (≈0…1+).
    var activity: [String: [Float]]
    /// Level of the whole track per bar, in dB (RMS, full scale = 0).
    var loudness: [Float] = []
    /// Per stem, per bar: level in dB, all of it and below 150 Hz. What a
    /// transition does to each stem (fades, filters, low kills) is judged
    /// from these before anything is rendered. Optional so structures
    /// measured before they existed still decode; the loader re-measures.
    var stemLevel: [String: [Float]]?
    var stemLowLevel: [String: [Float]]?

    /// How loud the track is when it's going: the level of its loud bars
    /// (80th percentile), which is what a DJ matches with the trim knob.
    /// Integrated loudness would be dragged down by intros and breakdowns.
    var referenceLoudness: Float {
        let bars = loudness.filter { $0 > -60 }.sorted()
        guard !bars.isEmpty else { return -14 }
        return bars[min(bars.count - 1, Int(Double(bars.count) * 0.8))]
    }

    func meanLoudness(bars: Range<Int>) -> Float {
        let r = max(0, bars.lowerBound)..<min(loudness.count, bars.upperBound)
        guard !r.isEmpty else { return -90 }
        // Average power, not average dB: one silent bar shouldn't dominate.
        let power = loudness[r].reduce(0) { $0 + pow(10, $1 / 10) } / Float(r.count)
        return 10 * log10(max(power, 1e-9))
    }

    func activity(_ stem: StemKind) -> [Float] { activity[stem.rawValue] ?? [] }

    func isActive(_ stem: StemKind, bar: Int) -> Bool {
        let a = activity(stem)
        return bar >= 0 && bar < a.count && a[bar] > Self.threshold
    }

    static let threshold: Float = 0.3

    /// First bar that starts a run of `run` active bars.
    func firstActiveBar(_ stem: StemKind, run: Int = 2) -> Int? {
        let a = activity(stem)
        guard a.count >= run else { return nil }
        return (0...(a.count - run)).first { i in (i..<(i + run)).allSatisfy { a[$0] > Self.threshold } }
    }

    /// Bar after the last run of `run` active bars.
    func lastActiveBarEnd(_ stem: StemKind, run: Int = 2) -> Int? {
        let a = activity(stem)
        guard a.count >= run else { return nil }
        return (0...(a.count - run)).last { i in (i..<(i + run)).allSatisfy { a[$0] > Self.threshold } }.map { $0 + run }
    }

    func meanActivity(_ stem: StemKind, bars: Range<Int>) -> Float {
        let a = activity(stem)
        let r = max(0, bars.lowerBound)..<min(a.count, bars.upperBound)
        guard !r.isEmpty else { return 0 }
        return a[r].reduce(0, +) / Float(r.count)
    }

    static func measure(stems: [StemKind: StemAudio], grid: BeatGrid) -> TrackStructure {
        let sr = AudioIO.sampleRate
        var activity: [String: [Float]] = [:]
        var stemLevel: [String: [Float]] = [:], stemLowLevel: [String: [Float]] = [:]
        for (kind, stem) in stems {
            var bars: [Float] = [], levels: [Float] = [], lows: [Float] = []
            var lowPass = Biquad()
            lowPass.set(.lowPass(frequency: 150, q: 0.707), sampleRate: sr)
            var bar = 0
            while true {
                let start = Int(grid.downbeat(bar) * sr), end = Int(grid.downbeat(bar + 1) * sr)
                guard end <= stem.count else { break }
                let n = end - start
                var l: Float = 0, r: Float = 0
                vDSP_rmsqv(stem.left.pointer + start, 1, &l, vDSP_Length(n))
                vDSP_rmsqv(stem.right.pointer + start, 1, &r, vDSP_Length(n))
                bars.append((l + r) / 2)
                var ml: Float = 0, mr: Float = 0
                vDSP_measqv(stem.left.pointer + start, 1, &ml, vDSP_Length(n))
                vDSP_measqv(stem.right.pointer + start, 1, &mr, vDSP_Length(n))
                levels.append(10 * log10(max((ml + mr) / 2, 1e-9)))
                var lowL = Array(UnsafeBufferPointer(start: stem.left.pointer + start, count: n))
                var lowR = Array(UnsafeBufferPointer(start: stem.right.pointer + start, count: n))
                lowPass.process(&lowL, &lowR, count: n)
                vDSP_measqv(lowL, 1, &ml, vDSP_Length(n))
                vDSP_measqv(lowR, 1, &mr, vDSP_Length(n))
                lows.append(10 * log10(max((ml + mr) / 2, 1e-9)))
                bar += 1
            }
            stemLevel[kind.rawValue] = levels
            stemLowLevel[kind.rawValue] = lows
            // Normalise to the stem's own loud bars so a quiet-but-present
            // vocal still counts, and separation bleed (a few % of the loud
            // level) doesn't.
            let reference = bars.sorted().dropFirst(Int(Double(bars.count) * 0.9)).first ?? 0
            activity[kind.rawValue] = reference > 1e-5 ? bars.map { $0 / reference } : bars.map { _ in 0 }
        }
        var loudness: [Float] = []
        let count = stems.values.map(\.count).min() ?? 0
        var bar = 0
        var mixL: [Float] = [], mixR: [Float] = []
        while true {
            let start = Int(grid.downbeat(bar) * sr), end = Int(grid.downbeat(bar + 1) * sr)
            guard end <= count else { break }
            if start < 0 { loudness.append(-90); bar += 1; continue }
            let n = end - start
            mixL = [Float](repeating: 0, count: n)
            mixR = mixL
            for stem in stems.values {
                vDSP_vadd(mixL, 1, stem.left.pointer + start, 1, &mixL, 1, vDSP_Length(n))
                vDSP_vadd(mixR, 1, stem.right.pointer + start, 1, &mixR, 1, vDSP_Length(n))
            }
            var l: Float = 0, r: Float = 0
            vDSP_measqv(mixL, 1, &l, vDSP_Length(n))
            vDSP_measqv(mixR, 1, &r, vDSP_Length(n))
            loudness.append(10 * log10(max((l + r) / 2, 1e-9)))
            bar += 1
        }
        return TrackStructure(activity: activity, loudness: loudness, stemLevel: stemLevel, stemLowLevel: stemLowLevel)
    }
}

extension TrackStructure {
    /// How strongly a new section starts at each bar (0…1): the change in
    /// what's playing between the four bars before and the four after.
    func boundaryStrength() -> [Float] {
        let stems = StemKind.allCases.map { activity($0) }
        let n = stems.map(\.count).min() ?? 0
        guard n > 8 else { return [Float](repeating: 0, count: n) }
        var novelty = [Float](repeating: 0, count: n)
        for b in 1..<n {
            let lo = max(0, b - 4), hi = min(n, b + 4)
            for a in stems {
                let before = a[lo..<b].reduce(0, +) / Float(b - lo)
                let after = a[b..<hi].reduce(0, +) / Float(hi - b)
                novelty[b] += abs(min(after, 1.5) - min(before, 1.5))
            }
            if b < loudness.count {
                let before = meanLoudness(bars: lo..<b), after = meanLoudness(bars: b..<hi)
                novelty[b] += min(1, abs(after - before) / 8)
            }
        }
        let peak = novelty.max() ?? 0
        return peak > 0 ? novelty.map { $0 / peak } : novelty
    }

    /// Bar offset (0…3) of the four-bar phrase grid: the phase on which
    /// sections start most.
    func phrasePhase() -> Int {
        let strength = boundaryStrength()
        var votes = [Float](repeating: 0, count: 4)
        for (b, v) in strength.enumerated() { votes[b % 4] += v * v }
        return votes.indices.max { votes[$0] < votes[$1] } ?? 0
    }
}

/// What a preset's automation does to each stem, bar by bar: the power left
/// of the stem's lows (below 150 Hz) and of the rest, after volume, DJ
/// filter and low EQ. Read off the automation the preset really writes, so
/// placement judges the transition that will play.
struct TransitionShape {
    typealias Gains = (low: Float, high: Float)
    /// Bars (from B's entry) the automation spans: before B's downbeat for
    /// a Wash Out, after it for the blends.
    let first: Int, last: Int
    private(set) var gains: [DeckSide: [StemKind: [Gains]]] = [:]

    init(_ preset: TransitionPreset, bars n: Int, vocalBar: Int?, keysClash: Bool, lowSwap: Int?) {
        (first, last) = preset == .echoOut ? (-max(1, min(n, 8)), 0) : (0, n)
        let lanes = TransitionBuilder.build(preset, lanes: Lane.allLanes(), start: 0, barSeconds: 1, bars: n,
                                            vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap)
        for lane in lanes {
            var perBar: [Gains] = []
            for k in first..<last {
                var low: Float = 0, high: Float = 0
                for u in [0.125, 0.375, 0.625, 0.875] {
                    let g = Self.gains(lane, at: Double(k) + u)
                    low += g.low / 4
                    high += g.high / 4
                }
                perBar.append((low, high))
            }
            gains[lane.side, default: [:]][lane.stem] = perBar
        }
    }

    private static func gains(_ lane: Lane, at t: Double) -> Gains {
        let volume = Double(LaneParameter.gain(lane[.volume].value(at: t, default: 1)))
        var low = volume * volume, high = low
        switch LaneParameter.filter(lane[.filter].value(at: t, default: 0.5)) {
        case .bypass: break
        case .lowPass(let f):
            low *= f >= 150 ? 1 : (f / 150) * (f / 150)
            high *= min(1, f / 8000)
        case .highPass(let f):
            low *= f <= 30 ? 1 : f >= 150 ? 0 : (30 / f) * (30 / f)
            high *= min(1, 300 / f)
        }
        low *= pow(10, LaneParameter.eqDecibels(lane[.low].value(at: t, default: 0.5)) / 10)
        return (Float(low), Float(high))
    }

    /// Estimated level (dB) of the mix in bar `k` of the transition, with A
    /// entering its bar `e` and B cued at `c`; powers from
    /// `AutoPlacement.powers`.
    func mixLevel(_ k: Int, a: [StemKind: [Gains]], e: Int, b: [StemKind: [Gains]], c: Int) -> Float {
        var power: Float = 0
        for (side, p, bar) in [(DeckSide.a, a, e + k), (.b, b, c + k)] {
            for (stem, levels) in p where bar >= 0 && bar < levels.count {
                // Before it A plays on its own, past the end B does.
                let g: Gains = k < first ? (side == .a ? (1, 1) : (0, 0))
                    : k >= last ? (side == .a ? (0, 0) : (1, 1))
                    : gains[side]?[stem]?[k - first] ?? (1, 1)
                power += g.low * levels[bar].low + g.high * levels[bar].high
            }
        }
        return 10 * log10(max(power, 1e-9))
    }
}

/// Picks where B should enter A, the way a club DJ would:
///
/// - **Energy holds.** What B plays right after the transition is about as
///   loud and busy as what A played right before it (after level matching),
///   and neither side is in a breakdown. A lift is fine; a drop isn't.
/// - **Sections line up.** B enters on a phrase start, A's exit starts on
///   one, and B's next section — ideally its chorus or drop — begins exactly
///   when the transition completes.
/// - **The beat carries through.** Drums on both sides where they overlap.
/// - **Vocals hand over.** B's vocal arrives as A's is echoed out, not
///   muted mid-line, and A isn't cut off mid-line either.
enum AutoPlacement {
    /// Every stem's power per bar, split at 150 Hz, with the deck's trim
    /// applied; nil for structures measured before per-stem levels existed.
    static func powers(_ s: TrackStructure, trim: Float) -> [StemKind: [TransitionShape.Gains]]? {
        guard let all = s.stemLevel, let lows = s.stemLowLevel else { return nil }
        let t = pow(10, trim / 10)
        var out: [StemKind: [TransitionShape.Gains]] = [:]
        for stem in StemKind.allCases {
            guard let a = all[stem.rawValue], let l = lows[stem.rawValue] else { return nil }
            out[stem] = zip(a, l).map { a, l in
                let total = pow(10, a / 10), low = min(total, pow(10, l / 10))
                return (t * low, t * (total - low))
            }
        }
        return out
    }

    struct Result: Equatable {
        var entryBar: Int
        var cueBar: Int
        /// Bars after B's entry at which B's vocal is let in.
        var vocalHandoff: Int
        /// Bars after B's entry at which the low end (kick and bass) changes
        /// hands: the first phrase where B's own low end is really there.
        var lowSwap: Int? = nil
        var reason: String
        /// How good the best spot is (higher is better); comparable between
        /// pairs, which is what set ordering uses it for.
        var score: Float = 0
    }

    /// - Parameters:
    ///   - trimA, trimB: the decks' level matches (dB), so energies compare
    ///     as heard.
    ///   - entryRange: bars of A the transition may start on (in a set: not
    ///     before A has had its time).
    ///   - keysClash: the melodies will be swapped rather than layered,
    ///     which changes what plays when.
    static func place(a: TrackAnalysis, b: TrackAnalysis, bars n: Int, preset: TransitionPreset,
                      trimA: Float = 0, trimB: Float = 0, entryRange: ClosedRange<Int>? = nil,
                      keysClash: Bool = false) -> Result {
        let barsA = a.grid.barCount(duration: a.duration)
        let barsB = b.grid.barCount(duration: b.duration)
        guard let sa = a.structure, let sb = b.structure, !sa.loudness.isEmpty, !sb.loudness.isEmpty else {
            return Result(entryBar: max(0, barsA - n - 8), cueBar: 0, vocalHandoff: n, reason: "")
        }
        let echo = preset == .echoOut
        // Bar (from B's entry) at which A's vocal is taken out and B's comes in.
        let swap = echo ? 0 : n / 2
        let vocalIn = echo ? 0 : n
        let span = echo ? 0 : n
        let boundA = sa.boundaryStrength(), boundB = sb.boundaryStrength()
        let phaseA = sa.phrasePhase(), phaseB = sb.phrasePhase()
        let refA = sa.referenceLoudness + trimA, refB = sb.referenceLoudness + trimB
        func bound(_ x: [Float], _ i: Int) -> Float { i >= 0 && i < x.count ? x[i] : 0 }

        // A must still be playing music when the transition ends (a video's
        // spoken outro or fade doesn't count).
        // Nor fading out: the whole blend sits in A's full-level part.
        let musicEndA = (sa.loudness.lastIndex { $0 + trimA > refA - 5 } ?? barsA - 1) + 1
        let latest = max(0, min(barsA, musicEndA) - max(1, span))
        let range = entryRange.map { min($0.lowerBound, latest)...$0.upperBound }
            ?? min(latest, Int(Double(barsA) * 0.45))...latest
        let entries = stride(from: range.lowerBound, through: max(range.lowerBound, min(range.upperBound, latest)), by: 1)
            .filter { ((($0 - phaseA) % 4) + 4) % 4 == 0 }
        // Skipping more than ~40 % of B throws away too much of it.
        let lastCue = max(0, min(Int(Double(barsB) * 0.4), barsB - n - 8))
        let cues = (0...lastCue).filter { ((($0 - phaseB) % 4) + 4) % 4 == 0 }

        // Where the low end changes hands for a given cue: the first phrase
        // from half-way where B's own kick and bass are really there; if B
        // is still building, A keeps it until B's drop at the end.
        let step = max(1, n / 4)
        func lowSwap(cue c: Int) -> Int? {
            guard !echo else { return nil }
            return stride(from: n / 2, to: n, by: step).first { k in
                let r = (c + k)..<(c + k + 4)
                return sb.meanActivity(.bass, bars: r) > 0.5 && sb.meanActivity(.drums, bars: r) > 0.5
            } ?? n
        }
        struct ShapeKey: Hashable { let handoff: Int, lowSwap: Int }
        var shapes: [ShapeKey: TransitionShape] = [:]
        let powerA = AutoPlacement.powers(sa, trim: trimA), powerB = AutoPlacement.powers(sb, trim: trimB)

        var best = (entry: entries.last ?? max(0, barsA - n), cue: cues.first ?? 0, handoff: vocalIn,
                    lowSwap: lowSwap(cue: cues.first ?? 0), score: -Float.infinity)
        for e in entries.isEmpty ? [max(0, latest)] : entries {
            // A side: beat under the first half, energy before and during.
            let drumsA = min(1.2, sa.meanActivity(.drums, bars: e..<(e + max(1, span / 2))))
            // Before the transition: for a Wash Out, before its bars.
            let lead = echo ? min(n, 8) : 0
            let preA = sa.meanLoudness(bars: (e - lead - 8)..<(e - lead)) + trimA
            let duringA = sa.meanLoudness(bars: e..<(e + max(1, span / 2))) + trimA
            var scoreA: Float = echo ? 0 : drumsA
            scoreA -= 0.12 * max(0, refA - preA - 2)
            scoreA -= 0.10 * max(0, preA - duringA - 3)
            scoreA += 0.6 * bound(boundA, e) + 0.3 * bound(boundA, e + span)
            scoreA += 0.3 * Float(e) / Float(max(1, barsA))
            if echo {
                scoreA -= 1.5 * sa.meanActivity(.vocals, bars: e..<(e + 1))
                scoreA -= 0.3 * sa.meanActivity(.vocals, bars: (e - 1)..<e)
            }
            // A new, louder section of A starting inside the blend would be
            // thrown away a few bars in: its drop cut short.
            for k in stride(from: 2, to: span, by: 1) where bound(boundA, e + k) > 0.5 {
                let jump = sa.meanLoudness(bars: (e + k)..<(e + k + 4)) - sa.meanLoudness(bars: (e + k - 4)..<(e + k))
                if jump > 3 { scoreA -= 0.5 * bound(boundA, e + k) }
            }

            for c in cues {
                let drumsB = min(1.2, sb.meanActivity(.drums, bars: c..<(c + max(1, span / 2))))
                let postB = sb.meanLoudness(bars: (c + span)..<(c + span + 8)) + trimB
                var score = scoreA
                score += echo ? 0.5 * sb.meanActivity(.bass, bars: c..<(c + 4)) : 0.8 * drumsB
                // Energy: B's first bars on its own against A's last before.
                score -= 0.2 * max(0, refB - postB - 2)
                let change = postB - preA
                score -= change < 0 ? 0.25 * max(0, -change - 1.5) : 0.03 * max(0, change - 3)
                if echo {
                    // B slams in: its first two bars must already be going,
                    // not an intro fill.
                    let opening = min(sb.meanLoudness(bars: c..<(c + 1)), sb.meanLoudness(bars: (c + 1)..<(c + 2))) + trimB
                    score -= 0.15 * max(0, postB - opening - 3)
                }
                score += 0.4 * bound(boundB, c) + 0.8 * bound(boundB, c + span)
                score -= 0.8 * Float(c) / Float(max(1, barsB))
                let sw = lowSwap(cue: c)
                if let sw, sw < span {
                    // The real change happens at the swap: best on a new
                    // section of B and the end of one of A's.
                    score += 0.4 * bound(boundB, c + sw) + 0.3 * bound(boundA, e + sw)
                }
                for handoff in Set([vocalIn, swap]) {
                    var s = score + (handoff == vocalIn ? 0.15 : 0)
                    s -= 1.5 * sb.meanActivity(.vocals, bars: c..<(c + handoff))
                    s += 0.6 * sb.meanActivity(.vocals, bars: (c + handoff)..<(c + handoff + 4))
                    // The mix, bar by bar, as the automation will play it,
                    // through B's first two phrases on its own too: no hole
                    // in the middle, no pile-up either, and no lull right
                    // after the swap or B dropping into its breakdown as
                    // soon as it has the floor.
                    if let powerA, let powerB {
                        let key = ShapeKey(handoff: handoff, lowSwap: sw ?? n)
                        let shape = shapes[key] ?? TransitionShape(preset, bars: n, vocalBar: handoff, keysClash: keysClash,
                                                                   lowSwap: sw)
                        shapes[key] = shape
                        // The floor is A's energy: B landing in its own
                        // breakdown is as much a hole as a gap in the blend.
                        // Per bar, so short and long blends compete fairly.
                        let floor = preA - 2.5, ceiling = max(preA, postB) + 2.5
                        let bars = shape.first..<(shape.last + 8)
                        var penalty: Float = 0
                        for k in bars {
                            let level = shape.mixLevel(k, a: powerA, e: e, b: powerB, c: c)
                            let hole = max(0, floor - level)
                            penalty += 0.1 * hole + 0.02 * hole * hole + 0.04 * max(0, level - ceiling)
                        }
                        s -= penalty * 24 / Float(bars.count)
                    }
                    guard !echo else {
                        if s > best.score { best = (e, c, handoff, sw, s) }
                        continue
                    }
                    // A's vocal leaves when B's arrives or B takes the low
                    // end, whichever is first; anything A sings later is cut.
                    let out = min(handoff, sw ?? n)
                    s -= 1.5 * sa.meanActivity(.vocals, bars: (e + out)..<(e + max(out + 1, span)))
                    s -= 0.3 * sa.meanActivity(.vocals, bars: (e + out - 1)..<(e + out))
                    // Best between lines on both sides: a vocal singing
                    // through the handover gets cut in two.
                    func through(_ s: TrackStructure, _ bar: Int) -> Float {
                        min(s.meanActivity(.vocals, bars: (bar - 1)..<bar), s.meanActivity(.vocals, bars: bar..<(bar + 1)))
                    }
                    s -= 0.8 * through(sb, c + handoff) + 0.4 * through(sa, e + out)
                    if s > best.score { best = (e, c, handoff, sw, s) }
                }
            }
        }
        var notes: [String] = []
        let handoff = best.handoff
        if handoff < vocalIn { notes.append("vocal handoff at bar \(handoff + 1)") }
        if sb.meanActivity(.vocals, bars: best.cue..<(best.cue + handoff)) > TrackStructure.threshold {
            notes.append("B sings early; muted until the handoff")
        } else if sb.meanActivity(.vocals, bars: (best.cue + handoff)..<(best.cue + handoff + 2)) > TrackStructure.threshold {
            notes.append("B's vocal lands on the handoff")
        }
        if bound(boundB, best.cue + span) > 0.5 { notes.append("B's next section starts as A leaves") }
        let out = min(handoff, best.lowSwap ?? n)
        if !echo, sa.meanActivity(.vocals, bars: (best.entry + out)..<(best.entry + span)) > TrackStructure.threshold {
            notes.append("A is still singing at the swap; it gets echoed out")
        }
        let preA = sa.meanLoudness(bars: (best.entry - 8)..<best.entry) + trimA
        let postB = sb.meanLoudness(bars: (best.cue + span)..<(best.cue + span + 8)) + trimB
        if postB < preA - 4 { notes.append(String(format: "energy drops %.0f dB", preA - postB)) }

        if best.lowSwap == n && n >= 8 { notes.append("A holds the low end until B's drop") }
        return Result(entryBar: best.entry, cueBar: best.cue, vocalHandoff: handoff, lowSwap: best.lowSwap,
                      reason: notes.joined(separator: " · "), score: best.score)
    }
}
