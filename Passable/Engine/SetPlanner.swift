import Accelerate
import Foundation

/// The mixing rules shared by the two-deck editor and the set builder.
enum MixMath {
    /// Loud sections of every track play at this level (dB RMS), like a DJ
    /// riding the trim so each record hits equally hard.
    static let targetLoudness: Float = -12

    /// B's tempo multiplier relative to A, folded by an octave when the two
    /// were detected at half/double time of each other.
    static func tempoMultiplier(a: Double, b: Double) -> Double {
        guard a > 0, b > 0 else { return 1 }
        return [0.5, 1, 2].min { abs(log2(a / (b * $0))) < abs(log2(a / (b * $1))) }!
    }

    /// B's rate while it plays under A.
    static func rate(a: Double, b: Double) -> Double {
        guard a > 0, b > 0 else { return 1 }
        return a / (b * tempoMultiplier(a: a, b: b))
    }

    /// Beyond this, stretching B is audible even with its tempo matched
    /// only through the blend: Wash Out, no shared beat.
    static let maxStretch = 0.08

    static func recommendedPreset(rate: Double) -> TransitionPreset {
        abs(rate - 1) > maxStretch ? .echoOut : .stemSwap
    }

    /// Bars B takes to glide from A's tempo back to its own once A is gone:
    /// about 1.5 % per bar, so the change is felt as a lift, not heard as a
    /// wobble.
    static func glideBars(rate: Double) -> Int {
        let percent = abs(rate - 1) * 100
        return percent < 0.05 ? 1 : min(16, max(2, Int((percent / 1.5).rounded(.up))))
    }

    /// Level match for a track, in dB. Boosts are capped: past that a quiet
    /// track would just be squashed by the limiter.
    static func trimDB(_ analysis: TrackAnalysis?) -> Double {
        guard let reference = analysis?.structure?.referenceLoudness else { return 0 }
        return Double(max(-12, min(8, targetLoudness - reference)))
    }

    /// No automatic blend runs longer than this, whatever the songs would
    /// allow: past it a crowd hears two songs fighting, not a mix. In
    /// seconds, because that's what feels long: 16 bars stay possible down
    /// to 85 BPM, 32 bars practically never.
    static let maxBlendSeconds = 45.0

    static func keysClash(_ a: MusicalKey, _ b: MusicalKey) -> Bool {
        b.harmonicShift(toMatch: a, limit: 0) == nil
    }

    /// The most an automatic transition pitches a song to fit the one
    /// before: two semitones is about what a voice takes unnoticed.
    static let maxKeyShift = 2

    /// Tempos this close layer a vocal over the other song's beat without
    /// the stretch being heard.
    static let mashupStretch = 0.05
}

/// Everything decided about one transition, from the two analyses alone.
struct PairPlan: Equatable {
    var preset: TransitionPreset
    var bars: Int
    /// B's rate during the overlap (1 for Wash Out).
    var rate: Double
    var placement: AutoPlacement.Result
    /// The keys clash even after B's shift: melodies are swapped.
    var keysClash: Bool
    /// B's pitch shift, for the whole time it plays.
    var semitones: Int = 0

    var stretchPercent: Double { (rate - 1) * 100 }

    /// - Parameter aShift: semitones A itself plays shifted by (its own
    ///   transition in), so B is fitted to the key A is heard in.
    /// - Parameter soloFrom: A's bar from which it plays on its own, to
    ///   pace its exit (see `AutoPlacement.pacing`).
    static func make(a: TrackAnalysis, b: TrackAnalysis, entryRange: ClosedRange<Int>? = nil, aShift: Int = 0,
                     soloFrom: Int? = nil, skip: Range<Int>? = nil) -> PairPlan {
        let rate = MixMath.rate(a: a.grid.bpm, b: b.grid.bpm)
        let preset = MixMath.recommendedPreset(rate: rate)
        let aKey = a.key.transposed(by: aShift)
        // Where the keys clash, B may be pitched into A's key: then the
        // melodies can layer and B can sing over A's beat. The shift stays
        // on for all of B, so it costs a little of B's own sound, and
        // placement decides whether what it buys is worth that.
        var shifts = [0]
        if MixMath.keysClash(aKey, b.key),
           let shift = b.key.harmonicShift(toMatch: aKey, limit: MixMath.maxKeyShift), shift != 0 {
            shifts.append(shift)
        }
        func clash(_ shift: Int) -> Bool { MixMath.keysClash(aKey, b.key.transposed(by: shift)) }
        func place(_ preset: TransitionPreset, _ bars: Int, _ shift: Int) -> AutoPlacement.Result {
            AutoPlacement.place(a: a, b: b, bars: bars, preset: preset,
                                trimA: Float(MixMath.trimDB(a)), trimB: Float(MixMath.trimDB(b)),
                                entryRange: entryRange, keysClash: clash(shift),
                                mashup: !clash(shift) && abs(rate - 1) < MixMath.mashupStretch, soloFrom: soloFrom,
                                skip: skip)
        }
        // A DJ fits the blend to the music: long where both sides just
        // groove, short where vocals or a drop leave no room. Every length
        // is judged by the same simulation; the priors only break near-ties
        // (long blends are the smoother ride, and a long stretch is only
        // worth it when the tempos are close).
        // A Drop Swap is in the running too; it only wins where B really
        // drops at the switch (placement rewards that, nothing else does).
        // How long a club DJ blends: about 15 to 30 seconds of the two
        // songs, whatever the tempo (eight bars of rap at 95 BPM is a full
        // blend, eight of house at 128 a quick one). Lengths are nudged
        // towards that; the simulation decides.
        let barSeconds = a.grid.barSeconds
        func length(_ bars: Int) -> Float { -0.03 * Float(abs(Double(bars) * barSeconds - 24)) }
        var options = [(preset: preset, bars: preset.defaultBars, prior: preset == .echoOut ? 0 : length(preset.defaultBars))]
        if preset == .stemSwap {
            options.append((.stemSwap, 8, length(8)))
            if abs(rate - 1) < 0.03 { options.append((.stemSwap, 32, length(32))) }
            options.append((.dropSwap, 16, length(16) - 0.2))
            options.append((.dropSwap, 8, length(8) - 0.2))
        }
        options = options.filter { $0.preset == .echoOut || Double($0.bars) * barSeconds <= MixMath.maxBlendSeconds
            || $0.bars <= 8 }
        let best = options.flatMap { option in shifts.map { (option, $0) } }
            .map { option, shift in
                (preset: option.preset, bars: option.bars, shift: shift, placement: place(option.preset, option.bars, shift),
                 prior: option.prior - 0.35 * Float(abs(shift)))
            }
            .max { $0.placement.score + $0.prior < $1.placement.score + $1.prior }!
        return PairPlan(preset: best.preset, bars: best.bars, rate: best.preset == .echoOut ? 1 : rate,
                        placement: best.placement, keysClash: clash(best.shift), semitones: best.shift)
    }

    /// Lower is better. What a DJ weighs when picking the next record:
    /// how far it has to be stretched, whether the keys sit together,
    /// whether the energy keeps going, and how well the two songs' sections
    /// line up for a blend.
    func cost(a: TrackAnalysis, b: TrackAnalysis) -> Double {
        let stretch = abs(MixMath.rate(a: a.grid.bpm, b: b.grid.bpm) - 1) * 100
        var cost: Double
        switch stretch {
        case ..<3: cost = 0.05 * stretch
        case ..<8: cost = 0.15 + 0.14 * (stretch - 3)
        default: cost = 1.5 + 0.05 * stretch // Wash Out: fine once, not all night
        }
        // Clashing songs can't blend, only swap: next to each other they
        // sound like two songs in a row.
        if keysClash { cost += 1.2 }
        cost += 0.15 * Double(abs(semitones))
        let drop = SetOrdering.energy(a) - SetOrdering.energy(b)
        cost += drop > 0 ? 2.0 * drop : 0.2 * -drop
        cost -= 0.3 * Double(placement.score)
        return cost
    }
}

