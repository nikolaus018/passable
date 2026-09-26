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

    /// Beyond this, stretching B is audible: Echo Out, no overlap.
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

    static func keysClash(_ a: MusicalKey, _ b: MusicalKey) -> Bool {
        b.harmonicShift(toMatch: a, limit: 0) == nil
    }
}

/// Everything decided about one transition, from the two analyses alone.
struct PairPlan: Equatable {
    var preset: TransitionPreset
    var bars: Int
    /// B's rate during the overlap (1 for Echo Out).
    var rate: Double
    var placement: AutoPlacement.Result
    var keysClash: Bool

    var stretchPercent: Double { (rate - 1) * 100 }

    static func make(a: TrackAnalysis, b: TrackAnalysis, entryRange: ClosedRange<Int>? = nil) -> PairPlan {
        let rate = MixMath.rate(a: a.grid.bpm, b: b.grid.bpm)
        let preset = MixMath.recommendedPreset(rate: rate)
        let bars = preset.defaultBars
        let placement = AutoPlacement.place(a: a, b: b, bars: bars, preset: preset,
                                            trimA: Float(MixMath.trimDB(a)), trimB: Float(MixMath.trimDB(b)),
                                            entryRange: entryRange)
        return PairPlan(preset: preset, bars: bars, rate: preset == .echoOut ? 1 : rate,
                        placement: placement, keysClash: MixMath.keysClash(a.key, b.key))
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
        default: cost = 1.5 + 0.05 * stretch // Echo Out: fine once, not all night
        }
        if keysClash { cost += 0.8 }
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

    /// Hip-hop detected at 70-something is felt at double time in a club.
    private static func foldToClubRange(_ bpm: Double) -> Double { bpm < 90 ? 2 : 1 }

    /// The order with the lowest total transition cost (a shortest
    /// Hamiltonian path over directed costs): exact for small sets, local
    /// search beyond.
    static func order(_ costs: [[Double]]) -> [Int] {
        let n = costs.count
        guard n > 2 else { return Array(0..<n) }
        if n <= 12 { return exact(costs) }
        var best = Array(0..<n), bestCost = Double.infinity
        for start in 0..<n {
            var path = greedy(costs, from: start)
            improve(&path, costs)
            let c = total(path, costs)
            if c < bestCost { bestCost = c; best = path }
        }
        return best
    }

    static func total(_ path: [Int], _ costs: [[Double]]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + costs[$1.0][$1.1] }
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
    private static func improve(_ path: inout [Int], _ costs: [[Double]]) {
        var improved = true
        while improved {
            improved = false
            let current = total(path, costs)
            outer: for i in path.indices {
                for j in path.indices where j != i {
                    var p = path
                    let x = p.remove(at: i)
                    p.insert(x, at: j)
                    if total(p, costs) < current - 1e-9 {
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

        var stems: [StemKind: StemAudio] { matched?.stems ?? loaded.stems }

        /// Master time of a moment in the track's own (unstretched) clock.
        func master(_ seconds: Double) -> Double {
            offset + map.output(seconds * AudioIO.sampleRate) / AudioIO.sampleRate
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
                lanes.append(.init(audio: t.stems[stem], offset: Int((t.offset * sr).rounded()),
                                   envelopes: t.envelopes[stem] ?? Lane(side: .a, stem: stem).envelopes,
                                   audible: including(i, stem), trim: trim))
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

/// Plans and renders a set from loaded tracks in a given order.
enum SetBuilder {
    /// Bars every track gets on its own between its glide home and the next
    /// transition, so no record is just passed through.
    static let minimumSoloBars = 16

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
        var settledBar = startBar
        var soloBars = 32

        for k in 1..<tracks.count {
            if Task.isCancelled { throw CancellationError() }
            let a = planned[k - 1], b = tracks[k].loaded
            let ga = a.loaded.analysis.grid, gb = b.analysis.grid
            progress("Planning \(k)/\(tracks.count - 1)")
            let plan = PairPlan.make(a: a.loaded.analysis, b: b.analysis, entryRange: (settledBar + soloBars)...Int.max)
            let barsA = ga.barCount(duration: a.loaded.analysis.duration)
            let lastBar = max(0, barsA - 1)
            let entryRange = min(settledBar, lastBar)...lastBar

            let key = PairKey(from: a.url, to: tracks[k].url)
            let isEdited = edits[key] != nil
            var edit = edits[key] ?? TransitionEdit(entryBar: plan.placement.entryBar, cueBar: plan.placement.cueBar,
                                                    preset: plan.preset, bars: plan.bars, semitones: 0, lanes: [])
            edit.entryBar = min(max(edit.entryBar, entryRange.lowerBound), entryRange.upperBound)
            let rate = edit.preset == .echoOut ? 1 : MixMath.rate(a: ga.bpm, b: gb.bpm)
            if !isEdited {
                let keysClash = MixMath.keysClash(a.loaded.analysis.key, b.analysis.key)
                edit.lanes = TransitionBuilder.build(edit.preset, lanes: Lane.allLanes(), start: ga.downbeat(edit.entryBar),
                                                     barSeconds: ga.barSeconds, bars: edit.bars,
                                                     vocalBar: plan.placement.vocalHandoff, keysClash: keysClash,
                                                     lowSwap: plan.placement.lowSwap)
            }

            // Editor time is A's own clock; the set's differs by a constant
            // once A is back at its own tempo.
            let native = ga.downbeat(edit.entryBar)
            let start = a.master(native)
            let delta = start - native
            let span = edit.preset == .echoOut ? 0 : edit.bars
            let end = start + Double(span) * ga.barSeconds
            let offset = start - gb.scaled(by: rate).downbeat(edit.cueBar)
            let glideBars = edit.preset == .echoOut ? 0 : MixMath.glideBars(rate: rate)
            let map = TimeMap.glide(rate: rate, rampStart: (end - offset) * sr,
                                    rampLength: Double(max(1, glideBars)) * ga.barSeconds * sr)
            let matchPlan = TrackProcessor.MatchPlan(map: map, semitones: edit.semitones)
            let matched: TrackProcessor.Matched
            if let cached = reuse[tracks[k].url], cached.plan.isSame(as: matchPlan) {
                matched = cached
            } else {
                matched = try await match(b, plan: matchPlan, processor: processor)
            }

            var incoming = SetMix.Track(url: tracks[k].url, loaded: b, map: map, matched: matched, offset: offset,
                                        envelopes: [:])
            for lane in edit.lanes {
                let shifted = lane.envelopes.map { shift($0, by: delta) }
                if lane.side == .a {
                    planned[k - 1].envelopes[lane.stem] = merge(planned[k - 1].envelopes[lane.stem], shifted)
                } else {
                    incoming.envelopes[lane.stem] = shifted
                }
            }
            let settled = map.hasGlide ? offset + map.rampEnd / sr : end
            planned.append(incoming)
            transitions.append(.init(from: k - 1, to: k, plan: plan, edit: edit, isEdited: isEdited, start: start,
                                     end: end, settled: settled, barSeconds: ga.barSeconds, delta: delta,
                                     entryRange: entryRange))
            settledBar = edit.cueBar + span + glideBars
            soloBars = minimumSoloBars
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
