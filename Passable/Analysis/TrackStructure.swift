import Accelerate

/// Bar-by-bar activity of each stem, which is most of what a DJ reads off a
/// track when choosing where to mix: where the drums come in, where the
/// vocal starts, where it finally stops.
struct TrackStructure: Codable, Equatable {
    /// Per stem, per bar: RMS relative to that stem's loud bars (≈0…1+).
    var activity: [String: [Float]]

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
        return TrackStructure(activity: activity)
    }
}

/// Picks where B should enter A, the way a DJ would: on phrase boundaries,
/// with drums on both sides to hold the blend together, B's vocal arriving
/// as the transition completes rather than being muted mid-line, and A's
/// vocal not being cut off by the swap.
enum AutoPlacement {
    struct Result: Equatable {
        var entryBar: Int
        var cueBar: Int
        /// Bars after B's entry at which B's vocal is let in.
        var vocalHandoff: Int
        var reason: String
    }

    static func place(a: TrackAnalysis, b: TrackAnalysis, bars n: Int, preset: TransitionPreset) -> Result {
        let barsA = a.grid.barCount(duration: a.duration)
        let barsB = b.grid.barCount(duration: b.duration)
        guard let sa = a.structure, let sb = b.structure else {
            return Result(entryBar: max(0, barsA - n - 8), cueBar: 0, vocalHandoff: n, reason: "")
        }
        let echo = preset == .echoOut
        // Bar (from B's entry) at which A's vocal is taken out and B's comes in.
        let swap = echo ? 0 : n / 2
        let vocalIn = echo ? 0 : n

        // B: early, drums present, vocal muted as little as possible, and
        // ideally a vocal starting exactly when it's let in. B's vocal comes
        // in either at the end of the blend or — when B sings throughout, as
        // pop does — at the swap, the moment A's vocal has gone.
        let anchorB = sb.firstActiveBar(.drums) ?? 0
        var bestB = (bar: anchorB, handoff: vocalIn, score: -Float.infinity)
        // Skipping more than a third of B throws away too much of it.
        let lastCue = max(0, min(Int(Double(barsB) * 0.3), barsB - n - 1))
        for cue in phraseBars(anchor: anchorB, step: 4, in: 0...lastCue) {
            var base = sb.meanActivity(.drums, bars: cue..<(cue + max(1, n / 2)))
            base -= 1.2 * Float(cue) / Float(max(1, barsB))
            if echo { base += sb.meanActivity(.bass, bars: cue..<(cue + 4)) }
            for (handoff, preference) in Set([vocalIn, swap]).map({ ($0, $0 == vocalIn ? Float(0.15) : 0) }) {
                var score = base + preference
                score -= 1.5 * sb.meanActivity(.vocals, bars: cue..<(cue + handoff))
                score += 0.6 * sb.meanActivity(.vocals, bars: (cue + handoff)..<(cue + handoff + 4))
                if score > bestB.score { bestB = (cue, handoff, score) }
            }
        }

        // A: late, drums through the blend, and as little A vocal as possible
        // after the swap (it gets echoed out there).
        let anchorA = sa.firstActiveBar(.drums) ?? 0
        let latestEntry = max(0, barsA - (echo ? 1 : n))
        let earliest = min(latestEntry, max(anchorA, Int(Double(barsA) * 0.5)))
        var bestA = (bar: latestEntry, score: -Float.infinity)
        for entry in phraseBars(anchor: anchorA, step: 4, in: earliest...latestEntry) {
            var score = sa.meanActivity(.drums, bars: entry..<(entry + max(1, n)))
            score -= 1.5 * sa.meanActivity(.vocals, bars: (entry + swap)..<(entry + max(swap + 1, n)))
            // A vocal still going in the bars right before the swap will be
            // echoed out: fine if it's a phrase end, so only a mild cost.
            score -= 0.3 * sa.meanActivity(.vocals, bars: (entry + swap - 1)..<(entry + swap))
            score += 0.5 * Float(entry) / Float(max(1, barsA))
            if (entry - anchorA) % 8 == 0 { score += 0.1 }
            if score > bestA.score { bestA = (entry, score) }
        }

        var notes: [String] = []
        let handoff = bestB.handoff
        if handoff < vocalIn { notes.append("vocal handoff at bar \(handoff + 1)") }
        if sb.meanActivity(.vocals, bars: bestB.bar..<(bestB.bar + handoff)) > TrackStructure.threshold {
            notes.append("B sings early; muted until the handoff")
        } else if sb.meanActivity(.vocals, bars: (bestB.bar + handoff)..<(bestB.bar + handoff + 2)) > TrackStructure.threshold {
            notes.append("B's vocal lands on the handoff")
        }
        if sa.meanActivity(.vocals, bars: (bestA.bar + swap)..<(bestA.bar + n)) > TrackStructure.threshold {
            notes.append("A is still singing at the swap; it gets echoed out")
        }
        if sa.meanActivity(.drums, bars: bestA.bar..<(bestA.bar + n)) < TrackStructure.threshold {
            notes.append("little drums in A there — check by ear")
        }
        return Result(entryBar: bestA.bar, cueBar: bestB.bar, vocalHandoff: handoff, reason: notes.joined(separator: " · "))
    }

    /// Bars `anchor + k·step` inside `range` (anchor may lie outside it).
    private static func phraseBars(anchor: Int, step: Int, in range: ClosedRange<Int>) -> [Int] {
        let first = anchor + Int((Double(range.lowerBound - anchor) / Double(step)).rounded(.up)) * step
        let bars = Array(stride(from: first, through: range.upperBound, by: step))
        return bars.isEmpty ? [range.upperBound] : bars
    }
}