enum SetOrdering {
    /// 0…1: how hard a track drives — tempo, and how much of it has a full
    /// beat and bass line going.
    static func energy(_ t: TrackAnalysis) -> Double {
        let tempo = min(1, max(0, (t.grid.bpm * foldToClubRange(t.grid.bpm) - 95) / 40))
        guard let s = t.structure else { return tempo }
        let drums = s.activity(.drums), bass = s.activity(.bass)
        let n = min(drums.count, bass.count)
        guard n > 0 else { return tempo }
        let full = (0..<n).filter { drums[$0] > 0.5 && bass[$0] > 0.5 }.count
        return 0.45 * tempo + 0.55 * Double(full) / Double(n)
    }

    /// Every ordered pair's transition cost.
    static func costMatrix(_ analyses: [TrackAnalysis]) -> [[Double]] {
        let n = analyses.count
        // Every pair is independent: all cores at once.
        var flat = [Double](repeating: 0, count: n * n)
        flat.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: n * n) { k in
                let i = k / n, j = k % n
                guard i != j else { return }
                out[k] = PairPlan.make(a: analyses[i], b: analyses[j]).cost(a: analyses[i], b: analyses[j])
            }
        }
        return (0..<n).map { Array(flat[($0 * n)..<($0 * n + n)]) }
    }

    /// Hip-hop detected at 70-something is felt at double time in a club;
    /// at 85 it's felt at 85 (calling it 170 made it the set's hardest
    /// record).
    private static func foldToClubRange(_ bpm: Double) -> Double { bpm < 80 ? 2 : 1 }

    /// Which ordered pairs can only be a Wash Out (tempos too far apart).
    static func washOuts(_ analyses: [TrackAnalysis]) -> [[Bool]] {
        analyses.map { a in
            analyses.map { b in MixMath.recommendedPreset(rate: MixMath.rate(a: a.grid.bpm, b: b.grid.bpm)) == .echoOut }
        }
    }

    /// A song between two Wash Outs is heard only between two beatless
    /// bridges: it flickers past with no beat carried in or out. A song in
    /// a tempo of its own belongs at an end of the set, not wedged in.
    static let washOutPairPenalty = 1.5

    /// The order with the lowest total transition cost (a shortest
    /// Hamiltonian path over directed costs): exact for small sets, local
    /// search beyond; then moves that keep Wash Outs apart.
    static func order(_ costs: [[Double]], washOuts: [[Bool]]? = nil) -> [Int] {
        let n = costs.count
        guard n > 2 else { return Array(0..<n) }
        if n <= 12 {
            var path = exact(costs)
            if washOuts != nil { improve(&path, costs, washOuts) }
            return path
        }
        var best = Array(0..<n), bestCost = Double.infinity
        for start in 0..<n {
            var path = greedy(costs, from: start)
            improve(&path, costs, washOuts)
            let c = total(path, costs, washOuts)
            if c < bestCost { bestCost = c; best = path }
        }
        return best
    }

    static func total(_ path: [Int], _ costs: [[Double]], _ washOuts: [[Bool]]? = nil) -> Double {
        var sum = zip(path, path.dropFirst()).reduce(0) { $0 + costs[$1.0][$1.1] }
        if let washOuts, path.count > 2 {
            for i in 1..<(path.count - 1) where washOuts[path[i - 1]][path[i]] && washOuts[path[i]][path[i + 1]] {
                sum += washOutPairPenalty
            }
        }
        return sum
    }

    private static func exact(_ costs: [[Double]]) -> [Int] {
        let n = costs.count, full = 1 << n
        var dp = [Double](repeating: .infinity, count: full * n)
        var parent = [Int](repeating: -1, count: full * n)
        for i in 0..<n { dp[(1 << i) * n + i] = 0 }
        for mask in 1..<full {
            for last in 0..<n where mask & (1 << last) != 0 {
                let here = dp[mask * n + last]
                guard here < .infinity else { continue }
                for next in 0..<n where mask & (1 << next) == 0 {
                    let m = mask | (1 << next)
                    let c = here + costs[last][next]
                    if c < dp[m * n + next] { dp[m * n + next] = c; parent[m * n + next] = last }
                }
            }
        }
        var last = (0..<n).min { dp[(full - 1) * n + $0] < dp[(full - 1) * n + $1] }!
        var mask = full - 1
        var path: [Int] = []
        while last >= 0 {
            path.append(last)
            let p = parent[mask * n + last]
            mask &= ~(1 << last)
            last = p
        }
        return path.reversed()
    }

    private static func greedy(_ costs: [[Double]], from start: Int) -> [Int] {
        var path = [start]
        var left = Set(0..<costs.count).subtracting([start])
        while let next = left.min(by: { costs[path.last!][$0] < costs[path.last!][$1] }) {
            path.append(next)
            left.remove(next)
        }
        return path
    }

    /// Or-opt: move single tracks to a better spot until nothing improves.
    private static func improve(_ path: inout [Int], _ costs: [[Double]], _ washOuts: [[Bool]]? = nil) {
        var improved = true
        while improved {
            improved = false
            let current = total(path, costs, washOuts)
            outer: for i in path.indices {
                for j in path.indices where j != i {
                    var p = path
                    let x = p.remove(at: i)
                    p.insert(x, at: j)
                    if total(p, costs, washOuts) < current - 1e-9 {
                        path = p
                        improved = true
                        break outer
                    }
                }
            }
        }
    }
}

/// A transition shaped by hand in the editor. It replaces the automatic plan
/// for that pair of songs for as long as they stay neighbours.
struct TransitionEdit: Equatable, Codable {
    var entryBar: Int
    var cueBar: Int
    var preset: TransitionPreset
    var bars: Int
    var semitones: Int
    /// Automation of both songs, timed in A's own (unstretched) seconds, the
    /// editor's timeline.
    var lanes: [Lane]
    /// Beat rolls, timed like the lanes.
    var rolls: [Roll] = []
}

extension TransitionEdit {
    /// Edits saved before rolls existed have none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryBar = try c.decode(Int.self, forKey: .entryBar)
        cueBar = try c.decode(Int.self, forKey: .cueBar)
        preset = try c.decode(TransitionPreset.self, forKey: .preset)
        bars = try c.decode(Int.self, forKey: .bars)
        semitones = try c.decode(Int.self, forKey: .semitones)
        lanes = try c.decode([Lane].self, forKey: .lanes)
        rolls = try c.decodeIfPresent([Roll].self, forKey: .rolls) ?? []
    }
}

/// Two neighbouring songs, by file.
struct PairKey: Hashable, Codable {
    let from: URL, to: URL
}

/// A whole set, planned and ready to render: every track with its time map,
/// its place on the master timeline and its automation.
struct SetMix: @unchecked Sendable {
    struct Track {
        let url: URL
        let loaded: TrackProcessor.Loaded
        var map: TimeMap
        /// The stretched rendition (nil: the track plays untouched).
        var matched: TrackProcessor.Matched?
        /// Master seconds at which output frame 0 plays.
        var offset: Double
        var envelopes: [StemKind: [Envelope]]
        /// Beat rolls, master seconds.
        var rolls: [Roll] = []
        /// A club edit: the track's own seconds it jumps over, from the
        /// first straight to the second. Always where it plays at its own
        /// tempo, so it's the same length in the set.
        var skip: (from: Double, to: Double)?

        var stems: [StemKind: StemAudio] { matched?.stems ?? loaded.stems }

        /// Master time of a moment in the track's own (unstretched) clock
        /// (for a skipped moment: where it would have been).
        func master(_ seconds: Double) -> Double {
            let s = skip.map { seconds >= $0.to ? seconds - ($0.to - $0.from) : seconds } ?? seconds
            return offset + map.output(s * AudioIO.sampleRate) / AudioIO.sampleRate
        }

