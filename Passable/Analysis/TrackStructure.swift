import Accelerate

/// Bar-by-bar activity of each stem, which is most of what a DJ reads off a
/// track when choosing where to mix: where the drums come in, where the
/// vocal starts, where it finally stops.
struct TrackStructure: Codable, Equatable {
    /// Per stem, per bar: RMS relative to that stem's loud bars (≈0…1+).
    var activity: [String: [Float]]
    /// Level of the whole track per bar, in dB (RMS, full scale = 0).
    var loudness: [Float] = []

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
        for (kind, stem) in stems {
            var bars: [Float] = []
            var bar = 0
            while true {
                let start = Int(grid.downbeat(bar) * sr), end = Int(grid.downbeat(bar + 1) * sr)
                guard end <= stem.count else { break }
                var l: Float = 0, r: Float = 0
                vDSP_rmsqv(stem.left.pointer + start, 1, &l, vDSP_Length(end - start))
                vDSP_rmsqv(stem.right.pointer + start, 1, &r, vDSP_Length(end - start))
                bars.append((l + r) / 2)
                bar += 1
            }
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
        return TrackStructure(activity: activity, loudness: loudness)
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
    static func place(a: TrackAnalysis, b: TrackAnalysis, bars n: Int, preset: TransitionPreset,
                      trimA: Float = 0, trimB: Float = 0, entryRange: ClosedRange<Int>? = nil) -> Result {
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

        var best = (entry: entries.last ?? max(0, barsA - n), cue: cues.first ?? 0, handoff: vocalIn,
                    score: -Float.infinity)
        for e in entries.isEmpty ? [max(0, latest)] : entries {
            // A side: beat under the first half, energy before and during.
            let drumsA = min(1.2, sa.meanActivity(.drums, bars: e..<(e + max(1, span / 2))))
            let preA = sa.meanLoudness(bars: (e - 8)..<e) + trimA
            let duringA = sa.meanLoudness(bars: e..<(e + max(1, span / 2))) + trimA
            var scoreA: Float = echo ? 0 : drumsA
            scoreA -= 0.12 * max(0, refA - preA - 2)
            scoreA -= 0.10 * max(0, preA - duringA - 3)
            scoreA -= 1.5 * sa.meanActivity(.vocals, bars: (e + swap)..<(e + max(swap + 1, span)))
            scoreA -= 0.3 * sa.meanActivity(.vocals, bars: (e + swap - 1)..<(e + swap))
            scoreA += 0.6 * bound(boundA, e) + 0.3 * bound(boundA, e + span)
            scoreA += 0.3 * Float(e) / Float(max(1, barsA))

            for c in cues {
                let drumsB = min(1.2, sb.meanActivity(.drums, bars: c..<(c + max(1, span / 2))))
                let postB = sb.meanLoudness(bars: (c + span)..<(c + span + 8)) + trimB
                var score = scoreA
                score += echo ? 0.5 * sb.meanActivity(.bass, bars: c..<(c + 4)) : 0.8 * drumsB
                // Energy: B's first bars on its own against A's last before.
                score -= 0.2 * max(0, refB - postB - 2)
                let change = postB - preA
                score -= change < 0 ? 0.25 * max(0, -change - 1.5) : 0.03 * max(0, change - 3)
                // No hole in the middle: A carries the first half, and both
                // play the second, so estimate the mix level phrase by phrase.
                let floor = min(preA, postB) - 2.5
                var k = 0
                while k < span {
                    let a = sa.meanLoudness(bars: (e + k)..<(e + k + 4)) + trimA
                    // Until the low end swaps, B is only its tops and melody.
                    let b = k >= span / 2 ? sb.meanLoudness(bars: (c + k)..<(c + k + 4)) + trimB - 6 : -90
                    let mix = 10 * log10(pow(10, a / 10) + pow(10, b / 10))
                    score -= 0.15 * max(0, floor - mix)
                    k += 4
                }
                score += 0.4 * bound(boundB, c) + 0.8 * bound(boundB, c + span)
                score -= 0.8 * Float(c) / Float(max(1, barsB))
                for handoff in Set([vocalIn, swap]) {
                    var s = score + (handoff == vocalIn ? 0.15 : 0)
                    s -= 1.5 * sb.meanActivity(.vocals, bars: c..<(c + handoff))
                    s += 0.6 * sb.meanActivity(.vocals, bars: (c + handoff)..<(c + handoff + 4))
                    if s > best.score { best = (e, c, handoff, s) }
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
        if sa.meanActivity(.vocals, bars: (best.entry + swap)..<(best.entry + span)) > TrackStructure.threshold {
            notes.append("A is still singing at the swap; it gets echoed out")
        }
        let preA = sa.meanLoudness(bars: (best.entry - 8)..<best.entry) + trimA
        let postB = sb.meanLoudness(bars: (best.cue + span)..<(best.cue + span + 8)) + trimB
        if postB < preA - 4 { notes.append(String(format: "energy drops %.0f dB", preA - postB)) }

        // Hand the low end over where B has one. If B is still building, A
        // keeps it until B's drop at the end of the transition.
        var lowSwap: Int?
        if !echo {
            let strong = { (k: Int) in
                let r = (best.cue + k)..<(best.cue + k + 4)
                return sb.meanActivity(.bass, bars: r) > 0.5 && sb.meanActivity(.drums, bars: r) > 0.5
            }
            let step = max(1, n / 4)
            lowSwap = stride(from: n / 2, to: n, by: step).first(where: strong) ?? n
            if lowSwap == n && n >= 8 { notes.append("A holds the low end until B's drop") }
        }
        return Result(entryBar: best.entry, cueBar: best.cue, vocalHandoff: handoff, lowSwap: lowSwap,
                      reason: notes.joined(separator: " · "), score: best.score)
    }
}