        /// Master seconds at which the track jumps.
        var skipAt: Double? { skip.map { master($0.from) } }

        /// Master time of the stems' frame 0 as they sound at master `t`:
        /// past the jump they're `skip`'s length further on.
        func stemOffset(at t: Double) -> Double {
            guard let skip, let at = skipAt, t >= at else { return offset }
            return offset - (skip.to - skip.from)
        }
    }

    struct Transition {
        let from: Int, to: Int
        let plan: PairPlan
        /// What was actually used: the plan's, or the hand edit's.
        let edit: TransitionEdit
        let isEdited: Bool
        /// Master seconds.
        let start: Double, end: Double
        /// Master seconds at which the incoming song is back at its own tempo.
        let settled: Double
        let barSeconds: Double
        /// Master seconds minus A's own seconds around the transition (A is
        /// at its own tempo there), i.e. set time minus editor time.
        let delta: Double
        /// Bars of A the transition may start on: not before A is back at its
        /// own tempo.
        let entryRange: ClosedRange<Int>
        /// Where to start listening: four bars before anything happens (a
        /// Wash Out begins up to eight bars before B's downbeat).
        var cue: Double {
            let lead = edit.preset == .echoOut ? Double(max(1, min(8, edit.bars))) : 0
            return max(0, start - (lead + 4) * barSeconds)
        }
        /// Seconds B was moved to lock its hits onto A's, and how well the
        /// two grooves sit together (0…1).
        var nudge: Double = 0
        var grooveLock: Double = 1
        var grooveLags: [Double] = []
        /// B's drums built in under A's; A's played on under B's after the
        /// swap.
        var drumsLayered = true, drumsLinger = true
        /// Master seconds at which A's vocal is taken out and B's let in
        /// (nil: not automatic, or no vocal to hand over).
        var vocalOut: Double?
        var vocalIn: Double?
        /// What makes it more than a crossfade (hook on the switch, mashup,
        /// roll into the drop), in words.
        var payoff: [String] = []
        /// Master seconds of the switch A rolls into, with its moment of
        /// silence just before (nil: no drop moment).
        var dropAt: Double?
        /// How B's vocal came in: "breath" (before a line), "word" (on a
        /// word's attack), "blend" (mid-line, faded in), "grid" (on the bar,
        /// nothing sounding); nil if automatic phrasing wasn't used.
        var vocalInKind: String?
        /// A's vocal was still singing where it left, so it blended out.
        var vocalOutBlend = false
        /// Bars of A a club edit left out before this transition.
        var skippedBars = 0
        /// The melodies were heard to clash, so they were swapped rather
        /// than layered.
        var melodiesClash = false
        /// dB A's drums and melody made way for B's (EQ).
        var room = 0.0
    }

    var tracks: [Track]
    var transitions: [Transition]
    var length: Double

    func snapshot(masterGain: Float, including: (Int, StemKind) -> Bool = { _, _ in true }) -> MixSnapshot {
        let sr = AudioIO.sampleRate
        var lanes: [MixSnapshot.LaneData] = []
        for (i, t) in tracks.enumerated() {
            let trim = Float(pow(10, MixMath.trimDB(t.loaded.analysis) / 20))
            for stem in StemKind.laneOrder {
                var rolls = t.rolls.filter { $0.stem == stem }
                // The jump plays as one roll that never loops back: from it
                // on, the stem sounds from `skip`'s length further on.
                if let skip = t.skip, let at = t.skipAt, let count = t.stems[stem]?.count {
                    let end = max(at + 1, t.offset + Double(count) / sr)
                    rolls.append(Roll(side: .a, stem: stem, start: at, end: end, anchor: at + skip.to - skip.from,
                                      length: end - at))
                }
                let frameRolls = rolls.sorted { $0.start < $1.start }.compactMap { MixSnapshot.FrameRoll($0, sampleRate: sr) }
                lanes.append(.init(audio: t.stems[stem], offset: Int((t.offset * sr).rounded()),
                                   envelopes: t.envelopes[stem] ?? Lane(side: .a, stem: stem).envelopes,
                                   audible: including(i, stem), trim: trim, rolls: frameRolls))
            }
        }
        // Each transition echoes at the outgoing track's tempo (dotted
        // eighth); switch half-way between transitions.
        var schedule: [(from: Int, seconds: Double)] = []
        var previousEnd = 0.0
        for tr in transitions {
            let from = schedule.isEmpty ? 0 : (previousEnd + tr.start) / 2
            schedule.append((Int(from * sr), tr.barSeconds / 4 * 0.75))
            previousEnd = tr.end
        }
        let first = schedule.first?.seconds ?? 0.35
        return MixSnapshot(lanes: lanes, length: Int(length * sr), delaySeconds: first, masterGain: masterGain,
                           delaySchedule: schedule)
    }
}

/// Locks B's hits onto A's, the way a DJ nudges the platter until the two
/// grooves sit as one. Both beat grids put the beat where the kick peaks,
/// but kicks differ (a clicky one peaks early, a boomy 808 late), and what
/// overlaps in a stem swap is A's whole kit against B's hats and snares: a
/// constant 10–20 ms between them is heard as a smeared, flamming groove.
enum BeatAlign {
    /// A third of a sixteenth at 128 BPM: far enough to fix a grid that
    /// sits off a track's audible hits (Missing's is 37 ms out), not so far
    /// that it could lock onto the next subdivision.
    static let maxNudge = 0.04

    /// How far to delay B (negative: earlier) so its drum hits land on A's,
    /// and how well the two grooves sit together once they do, measured
    /// over the overlap `from…to` (master seconds).
    /// - Parameters:
    ///   - a, b: the drums as they play (A at its own tempo there, B
    ///     stretched to it), output frame 0 at master `aOffset`/`bOffset`.
    static func nudge(a: StemAudio, aOffset: Double, b: StemAudio, bOffset: Double,
                      from: Double, to: Double) -> Result {
        let sr = AudioIO.sampleRate, hop = Double(onsetHop)
        let pad = 2 * maxNudge
        let bFrom = from - bOffset - pad
        guard let ea = onsets(a, from: from - aOffset, to: to - aOffset),
              let eb = onsets(b, from: bFrom, to: to - bOffset + pad) else { return Result(nudge: 0, lock: 1) }
        func score(_ lag: Double, _ frames: Range<Int>) -> Double {
            var sum = 0.0
            for i in frames where ea[i] > 0 {
                let master = from + Double(i) * hop / sr
                let j = (master - lag - bOffset - bFrom) * sr / hop
                let k = Int(j)
                guard k >= 0, k + 1 < eb.count else { continue }
                let f = j - Double(k)
                sum += Double(ea[i]) * (Double(eb[k]) * (1 - f) + Double(eb[k + 1]) * f)
            }
            return sum
        }
        // The best lag of every two bars on its own. A real offset shows up
        // the same in most of them; two different patterns give scattered
        // lags, and then there is nothing to nudge. Each half of the blend
        // votes on its own: before the swap it's A's kit under B's tops,
        // after it the other way round, and grooves can sit differently.
        let window = max(1, Int((to - from) / 8 * sr / hop))
        // Only a window whose hits line up clearly better at one lag than
        // on average says anything about the groove. In a sparse intro (a
        // few hats, a lone snare) every lag scores about the same and the
        // best one is noise: counting those as votes called beats that sit
        // together perfectly "won't lock" and threw away half the blends.
        func lags(_ frames: Range<Int>) -> [Double] {
            var out: [Double] = []
            for w in stride(from: frames.lowerBound, to: frames.upperBound - window + 1, by: window) {
                let f = w..<(w + window)
                guard ea[f].reduce(0, +) > 0 else { continue }
                // Whole onset frames (a millisecond) first, then the peak's
                // own shape through the best and its neighbours: hits are
                // sharp, so it's a V (two lines of equal slope), not a
                // parabola, which would pull the offset towards the
                // nearest frame.
                let frame = hop / sr, reach = Int((maxNudge / frame).rounded())
                let scores = (-reach...reach).map { score(Double($0) * frame, f) }
                let k = scores.indices.max { scores[$0] < scores[$1] }!
                let best = scores[k], mean = scores.reduce(0, +) / Double(scores.count)
                guard best > 0, best > 1.25 * mean else { continue }
                var lag = Double(k - reach)
                if k > 0, k < scores.count - 1 {
                    let left = scores[k - 1], right = scores[k + 1]
                    let fall = best - min(left, right)
                    if fall > 0 { lag += 0.5 * (right - left) / fall }
                }
                out.append(lag * frame)
            }
            return out
        }
        func consensus(_ lags: [Double]) -> Double? {
            guard lags.count >= 2 else { return nil }
            let median = lags.sorted()[lags.count / 2]
            let agreeing = lags.filter { abs($0 - median) <= 0.004 }.count
            return 4 * agreeing >= 3 * lags.count ? median : nil
        }
        let half = ea.count / 2
        let first = lags(0..<half), second = lags(half..<ea.count)
        let votes = [consensus(first), consensus(second)].compactMap { $0 }
        let nudge = votes.isEmpty ? 0 : votes.reduce(0, +) / Double(votes.count)
        let all = first + second
        // Before the swap it's A's kit under B's tops, after it the other
        // way round: each half can groove or not on its own.
        func sits(_ lags: [Double]) -> Double {
            lags.count < 2 ? 1 : Double(lags.filter { abs($0 - nudge) <= 0.008 }.count) / Double(lags.count)
        }
        // How much of the blend sits within 8 ms once nudged (a flam is
        // heard from about 10). Too few clear windows to judge: the two
        // beat grids (tracked, then nudged) are all there is, and they
        // agree by construction.
        let lock = all.count < 3 ? 1 : Double(all.filter { abs($0 - nudge) <= 0.008 }.count) / Double(all.count)
        return Result(nudge: abs(nudge) >= 0.003 ? nudge : 0, lock: lock, lags: all,
                      lockBefore: sits(first), lockAfter: sits(second))
    }

    struct Result {
        /// Seconds to delay B by.
        var nudge: Double
        /// 0…1: how much of the overlap the two drum parts sit together.
        var lock: Double
        /// The best lag of every window that clearly had one (seconds).
        var lags: [Double] = []
        /// The same for each half of the overlap.
        var lockBefore: Double = 1, lockAfter: Double = 1
        /// Two patterns that differ (a dancehall riddim over a straight
        /// beat) leave some windows without a clear lag, and those don't
        /// vote. Of the windows that do, a clear majority has to sit
        /// together: half the blend flamming is still a flam. B's tops
        /// layer under A's kit if the first half grooves.
        var grooves: Bool { lockBefore >= 0.6 }
        /// A's drums play on under B's after the swap.
        var groovesAfter: Bool { grooves && lockAfter >= 0.6 }
    }

    /// Samples per onset frame: a millisecond. The tempo detector's 10 ms
    /// frames smear where a hit lands inside them, so a steady 8 ms flam
    /// read as 0 or 10 by turns: never fixed, and taken for no groove.
    static let onsetHop = 44

    /// Attacks above 150 Hz (the hats, snares and the kick's click, which
    /// is where a flam is heard; the kick's body is never doubled): the
    /// rise of the level, log-compressed so soft hits count, over two
    /// milliseconds, local mean removed, every millisecond of a stretch of
    /// the stem, or nil if it's all but silent.
    private static func onsets(_ stem: StemAudio, from: Double, to: Double) -> [Float]? {
        let sr = AudioIO.sampleRate
        // Frame 0 is `from` even where that's before the file starts.
        let start = Int(from * sr), end = min(stem.count, Int(to * sr))
        guard end - max(0, start) > Int(sr) else { return nil }
        var mono = [Float](repeating: 0, count: end - start)
        for i in max(0, -start)..<mono.count {
            mono[i] = 0.5 * (stem.left.pointer[start + i] + stem.right.pointer[start + i])
        }
        return attacks(mono)
    }

    /// `onsets` of mono audio, frame 0 at its first sample.
    static func attacks(_ input: [Float]) -> [Float]? {
        let sr = AudioIO.sampleRate
        var mono = input, twin = input
        var hp = Biquad()
        hp.set(.highPass(frequency: 150, q: 0.707), sampleRate: sr)
        mono.withUnsafeMutableBufferPointer { m in
            twin.withUnsafeMutableBufferPointer { t in hp.process(m.baseAddress!, t.baseAddress!, count: m.count) }
        }
        let bins = mono.count / onsetHop
        guard bins > 4 else { return nil }
        var level = [Float](repeating: 0, count: bins)
        mono.withUnsafeBufferPointer { m in
            for i in 0..<bins {
                var e: Float = 0
                vDSP_svesq(m.baseAddress! + i * onsetHop, 1, &e, vDSP_Length(onsetHop))
                level[i] = log1p(100 * (e / Float(onsetHop)).squareRoot())
            }
        }
        let rise = (0..<bins).map { i in i < 2 ? 0 : max(0, level[i] - level[i - 2]) }
        guard rise.contains(where: { $0 > 0 }) else { return nil }
        // Minus the mean over ±100 ms: only what stands out is a hit.
        var prefix = [Float](repeating: 0, count: bins + 1)
        for i in 0..<bins { prefix[i + 1] = prefix[i] + rise[i] }
        let w = 100
        return (0..<bins).map { i in
            let lo = max(0, i - w), hi = min(bins, i + w + 1)
            return max(0, rise[i] - (prefix[hi] - prefix[lo]) / Float(hi - lo))
        }
    }
}

/// What the notes that will really play together say, rather than the
/// songs' overall keys: a key estimate can be off, and a song's key isn't
/// every section's.
enum Harmony {
    /// Pitch-class energy (strongest = 1) of `stems` summed, from master
    /// `from` to `to`, each stem's frame 0 at master `offset`; nil if it's
    /// all but silent there.
    static func chroma(_ stems: [StemAudio], offset: Double, from: Double, to: Double) -> [Float]? {
        let sr = AudioIO.sampleRate
        let count = stems.map(\.count).min() ?? 0
        let start = max(0, Int((from - offset) * sr)), end = min(count, Int((to - offset) * sr))
        guard end - start > Int(sr) else { return nil }
        var mono = [Float](repeating: 0, count: end - start)
        for stem in stems {
            for channel in [stem.left, stem.right] {
                vDSP_vadd(mono, 1, channel.pointer + start, 1, &mono, 1, vDSP_Length(mono.count))
            }
        }
        var rms: Float = 0
        vDSP_rmsqv(mono, 1, &rms, vDSP_Length(mono.count))
        guard rms > 1e-3 else { return nil }
        return KeyDetector.computeChroma(samples: mono, sampleRate: sr).map(Float.init)
    }

    /// The two sit together: B's notes lie in A's scale (the diatonic
    /// scale A's notes fit best) about as well as in the scale that suits B
    /// best. A different chord of the same scale fits; notes a semitone or
    /// a tritone off don't.
    /// - Parameter tolerance: how much worse B may sit in A's scale than in
    ///   its own: small to pick a shift, larger to call a clash (only a
    ///   clear one should break up a blend).
    static func fits(_ a: [Float], _ b: [Float], tolerance: Float = 0.08) -> Bool {
        clash(a, b) <= tolerance
    }

    /// How much less the two together sit in one diatonic scale than each
    /// does on its own (0: they share one; a fifth apart ≈ 0.04, a whole
    /// tone ≈ 0.1, a tritone or semitone ≈ 0.3). Heard as one sound, which
    /// is what a blend is, rather than B measured against A's best guess
    /// of a scale (which let almost anything through). Neighbours on the
    /// key wheel are what blends are made of: `fits` lets 0.08 through.
    static func clash(_ a: [Float], _ b: [Float]) -> Float {
        let major = [0, 2, 4, 5, 7, 9, 11]
        func best(_ x: [Float]) -> Float {
            let total = max(1e-6, x.reduce(0, +))
            return (0..<12).map { tonic in major.reduce(0) { $0 + x[($1 + tonic) % 12] } }.max()! / total
        }
        let sa = max(1e-6, a.reduce(0, +)), sb = max(1e-6, b.reduce(0, +))
        let both = zip(a, b).map { $0 / sa + $1 / sb }
        return min(best(a), best(b)) - best(both)
    }

    /// Pitch classes moved up by `semitones`.
    static func transposed(_ chroma: [Float], by semitones: Int) -> [Float] {
        (0..<12).map { chroma[(($0 - semitones) % 12 + 12) % 12] }
    }

    /// B's pitch shift chosen from the notes that will actually overlap
    /// (a quarter to three quarters into the blend, A as it's heard), not
    /// from the songs' overall keys: `preferred` if it fits, else the
    /// smallest shift up to `MixMath.maxKeyShift` that does. nil: none fits
    /// (or nothing to compare).
    static func bestShift(a: TrackProcessor.Loaded, aShift: Int, entryBar: Int,
                          b: TrackProcessor.Loaded, cueBar: Int, bars n: Int, preferred: Int) -> Int? {
        let ga = a.analysis.grid, gb = b.analysis.grid, q = Double(n) / 4
        let aFrom = ga.downbeat(entryBar) + q * ga.barSeconds, bFrom = gb.downbeat(cueBar) + q * gb.barSeconds
        guard let ca = chroma([a.stems[.other], a.stems[.bass]].compactMap { $0 }, offset: 0,
                              from: aFrom, to: aFrom + 2 * q * ga.barSeconds),
              let cb = chroma([b.stems[.other]].compactMap { $0 }, offset: 0,
                              from: bFrom, to: bFrom + 2 * q * gb.barSeconds) else { return nil }
        let heard = transposed(ca, by: aShift)
        // A DJ shifts sparingly (a known voice a tone off gets noticed):
        // the key estimate's own shift, none, or a semitone.
        let candidates = [preferred] + [0, 1, -1].filter { $0 != preferred }
        // The one that sits best; the key estimate's, none, then a
        // semitone where they're about as good.
        let clashes = candidates.map { clash(heard, transposed(cb, by: $0)) }
        let least = clashes.min()!
        guard least <= 0.08 else { return nil }
        return candidates[clashes.firstIndex { $0 <= least + 0.02 }!]
    }

    /// `fits`, when both sides have notes to compare; nothing to clash
    /// with counts as fitting.
    static func fits(_ a: [StemAudio], aOffset: Double, _ b: [StemAudio], bOffset: Double, from: Double, to: Double,
                     tolerance: Float = 0.08) -> Bool {
        guard let ca = chroma(a, offset: aOffset, from: from, to: to),
              let cb = chroma(b, offset: bOffset, from: from, to: to) else { return true }
        return fits(ca, cb, tolerance: tolerance)
    }

    /// Where the key estimates agree, only a clear clash heard in the notes
    /// breaks up a blend; where they say the keys clash, the notes have to
    /// show clearly that they don't.
    static let clashTolerance: Float = 0.10
    static let keysClashTolerance: Float = 0.04
}

extension BeatAlign {
    /// Which beat (0…3) of the bars before `barStart + 4 beats` carries the
    /// snare: the one whose hits have the most bite (high-frequency energy
    /// in their first 60 ms), over the last two bars.
    static func snareBeat(_ drums: StemAudio, offset: Double, barStart: Double, beat: Double) -> Int? {
        let sr = AudioIO.sampleRate, n = Int(0.06 * sr)
        var bite = [Float](repeating: 0, count: 4)
        for bar in [-1.0, 0.0] {
            for k in 0..<4 {
                let i = Int((barStart + (bar * 4 + Double(k)) * beat - offset) * sr)
                guard i >= 0, i + n < drums.count else { return nil }
                for j in max(1, i)..<(i + n) {
                    let d = (drums.left.pointer[j] - drums.left.pointer[j - 1]) + (drums.right.pointer[j] - drums.right.pointer[j - 1])
                    bite[k] += d * d
                }
            }
        }
        guard let best = bite.indices.max(by: { bite[$0] < bite[$1] }), bite[best] > 0 else { return nil }
        return best
    }
}

/// Where vocal lines start and stop, to the beat. A DJ lets the new vocal
/// in on the breath before its next line and takes the old one out on the
/// breath after its last, never mid-word; bars are too coarse for that.
enum VocalPhrasing {
    /// Mean square of `stem` over one beat starting at `time` (seconds of
    /// the stem's own output), in dB.
    private static func level(_ stem: StemAudio, at time: Double, beat: Double) -> Float {
        let sr = AudioIO.sampleRate
        let start = Int(time * sr), end = Int((time + beat) * sr)
        guard start >= 0, end <= stem.count, end > start else { return -90 }
        var l: Float = 0, r: Float = 0
        vDSP_measqv(stem.left.pointer + start, 1, &l, vDSP_Length(end - start))
        vDSP_measqv(stem.right.pointer + start, 1, &r, vDSP_Length(end - start))
        return 10 * log10(max((l + r) / 2, 1e-9))
    }

    /// The level a vocal sings at: its loud bars (90th percentile).
    static func reference(_ structure: TrackStructure?) -> Float? { structure?.vocalReference }

    /// A beat with no more than breath and bleed in it.
    private static func quiet(_ db: Float, _ reference: Float) -> Bool { db < reference - 16 }

    /// Master time to let a vocal in at, as close to `target` as it allows
    /// (no earlier than `earliest`, no later than `latest`): at the second
    /// beat of a pause (two quiet beats), so its next line plays whole and
    /// starts exactly as in the song. nil: it sings straight through, and
    /// the caller eases it in instead.
    /// - Parameter offset: master time of the stem's output frame 0.
    static func lineStart(_ stem: StemAudio, offset: Double, reference: Float, target: Double, earliest: Double,
                          latest: Double, beat: Double) -> Double? {
        func pause(_ t: Double) -> Bool {
            quiet(level(stem, at: t - beat - offset, beat: beat), reference)
                && quiet(level(stem, at: t - offset, beat: beat), reference)
        }
        // Outwards from the target, beat by beat, later first on a tie: a
        // late entry only delays B's vocal, an early one overlaps A's echo.
        var step = 0
        while target - Double(step) * beat >= earliest || target + Double(step) * beat <= latest {
            let later = target + Double(step) * beat, earlier = target - Double(step) * beat
            if later <= latest, pause(later) { return later }
            if step > 0, earlier >= earliest, pause(earlier) { return earlier }
            step += 1
        }
        return nil
    }

    /// Whether the vocal is sounding in the beat starting at `time` (master
    /// seconds): more than breath and bleed.
    static func sounding(_ stem: StemAudio, offset: Double, reference: Float, at time: Double, beat: Double) -> Bool {
        !quiet(level(stem, at: time - offset, beat: beat), reference)
    }

    /// Master time of the strongest word attack on a beat from `earliest`
    /// to `latest`: where to open a vocal that never pauses, so it starts
    /// on a word rather than in the middle of one. nil: nothing stands out.
    static func lineOnset(_ stem: StemAudio, offset: Double, reference: Float, earliest: Double, latest: Double,
                          beat: Double) -> Double? {
        var best: (time: Double, rise: Float)?
        var t = earliest
        while t <= latest {
            let now = level(stem, at: t - offset, beat: beat / 2)
            let rise = now - level(stem, at: t - beat / 2 - offset, beat: beat / 2)
            if now > reference - 10, rise >= 6, rise > best?.rise ?? 0 { best = (t, rise) }
            t += beat
        }
        return best?.time
    }

    /// Master time to take a vocal out at, as close to `target` as it
    /// allows: the first beat of a pause (the line just ended) up to
    /// `before` seconds earlier, or failing that `after` seconds later.
    static func lineEnd(_ stem: StemAudio, offset: Double, reference: Float, target: Double, beat: Double,
                        before: Double, after: Double) -> Double? {
        func pause(_ t: Double) -> Bool {
            quiet(level(stem, at: t - offset, beat: beat), reference)
                && quiet(level(stem, at: t + beat - offset, beat: beat), reference)
        }
        var t = target
        while t >= target - before {
            if pause(t) { return t }
            t -= beat
        }
        t = target + beat
        while t <= target + after {
            if pause(t) { return t }
            t += beat
        }
        return nil
    }
}

/// Plans and renders a set from loaded tracks in a given order.
enum SetBuilder {
    /// Bars every track gets on its own between its glide home and the next
    /// transition, so no record is just passed through. Placement's pacing
    /// decides how much longer: as long as the song keeps its power.
    static let minimumSoloBars = 8

    /// - Parameters:
    ///   - edits: hand-shaped transitions, by pair.
    ///   - reuse: renditions from the last build, reused when their plan
    ///     still matches, so an edit re-renders only what it changed.
    static func build(_ tracks: [(url: URL, loaded: TrackProcessor.Loaded)], edits: [PairKey: TransitionEdit] = [:],
                      reuse: [URL: TrackProcessor.Matched] = [:], processor: TrackProcessor,
                      progress: @escaping @Sendable (String) -> Void) async throws -> SetMix {
        precondition(!tracks.isEmpty)
        let sr = AudioIO.sampleRate
        let first = tracks[0].loaded
        let s0 = first.analysis.structure
        let ref0 = s0?.referenceLoudness ?? -14
        // Open where the beat is going, not on a video's lead-in or a quiet
        // intro: the first four-bar run near the track's full level.
        let loud = s0?.loudness ?? []
        let startBar = loud.indices.first { i in
            i + 4 <= loud.count && loud[i..<(i + 4)].allSatisfy { $0 > ref0 - 8 }
        } ?? 0
        var planned = [SetMix.Track(url: tracks[0].url, loaded: first, map: .constant(1), matched: nil,
                                    offset: -first.analysis.grid.downbeat(startBar), envelopes: [:])]
        var transitions: [SetMix.Transition] = []
        // Where each track is back at its own tempo (its bars): transitions
        // out of it start no earlier, and automatic ones allow it some time
        // on its own first.
        // First every transition's plan, from the analyses alone: what B
        // has to be rendered as doesn't depend on any audio, so all the
        // renditions can then be made at once rather than one by one.
        struct Draft {
            let isEdited: Bool, skip: Range<Int>?, plan: PairPlan
            let entryRange: ClosedRange<Int>, edit: TransitionEdit, rate: Double, glideBars: Int
            let matchPlan: TrackProcessor.MatchPlan
        }
        var drafts: [Draft] = []
        do {
            // Where each track is back at its own tempo (its bars):
            // transitions out of it start no earlier, and automatic ones
            // allow it some time on its own first.
            var settledBar = startBar
            var soloBars = 32
            // Semitones each track plays shifted by.
            var shifts = [0]
            for k in 1..<tracks.count {
                if Task.isCancelled { throw CancellationError() }
                progress("Planning \(k)/\(tracks.count - 1)")
                let a = tracks[k - 1].loaded, b = tracks[k].loaded
                let ga = a.analysis.grid, gb = b.analysis.grid
                let key = PairKey(from: tracks[k - 1].url, to: tracks[k].url)
                let isEdited = edits[key] != nil
                let barsA = ga.barCount(duration: a.analysis.duration)
                // A club edit: once A has the floor, jump over its verse and
                // breakdown to where it repeats the part it's in. Not the
                // opener's (its intro is the set's), not under a hand edit.
                let skip = isEdited || k == 1 ? nil
                    : a.analysis.structure?.skip(from: settledBar + 4, landingBy: barsA - 24)
                let plan = PairPlan.make(a: a.analysis, b: b.analysis, entryRange: (settledBar + soloBars)...Int.max,
                                         aShift: shifts[k - 1], soloFrom: settledBar, skip: skip)
                let lastBar = max(0, barsA - 1)
                let entryRange = min(settledBar, lastBar)...lastBar
                var edit = edits[key] ?? TransitionEdit(entryBar: plan.placement.entryBar, cueBar: plan.placement.cueBar,
                                                        preset: plan.preset, bars: plan.bars, semitones: plan.semitones,
                                                        lanes: [])
                edit.entryBar = min(max(edit.entryBar, entryRange.lowerBound), entryRange.upperBound)
                // The key estimate proposes B's shift; where it hears a clash,
                // the notes that will overlap decide the shift.
                if !isEdited, edit.preset != .echoOut, plan.keysClash || plan.semitones != 0,
                   let shift = Harmony.bestShift(a: a, aShift: shifts[k - 1], entryBar: edit.entryBar, b: b,
                                                 cueBar: edit.cueBar, bars: edit.bars, preferred: edit.semitones) {
                    edit.semitones = shift
                }
                let rate = edit.preset == .echoOut ? 1 : MixMath.rate(a: ga.bpm, b: gb.bpm)
                let span = edit.preset == .echoOut ? 0 : edit.bars
                let glideBars = edit.preset == .echoOut ? 0 : MixMath.glideBars(rate: rate)
                // B glides home from the end of the blend: that far past its
                // cue bar, in B's own output frames.
                let map = TimeMap.glide(rate: rate,
                                        rampStart: (Double(span) * ga.barSeconds + gb.scaled(by: rate).downbeat(edit.cueBar)) * sr,
                                        rampLength: Double(max(1, glideBars)) * ga.barSeconds * sr)
                drafts.append(Draft(isEdited: isEdited, skip: skip, plan: plan, entryRange: entryRange,
                                    edit: edit, rate: rate, glideBars: glideBars,
                                    matchPlan: .init(map: map, semitones: edit.semitones)))
                shifts.append(edit.semitones)
                settledBar = edit.cueBar + span + glideBars
                soloBars = minimumSoloBars
            }
        }

        // Every rendition not already at hand, a few at a time (each is
        // already spread over four cores, and holds a copy of its song).
        var renditions = reuse
        let jobs = drafts.indices.compactMap { i -> (url: URL, loaded: TrackProcessor.Loaded, plan: TrackProcessor.MatchPlan)? in
            let url = tracks[i + 1].url
            if let r = renditions[url], r.plan.isSame(as: drafts[i].matchPlan) { return nil }
            return (url, tracks[i + 1].loaded, drafts[i].matchPlan)
        }
        if !jobs.isEmpty {
            progress("Matching tempos")
            let width = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 4))
            try await withThrowingTaskGroup(of: (URL, TrackProcessor.Matched).self) { group in
                var next = 0
                func start() {
                    let job = jobs[next]
                    next += 1
                    group.addTask { (job.url, try await match(job.loaded, plan: job.plan, processor: processor)) }
                }
                while next < min(width, jobs.count) { start() }
                for try await (url, matched) in group {
                    renditions[url] = matched
                    if next < jobs.count { start() }
                }
            }
        }

        var shifts = [0]
        var sinceDrop = 3

        for k in 1..<tracks.count {
            if Task.isCancelled { throw CancellationError() }
            var a = planned[k - 1]
            let b = tracks[k].loaded
            let ga = a.loaded.analysis.grid, gb = b.analysis.grid
            let draft = drafts[k - 1]
            let isEdited = draft.isEdited, plan = draft.plan, entryRange = draft.entryRange
            var skippedBars = 0
            if let skip = draft.skip, plan.placement.entryBar >= skip.upperBound {
                planned[k - 1].skip = (ga.downbeat(skip.lowerBound), ga.downbeat(skip.upperBound))
                a = planned[k - 1]
                skippedBars = skip.count
            }
            var edit = draft.edit
            let rate = draft.rate

            // Editor time is A's own clock; the set's differs by a constant
            // once A is back at its own tempo.
            let native = ga.downbeat(edit.entryBar)
            let start = a.master(native)
            let delta = start - native
            let span = edit.preset == .echoOut ? 0 : edit.bars
            let end = start + Double(span) * ga.barSeconds
            // Where A's stems sound from around its exit: placement keeps the
            // transition, and the bars heard before it, past any jump.
            let aOffset = a.stemOffset(at: start)
            let offset = start - gb.scaled(by: rate).downbeat(edit.cueBar)
            let matchPlan = draft.matchPlan
            let map = matchPlan.map
            let matched: TrackProcessor.Matched
            if let cached = renditions[tracks[k].url], cached.plan.isSame(as: matchPlan) {
                matched = cached
            } else {
                matched = try await match(b, plan: matchPlan, processor: processor)
            }

            // Measured on the audio that plays: B's stretched drums against
            // A's. The glide may start a few ms off after the nudge; nobody
            // hears that, while re-stretching would cost a second render.
            var align = BeatAlign.Result(nudge: 0, lock: 1)
            if span > 0, let drumsA = a.stems[.drums], let drumsB = matched.stems[.drums] {
                align = BeatAlign.nudge(a: drumsA, aOffset: aOffset, b: drumsB, bOffset: offset, from: start, to: end)
            }
            let nudge = align.nudge
            // Vocals hand over between lines, not mid-word.
            let keysDisagree = MixMath.keysClash(a.loaded.analysis.key.transposed(by: shifts[k - 1]),
                                                 b.analysis.key.transposed(by: edit.semitones))
            var keysClash = keysDisagree
            // Whether the melodies can layer is heard, not guessed from the
            // keys: the notes that will actually overlap (a quarter to three
            // quarters in, B as shifted) decide, where there are any.
            if !isEdited, span > 0, let otherA = a.stems[.other], let otherB = matched.stems[.other] {
                let n = Double(edit.bars), bar = ga.barSeconds
                keysClash = !Harmony.fits([otherA] + [a.stems[.bass]].compactMap { $0 }, aOffset: aOffset,
                                          [otherB], bOffset: offset + nudge,
                                          from: start + n / 4 * bar, to: start + 3 * n / 4 * bar,
                                          tolerance: keysDisagree ? Harmony.keysClashTolerance : Harmony.clashTolerance)
            }
            var vocalIn: Double?, vocalOut: Double?
            var mashup = false
            var vocalInKind: String?
            if !isEdited, edit.preset == .echoOut, let vocalsA = a.stems[.vocals],
               let ref = VocalPhrasing.reference(a.loaded.analysis.structure),
               let t = VocalPhrasing.lineEnd(vocalsA, offset: aOffset, reference: ref, target: start - ga.barSeconds,
                                             beat: ga.barSeconds / 4, before: 2 * ga.barSeconds, after: ga.barSeconds) {
                vocalOut = (t - start) / ga.barSeconds
            }
            if !isEdited, span > 0, let vocalsA = a.stems[.vocals], let vocalsB = matched.stems[.vocals] {
                let n = Double(edit.bars), bar = ga.barSeconds, beat = bar / 4
                let v = min(n, max(n / 2, Double(plan.placement.vocalHandoff)))
                let sw = min(n, max(n / 2, Double(plan.placement.lowSwap ?? edit.bars / 2)))
                let refA = VocalPhrasing.reference(a.loaded.analysis.structure)
                // A mashup moment: B's vocal sings over A's beat from early
                // in the blend, where placement found it pays off. Only if
                // it can't go wrong as it plays: the grooves lock, B's line
                // starts clean in the window, and A's vocal (if any) has
                // finished a line by then.
                // B's voice has to sit on A's chords, as they play there.
                if plan.placement.mashup, edit.preset == .stemSwap, !keysClash, align.grooves,
                   let refB = VocalPhrasing.reference(b.analysis.structure),
                   Harmony.fits([a.stems[.other], a.stems[.bass]].compactMap { $0 }, aOffset: aOffset,
                                [vocalsB], bOffset: offset + nudge,
                                from: start + n / 4 * bar, to: start + n / 2 * bar) {
                    let window = TransitionBuilder.mashupWindow(bars: edit.bars)
                    if let tin = VocalPhrasing.lineStart(vocalsB, offset: offset + nudge, reference: refB,
                                                         target: start + window.earliest * bar,
                                                         earliest: start + window.earliest * bar,
                                                         latest: start + window.latest * bar, beat: beat) {
                        if let refA {
                            if let tout = VocalPhrasing.lineEnd(vocalsA, offset: aOffset, reference: refA, target: tin,
                                                                beat: beat, before: 4 * bar, after: 0), tout <= tin {
                                vocalIn = (tin - start) / bar
                                vocalOut = (tout - start) / bar
                                mashup = true
                            }
                        } else {
                            vocalIn = (tin - start) / bar
                            mashup = true
                        }
                        if mashup { vocalInKind = "breath" }
                    }
                }
                if !mashup {
                    if let ref = VocalPhrasing.reference(b.analysis.structure) {
                        let earliest = start + n / 2 * bar, latest = start + (v + 4) * bar
                        if let t = VocalPhrasing.lineStart(vocalsB, offset: offset + nudge, reference: ref,
                                                           target: start + v * bar, earliest: earliest,
                                                           latest: latest, beat: beat) {
                            vocalIn = (t - start) / bar
                            vocalInKind = "breath"
                        } else if let t = VocalPhrasing.lineOnset(vocalsB, offset: offset + nudge, reference: ref,
                                                                  earliest: earliest, latest: latest, beat: beat) {
                            vocalIn = (t - start) / bar
                            vocalInKind = "word"
                        }
                    }
                    // A's vocal sings on over B's beat until B's own arrives
                    // (an a cappella over the new song: both are heard), if
                    // its notes sit on B's chords there; otherwise it leaves
                    // as B takes the low end.
                    let untilB = vocalIn ?? v
                    let acappella = !keysClash && untilB > sw
                        && Harmony.fits([vocalsA], aOffset: aOffset,
                                        [matched.stems[.other], matched.stems[.bass]].compactMap { $0 }, bOffset: offset + nudge,
                                        from: start + sw * bar, to: start + untilB * bar)
                    let target = acappella ? untilB : min(untilB, min(v, sw))
                    if let refA, let t = VocalPhrasing.lineEnd(vocalsA, offset: aOffset, reference: refA,
                                                               target: start + target * bar, beat: beat,
                                                               before: 4 * bar, after: acappella ? 0 : 2 * bar) {
                        vocalOut = min((t - start) / bar, vocalIn ?? n)
                    }
                }
            }
            var payoff: [String] = []
            var room = 0.0
            var dropAt: Double?
            var vocalOutBlend = false
            if !isEdited {
                // Grooves that won't lock (a swung beat against a straight
                // one) aren't layered: A's beat plays on and B's drums come
                // in whole on the swap.
                // A roll into the drop is a moment only if it isn't every
                // transition: at most one in three (a Drop Swap is built on
                // it), and only after a blend long enough to be one.
                let dropMoment = plan.placement.dropMoment && edit.preset != .echoOut
                    && (edit.preset == .dropSwap || (edit.bars >= 16 && sinceDrop >= 3))
                sinceDrop = dropMoment ? 0 : sinceDrop + 1
                let n = Double(edit.bars)
                let switchBar = edit.preset == .dropSwap ? n / 2
                    : min(n, max(n / 2, Double(plan.placement.lowSwap ?? edit.bars / 2)))
                let rollBeat = dropMoment ? a.stems[.drums].flatMap {
                    BeatAlign.snareBeat($0, offset: aOffset, barStart: start + (switchBar - 1) * ga.barSeconds,
                                        beat: ga.barSeconds / 4)
                } : nil
                func make(outFade: Double, inFade: Double, room: Double, start: Double? = nil,
                          barSeconds: Double? = nil) -> TransitionBuilder.Made {
                    TransitionBuilder.make(edit.preset, lanes: Lane.allLanes(), start: start ?? ga.downbeat(edit.entryBar),
                                           barSeconds: barSeconds ?? ga.barSeconds, bars: edit.bars,
                                           vocalBar: mashup ? plan.placement.vocalHandoff
                                               : max(edit.bars / 2, plan.placement.vocalHandoff),
                                           keysClash: keysClash, lowSwap: plan.placement.lowSwap,
                                           drumsLayer: align.grooves, drumsLinger: align.groovesAfter,
                                           vocalIn: vocalIn, vocalOut: vocalOut,
                                           mashup: mashup, dropMoment: dropMoment, rollBeat: rollBeat,
                                           vocalOutFade: outFade, vocalInFade: inFade, room: room)
                }
                // Room for B: A's EQ gives way as much as B's parts need to
                // be heard, judged on the blend as it will play (B through
                // its entry filters, its drums in or not, A's voice on).
                if edit.preset == .stemSwap, let sa = a.loaded.analysis.structure, let sb = b.analysis.structure,
                   let pa = AutoPlacement.powers(sa, trim: Float(MixMath.trimDB(a.loaded.analysis))),
                   let pb = AutoPlacement.powers(sb, trim: Float(MixMath.trimDB(b.analysis))) {
                    let q = max(1, edit.bars / 4)
                    let plain = TransitionShape(lanes: make(outFade: 0, inFade: 0, room: 0, start: 0, barSeconds: 1).lanes,
                                                preset: edit.preset, bars: edit.bars)
                    room = AutoPlacement.room(plain, a: pa, e: edit.entryBar, b: pb, c: edit.cueBar, from: q,
                                              to: max(q + 1, Int(switchBar)))
                }
                var made = make(outFade: 0, inFade: 0, room: room)
                // Cut or blend, from what each vocal is doing right there. A
                // cut is clean where A's line has ended and B's is starting;
                // where A is still singing it would chop a word, so A blends
                // out under its echo over the bar before; where B comes in
                // mid-line (no breath, no word to start on) it blends in over
                // half a bar.
                let bar = ga.barSeconds, beat = bar / 4
                var outFade = 0.0, inFade = 0.0
                if let exit = made.vocalExit, let vocalsA = a.stems[.vocals],
                   let ref = VocalPhrasing.reference(a.loaded.analysis.structure),
                   VocalPhrasing.sounding(vocalsA, offset: aOffset, reference: ref, at: start + exit * bar, beat: beat) {
                    outFade = 1
                }
                if vocalIn == nil, let entry = made.vocalEntry, let vocalsB = matched.stems[.vocals],
                   let ref = VocalPhrasing.reference(b.analysis.structure),
                   VocalPhrasing.sounding(vocalsB, offset: offset + nudge, reference: ref, at: start + entry * bar - beat,
                                          beat: beat) {
                    inFade = 0.5
                }
                if outFade > 0 || inFade > 0 { made = make(outFade: outFade, inFade: inFade, room: room) }
                if made.vocalEntry != nil, VocalPhrasing.reference(b.analysis.structure) != nil {
                    vocalInKind = inFade > 0 ? "blend" : vocalInKind ?? "grid"
                } else {
                    vocalInKind = nil
                }
                vocalOutBlend = outFade > 0
                edit.lanes = made.lanes
                edit.rolls = made.rolls
                payoff = plan.placement.payoff.filter { !$0.hasPrefix("mashup") && $0 != "roll into the drop" }
                if mashup { payoff.append("mashup: B sings over A's beat") }
                if dropMoment { payoff.append("roll into the drop") }
                if dropMoment { dropAt = start + switchBar * ga.barSeconds }
            }
            var incoming = SetMix.Track(url: tracks[k].url, loaded: b, map: map, matched: matched, offset: offset + nudge,
                                        envelopes: [:])
            for lane in edit.lanes {
                let shifted = lane.envelopes.map { shift($0, by: delta) }
                if lane.side == .a {
                    planned[k - 1].envelopes[lane.stem] = merge(planned[k - 1].envelopes[lane.stem], shifted)
                } else {
                    incoming.envelopes[lane.stem] = shifted
                }
            }
            for roll in edit.rolls {
                if roll.side == .a {
                    // Past a jump the stems sound further on than set time
                    // says; the roll's loop has to be found there too.
                    var shifted = roll.shifted(by: delta)
                    if let jump = a.skip, let at = a.skipAt, shifted.start >= at { shifted.anchor += jump.to - jump.from }
                    planned[k - 1].rolls.append(shifted)
                } else {
                    incoming.rolls.append(roll.shifted(by: delta))
                }
            }
            let settled = map.hasGlide ? offset + nudge + map.rampEnd / sr : end
            planned.append(incoming)
            transitions.append(.init(from: k - 1, to: k, plan: plan, edit: edit, isEdited: isEdited, start: start,
                                     end: end, settled: settled, barSeconds: ga.barSeconds, delta: delta,
                                     entryRange: entryRange, nudge: nudge, grooveLock: align.lock, grooveLags: align.lags,
                                     drumsLayered: align.grooves, drumsLinger: align.groovesAfter,
                                     vocalOut: vocalOut.map { start + $0 * ga.barSeconds },
                                     vocalIn: vocalIn.map { start + $0 * ga.barSeconds }, payoff: payoff, dropAt: dropAt,
                                     vocalInKind: vocalInKind, vocalOutBlend: vocalOutBlend, skippedBars: skippedBars,
                                     melodiesClash: keysClash, room: room))
            shifts.append(edit.semitones)
        }

        // The last record plays out to the end of its music, fading over the
        // final eight bars.
        let last = planned[planned.count - 1]
        let gl = last.loaded.analysis.grid
        let sl = last.loaded.analysis.structure
        let refL = sl?.referenceLoudness ?? -14
        let endBar = (sl?.loudness.lastIndex { $0 > refL - 12 }).map { $0 + 1 }
            ?? gl.barCount(duration: last.loaded.analysis.duration)
        let end = last.master(gl.downbeat(endBar))
        let fadeStart = last.master(gl.downbeat(max(0, endBar - 8)))
        for stem in StemKind.allCases {
            var env = planned[planned.count - 1].envelopes[stem] ?? Lane(side: .a, stem: stem).envelopes
            env[LaneParameter.volume.rawValue].insert(AutomationPoint(time: fadeStart, value: 1, curve: .logarithmic))
            env[LaneParameter.volume.rawValue].insert(AutomationPoint(time: end, value: 0))
            planned[planned.count - 1].envelopes[stem] = env
        }
        return SetMix(tracks: planned, transitions: transitions, length: end + 1)
    }

    private static func shift(_ envelope: Envelope, by delta: Double) -> Envelope {
        var out = Envelope()
        for point in envelope.points {
            var q = point
            q.time += delta
            out.insert(q)
        }
        return out
    }

    /// A track's automation from its entry and its exit: the two never
    /// overlap in time, so the union of their points is both.
    private static func merge(_ existing: [Envelope]?, _ new: [Envelope]) -> [Envelope] {
        guard var result = existing else { return new }
        for p in LaneParameter.allCases {
            for point in new[p.rawValue].points { result[p.rawValue].insert(point) }
        }
        return result
    }

    private static func match(_ loaded: TrackProcessor.Loaded, plan: TrackProcessor.MatchPlan,
                              processor: TrackProcessor) async throws -> TrackProcessor.Matched {
        try await withCheckedThrowingContinuation { continuation in
            processor.match(loaded, plan: plan, ticket: .init()) { continuation.resume(with: $0) }
        }
    }
}
