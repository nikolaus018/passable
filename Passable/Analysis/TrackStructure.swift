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
    /// The vocal's level per beat, in dB: where its lines start and stop,
    /// which bars are too coarse for. Optional like the above.
    var vocalBeatLevel: [Float]?
    /// Per bar, 0…1: how strongly a hook (the chorus, the drop: what the
    /// crowd waits for) starts there. Optional like the above.
    var hookStart: [Float]?
    /// Per bar, the 12 pitch-class energies of the melody and vocal: where
    /// the song repeats itself, for hooks and for jumps. Optional like the
    /// above.
    var barChroma: [[Float]]?

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
        var vocalBeats: [Float] = []
        if let vocals = stems[.vocals] {
            var i = 0
            while true {
                let start = Int(grid.beat(i) * sr), end = Int(grid.beat(i + 1) * sr)
                guard end <= vocals.count else { break }
                var l: Float = 0, r: Float = 0
                vDSP_measqv(vocals.left.pointer + start, 1, &l, vDSP_Length(end - start))
                vDSP_measqv(vocals.right.pointer + start, 1, &r, vDSP_Length(end - start))
                vocalBeats.append(10 * log10(max((l + r) / 2, 1e-9)))
                i += 1
            }
        }
        // Harmony and melody per bar (the melody stems and the vocal, which
        // is what a chorus repeats), for finding the hooks.
        var chroma: [[Float]] = []
        if let other = stems[.other] {
            let vocals = stems[.vocals]
            var bar = 0
            while true {
                let start = Int(grid.downbeat(bar) * sr), end = Int(grid.downbeat(bar + 1) * sr)
                guard end <= other.count, end <= vocals?.count ?? end else { break }
                bar += 1
                guard start >= 0 else { chroma.append([Float](repeating: 0, count: 12)); continue }
                let n = end - start
                var mono = [Float](repeating: 0, count: n)
                for channel in [other.left, other.right] + (vocals.map { [$0.left, $0.right] } ?? []) {
                    vDSP_vadd(mono, 1, channel.pointer + start, 1, &mono, 1, vDSP_Length(n))
                }
                chroma.append(KeyDetector.computeChroma(samples: mono, sampleRate: sr).map(Float.init))
            }
        }
        var structure = TrackStructure(activity: activity, loudness: loudness, stemLevel: stemLevel,
                                       stemLowLevel: stemLowLevel, vocalBeatLevel: vocalBeats)
        structure.hookStart = hookStarts(chroma: chroma, structure: structure)
        structure.barChroma = chroma
        return structure
    }

    /// How strongly a hook starts on each bar (0…1). A hook is what a song
    /// comes back to at full power: its harmony and melody return later in
    /// the song (compared four bars at a time, the song's average harmony
    /// taken out so a verse in the same key doesn't count), it's among the
    /// song's loudest parts with beat and bass going, and a new section
    /// starts on it, lifting from what came before.
    /// - Parameter chroma: per bar, the 12 pitch-class energies of the
    ///   melody and vocal.
    static func hookStarts(chroma: [[Float]], structure s: TrackStructure) -> [Float] {
        let drums = s.activity(.drums), bass = s.activity(.bass)
        let n = min(chroma.count, s.loudness.count, drums.count, bass.count)
        guard n >= 24 else { return [Float](repeating: 0, count: max(0, n)) }

        let centred = Array(centredChroma(chroma)[0..<n])
        func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        // Four bars starting at b against the best match at least eight
        // bars away: a section the song plays again.
        let blocks = n - 3
        var repetition = [Float](repeating: 0, count: n)
        for b in 0..<blocks {
            var best: Float = -1
            for c in 0..<blocks where abs(c - b) >= 8 {
                let sim = (0..<4).reduce(Float(0)) { $0 + dot(centred[b + $1], centred[c + $1]) } / 4
                best = max(best, sim)
            }
            repetition[b] = best
        }
        func spread(_ x: [Float]) -> [Float] {
            let sorted = x.sorted()
            let mid = sorted[sorted.count / 2], high = sorted[sorted.count * 9 / 10]
            guard high - mid > 1e-4 else { return x.map { _ in 0 } }
            return x.map { min(1, max(0, ($0 - mid) / (high - mid))) }
        }
        let repeats = spread(Array(repetition[0..<blocks])) + [Float](repeating: 0, count: n - blocks)
        let reference = s.referenceLoudness
        let power: [Float] = (0..<n).map { b in
            let energy = min(1, max(0, (s.loudness[b] - (reference - 9)) / 9))
            let full = min(1, drums[b]) * min(1, bass[b])
            return 0.45 * repeats[b] + 0.35 * energy + 0.2 * full
        }
        func section(_ r: Range<Int>) -> Float {
            let r = max(0, r.lowerBound)..<min(n, r.upperBound)
            return r.isEmpty ? 0 : power[r].reduce(0, +) / Float(r.count)
        }
        let sections = (0..<n).map { section($0..<($0 + 8)) }
        let ranked = spread(sections)
        let boundary = s.boundaryStrength()
        return (0..<n).map { b in
            let lift = min(1, max(0, (sections[b] - section((b - 4)..<b)) / 0.2))
            let starts = min(1, (b < boundary.count ? boundary[b] : 0) / 0.4)
            return ranked[b] * (0.5 + 0.5 * lift) * starts
        }
    }

    /// Per bar, the chroma with the song's average taken out and scaled to
    /// unit length: what's particular to that bar (silent bars are zero).
    static func centredChroma(_ chroma: [[Float]]) -> [[Float]] {
        var mean = [Float](repeating: 0, count: 12)
        let voiced = chroma.indices.filter { chroma[$0].contains { $0 > 0 } }
        for b in voiced { for p in 0..<12 { mean[p] += chroma[b][p] / Float(max(1, voiced.count)) } }
        return chroma.map { bar in
            guard bar.contains(where: { $0 > 0 }) else { return [Float](repeating: 0, count: 12) }
            let v = (0..<12).map { bar[$0] - mean[$0] }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return norm > 1e-6 ? v.map { $0 / norm } : [Float](repeating: 0, count: 12)
        }
    }

    /// Below full power: a verse, a breakdown, the beat or the bass gone.
    /// What cools a floor when a song plays it on its own.
    func sags(_ bar: Int) -> Bool {
        let drums = activity(.drums), bass = activity(.bass)
        guard bar >= 0, bar < loudness.count else { return false }
        let full = bar < drums.count && bar < bass.count && min(drums[bar], bass[bar]) >= 0.4
        return loudness[bar] < referenceLoudness - 3.5 || !full
    }

    /// A club edit: bars `x..<y` the song can leave out, jumping from bar x
    /// straight to bar y, because the song repeats itself there: the four
    /// bars on either side of x sound like those on either side of y (same
    /// harmony and melody, level, beat and bass), so the jump is a seam no
    /// one hears, and no vocal line is cut in two (both points sit in a
    /// pause, or the vocal repeats too). Worth it only if what it leaves out
    /// is mostly verse and breakdown. nil: no such jump from `earliest` on
    /// that lands by `latest`.
    func skip(from earliest: Int, landingBy latest: Int) -> Range<Int>? {
        guard let chroma = barChroma, chroma.count >= 32 else { return nil }
        let c = Self.centredChroma(chroma)
        let n = min(c.count, loudness.count)
        let phase = phrasePhase(), pauses = vocalQuietBeats
        let drums = activity(.drums), bass = activity(.bass)
        func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        func similarity(_ x: Int, _ y: Int) -> Float? {
            guard x >= 4, y + 4 <= n else { return nil }
            var sum: Float = 0
            for k in -4..<4 {
                let a = c[x + k], b = c[y + k]
                guard a.contains(where: { $0 != 0 }), b.contains(where: { $0 != 0 }) else { return nil }
                sum += dot(a, b)
            }
            return sum / 8
        }
        func mean(_ a: [Float], _ r: Range<Int>) -> Float {
            let r = max(0, r.lowerBound)..<min(a.count, r.upperBound)
            return r.isEmpty ? 0 : a[r].reduce(0, +) / Float(r.count)
        }
        func seamless(_ x: Int, _ y: Int) -> Bool {
            guard let pauses else { return true }
            return (pauses.isQuiet(4 * x - 1) || pauses.isQuiet(4 * x)) && (pauses.isQuiet(4 * y - 1) || pauses.isQuiet(4 * y))
        }
        var best: (range: Range<Int>, score: Float)?
        for x in max(4, earliest)..<max(max(4, earliest), min(n, latest)) where ((x - phase) % 4 + 4) % 4 == 0 {
            for y in stride(from: x + 8, through: min(latest, n - 4), by: 4) {
                guard let sim = similarity(x, y), sim >= 0.75,
                      abs(meanLoudness(bars: (x - 4)..<(x + 4)) - meanLoudness(bars: (y - 4)..<(y + 4))) <= 1.5,
                      abs(mean(drums, x..<(x + 4)) - mean(drums, y..<(y + 4))) <= 0.25,
                      abs(mean(bass, x..<(x + 4)) - mean(bass, y..<(y + 4))) <= 0.25,
                      seamless(x, y) || sim >= 0.9 else { continue }
                let sag = (x..<y).filter { sags($0) }.count
                guard sag >= 6, 2 * sag >= y - x else { continue }
                let score = sim + 0.05 * Float(sag)
                if score > best?.score ?? -1 { best = (x..<y, score) }
            }
        }
        return best?.range
    }

    /// 0…1: how strongly a hook starts on `bar`.
    func hook(_ bar: Int) -> Float {
        guard let h = hookStart, bar >= 0, bar < h.count else { return 0 }
        return h[bar]
    }
}

extension TrackStructure {
    /// The level the vocal sings at: its loud bars (90th percentile). nil
    /// for an instrumental, whose vocal stem is only separation bleed: its
    /// "lines" would be noise.
    var vocalReference: Float? {
        guard let levels = stemLevel?[StemKind.vocals.rawValue]?.filter({ $0 > -80 }).sorted(), !levels.isEmpty
        else { return nil }
        let reference = levels[min(levels.count - 1, levels.count * 9 / 10)]
        return reference > -45 ? reference : nil
    }

    /// Per beat: no more of the vocal than breath and bleed. nil for
    /// structures measured before per-beat levels existed.
    var vocalQuietBeats: VocalPauses? {
        guard let beats = vocalBeatLevel, let reference = vocalReference else { return nil }
        return VocalPauses(quiet: beats.map { $0 < reference - 16 })
    }
}

/// Where a vocal is silent, beat by beat: where its lines can be let in or
/// taken out cleanly.
struct VocalPauses {
    let quiet: [Bool]

    /// Beats outside the song count as quiet.
    func isQuiet(_ i: Int) -> Bool { i < 0 || i >= quiet.count || quiet[i] }

    /// Two quiet beats somewhere in `range`: a line can start (or has
    /// ended) there without cutting one in two.
    func hasPause(in range: ClosedRange<Int>) -> Bool {
        range.contains { isQuiet($0 - 1) && isQuiet($0) }
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

    init(_ preset: TransitionPreset, bars n: Int, vocalBar: Int?, keysClash: Bool, lowSwap: Int?, mashup: Bool = false,
         drumsLayer: Bool = true, room: Double = 0, dropMoment: Bool = false, vocalIn: Double? = nil) {
        self.init(lanes: TransitionBuilder.build(preset, lanes: Lane.allLanes(), start: 0, barSeconds: 1, bars: n,
                                                 vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap,
                                                 drumsLayer: drumsLayer, vocalIn: vocalIn, mashup: mashup,
                                                 dropMoment: dropMoment, room: room),
                  preset: preset, bars: n)
    }

    private struct Key: Hashable {
        let preset: TransitionPreset, bars: Int, vocalBar: Int?, keysClash: Bool, lowSwap: Int?, mashup: Bool
        let room: Double, dropMoment: Bool, vocalIn: Double?, drumsLayer: Bool
    }
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var shapes: [Key: TransitionShape] = [:]
    }
    private static let cache = Cache()

    /// The same, built once per app run: a shape depends on the transition
    /// alone, not on the songs, and placement asks for the same few
    /// thousand over and over (every pair, every spot).
    static func cached(_ preset: TransitionPreset, bars n: Int, vocalBar: Int?, keysClash: Bool, lowSwap: Int?,
                       mashup: Bool, room: Double, dropMoment: Bool, vocalIn: Double?,
                       drumsLayer: Bool = true) -> TransitionShape {
        let key = Key(preset: preset, bars: n, vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap, mashup: mashup,
                      room: room, dropMoment: dropMoment, vocalIn: vocalIn, drumsLayer: drumsLayer)
        cache.lock.lock()
        if let shape = cache.shapes[key] { cache.lock.unlock(); return shape }
        cache.lock.unlock()
        let shape = TransitionShape(preset, bars: n, vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap,
                                    mashup: mashup, drumsLayer: drumsLayer, room: room, dropMoment: dropMoment,
                                    vocalIn: vocalIn)
        cache.lock.lock()
        cache.shapes[key] = shape
        cache.lock.unlock()
        return shape
    }

    /// The shape of automation already written, starting at 0 with
    /// one-second bars.
    init(lanes: [Lane], preset: TransitionPreset, bars n: Int) {
        (first, last) = preset == .echoOut ? (-max(1, min(n, 8)), 0) : (0, n)
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
        // As the mixer plays it: a kill is an isolator (the kick and bass
        // line 20–50 dB down, half a dB off the highs), a
        // lesser cut or a boost a shelf under 150 Hz.
        let lowDB = LaneParameter.eqDecibels(lane[.low].value(at: t, default: 0.5))
        if lowDB <= MixRenderer.killDB {
            low *= pow(10, -25 / 10)
            high *= pow(10, -0.5 / 10)
        } else {
            low *= pow(10, lowDB / 10)
        }
        // The mid bell and the high shelf cut together take about 0.55 dB
        // off a stem's power above 150 Hz per dB (measured on real drums
        // and melodies: much of it sits in the low mids, below both).
        let mid = LaneParameter.eqDecibels(lane[.mid].value(at: t, default: 0.5))
        let top = LaneParameter.eqDecibels(lane[.high].value(at: t, default: 0.5))
        high *= pow(10, (0.4 * mid + 0.15 * top) / 10)
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

extension TransitionShape {
    /// Whether both songs are clearly heard in bar `k`: drums, melody and
    /// voice (above 150 Hz; the low end has one owner by design), each
    /// within 8 dB of the two together.
    func together(_ k: Int, a: [StemKind: [Gains]], e: Int, b: [StemKind: [Gains]], c: Int) -> Bool {
        guard k >= first, k < last else { return false }
        var side: [Float] = [0, 0]
        for (i, (s, p, bar)) in [(DeckSide.a, a, e + k), (.b, b, c + k)].enumerated() {
            for (stem, levels) in p where bar >= 0 && bar < levels.count {
                side[i] += (gains[s]?[stem]?[k - first].high ?? 1) * levels[bar].high
            }
        }
        // Within 6 dB of each other: a little inside the 8 dB of the two
        // together that makes a part heard, so the plan holds up where
        // the level estimates are a dB or two off.
        return min(side[0], side[1]) >= 0.2 * (side[0] + side[1])
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
/// - **Something happens.** None of the above makes anyone look up. The
///   best spots give the blend a payoff: B's hook (its chorus or drop)
///   landing right on the switch, B singing over A's beat (a mashup), or a
///   real drop of B to build into.
enum AutoPlacement {
    /// A crowd stays with a song for its hooks, not for the verse and the
    /// breakdown between them. What it costs to keep A playing on its own
    /// from bar `from` to bar `to`: every bar under full power (a verse, a
    /// breakdown, the beat or bass gone) cools the floor, and past about a
    /// minute and a half on its own even a song at full power has said what
    /// it has to say. Too short, and the songs just flicker past.
    /// - Parameter skipping: bars left out by a jump (not played at all).
    static func pacing(_ s: TrackStructure, from: Int, to: Int, barSeconds: Double,
                       skipping: Range<Int>? = nil) -> Float {
        let bars = (max(0, from)..<max(max(0, from), to)).filter { !(skipping?.contains($0) ?? false) }
        let sag = bars.filter { s.sags($0) }.count
        let seconds = Float(Double(bars.count) * barSeconds)
        return 0.1 * Float(sag) + 0.02 * max(0, seconds - 90) + 0.02 * max(0, 30 - seconds)
    }

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

    /// dB A's drums and melody should give up (see `TransitionBuilder.room`)
    /// over bars `from..<to` so B is heard as well as A: everything of B
    /// above 150 Hz, as `shape` (written without room) lets it through,
    /// within 5 dB of everything of A there. A's voice isn't cut, so where
    /// it carries A that takes more off the rest. A DJ doesn't bury the
    /// new song 10 dB under the old one, nor push it over. Whole dB of
    /// EQ, at most 12 (about 6.5 dB off A's drums and melody; past that
    /// A's beat thins into a shadow of itself).
    static func room(_ shape: TransitionShape, a: [StemKind: [TransitionShape.Gains]], e: Int,
                     b: [StemKind: [TransitionShape.Gains]], c: Int, from: Int, to: Int) -> Double {
        guard to > from else { return 0 }
        var cuttable: Float = 0, kept: Float = 0, pb: Float = 0
        for k in max(from, shape.first)..<min(to, shape.last) {
            for (side, p, at) in [(DeckSide.a, a, e + k), (.b, b, c + k)] {
                for (stem, levels) in p where at >= 0 && at < levels.count {
                    let heard = (shape.gains[side]?[stem]?[k - shape.first].high ?? 1) * levels[at].high
                    if side == .b { pb += heard } else if stem == .drums || stem == .other { cuttable += heard } else { kept += heard }
                }
            }
        }
        // Nothing of B's there to make room for.
        guard cuttable > 0, pb > 1e-3 * (cuttable + kept) else { return 0 }
        let within: Float = pow(10, -5 / 10)
        // The EQ takes about 0.55 dB off a part per dB cut (see `TransitionShape`).
        return Double((0...12).first { r in pb >= within * (kept + cuttable * pow(10, -0.055 * Float(r))) } ?? 12)
    }

    /// Where the builder will open B's vocal (bars from B's entry), found
    /// from the per-beat levels the way `VocalPhrasing` finds it in the
    /// audio: the second beat of the pause nearest `target` (later first),
    /// else the strongest word attack in the window, else `target` itself.
    /// The blend is judged with the vocal where it will really come in.
    static func vocalEntry(_ s: TrackStructure, cue c: Int, target: Double, earliest: Double,
                           latest: Double) -> Double {
        guard let beats = s.vocalBeatLevel, let ref = s.vocalReference else { return target }
        func level(_ j: Int) -> Float { j >= 0 && j < beats.count ? beats[j] : -90 }
        func quiet(_ j: Int) -> Bool { level(j) < ref - 16 }
        let base = 4 * c
        let t = Int((target * 4).rounded()), lo = Int((earliest * 4).rounded(.up)), hi = Int((latest * 4).rounded(.down))
        guard hi >= lo else { return target }
        var step = 0
        while t - step >= lo || t + step <= hi {
            let later = t + step, earlier = t - step
            if later <= hi, later >= lo, quiet(base + later - 1), quiet(base + later) { return Double(later) / 4 }
            if step > 0, earlier >= lo, earlier <= hi, quiet(base + earlier - 1), quiet(base + earlier) {
                return Double(earlier) / 4
            }
            step += 1
        }
        var best: (beat: Int, rise: Float)?
        for j in lo...hi {
            let rise = level(base + j) - level(base + j - 1)
            if level(base + j) > ref - 10, rise >= 6, rise > best?.rise ?? 0 { best = (j, rise) }
        }
        return best.map { Double($0.beat) / 4 } ?? target
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
        /// B's vocal comes in early, over A's beat.
        var mashup = false
        /// The switch is worth building into: roll, silence, drop.
        var dropMoment = false
        /// What makes this transition more than a crossfade, in words.
        var payoff: [String] = []
        /// Bars the simulation expects both songs to be clearly heard in,
        /// and where it expects B's vocal to come in (bars from B's entry).
        var together: Int?
        var expectedVocalIn: Double?
    }

    /// - Parameters:
    ///   - trimA, trimB: the decks' level matches (dB), so energies compare
    ///     as heard.
    ///   - entryRange: bars of A the transition may start on (in a set: not
    ///     before A has had its time).
    ///   - keysClash: the melodies will be swapped rather than layered,
    ///     which changes what plays when.
    ///   - mashup: B's vocal may sing over A's beat from a quarter into the
    ///     blend (the keys fit and the tempos are close).
    ///   - soloFrom: A's bar from which it has the floor to itself (in a
    ///     set: once its own transition in is over). Given, the exit is
    ///     paced for a crowd; nil, it favours letting A play out.
    ///   - skip: bars of A a jump leaves out, if A plays that far: the
    ///     transition starts before them or well after.
    static func place(a: TrackAnalysis, b: TrackAnalysis, bars n: Int, preset: TransitionPreset,
                      trimA: Float = 0, trimB: Float = 0, entryRange: ClosedRange<Int>? = nil,
                      keysClash: Bool = false, mashup: Bool = false, soloFrom: Int? = nil,
                      skip: Range<Int>? = nil) -> Result {
        let barsA = a.grid.barCount(duration: a.duration)
        let barsB = b.grid.barCount(duration: b.duration)
        guard let sa = a.structure, let sb = b.structure, !sa.loudness.isEmpty, !sb.loudness.isEmpty else {
            return Result(entryBar: max(0, barsA - n - 8), cueBar: 0, vocalHandoff: n, reason: "")
        }
        let echo = preset == .echoOut
        // Bar (from B's entry) at which A's vocal is taken out and B's comes in.
        let swap = echo ? 0 : n / 2
        let vocalIn = echo ? 0 : n
        let mash = mashup && preset == .stemSwap && n >= 16 ? Int(TransitionBuilder.mashupWindow(bars: n).earliest) : nil
        let handoffs = (swap == vocalIn ? [vocalIn] : [vocalIn, swap]) + (mash.map { [$0] } ?? [])
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
        // A Wash Out's bridge starts its bars before the entry: A's own
        // time on its own comes before that, not under it.
        let bridge = echo ? min(n, 8) : 0
        let range = entryRange.map { min($0.lowerBound + bridge, latest)...max($0.upperBound, $0.lowerBound + bridge) }
            ?? min(latest, Int(Double(barsA) * 0.45))...latest
        // Past a jump, only once the eight bars before the transition (and
        // a Wash Out's own) are all played ones.
        let entries = stride(from: range.lowerBound, through: max(range.lowerBound, min(range.upperBound, latest)), by: 1)
            .filter { ((($0 - phaseA) % 4) + 4) % 4 == 0 }
            .filter { e in skip.map { e + span <= $0.lowerBound || e - bridge - 8 >= $0.upperBound } ?? true }
        // Skipping more than ~45 % of B throws away too much of it. Far
        // enough to reach the first chorus: a DJ mixes pop in on the hook.
        let lastCue = max(0, min(Int(Double(barsB) * 0.45), barsB - n - 8))
        let cues = (0...lastCue).filter { ((($0 - phaseB) % 4) + 4) % 4 == 0 }

        // Where the low end changes hands for an entry and a cue: the first
        // phrase from half-way where B's own kick and bass are really
        // there; if B is still building, A keeps it until B's drop at the
        // end. But if A's own low end leaves first (a breakdown starting
        // inside the blend), B's takes over right there, from the second
        // bar on (one to hear B's tops first), wherever it's ready: a DJ
        // doesn't leave the floor without a kick and bass for bars just
        // to swap them on a later downbeat.
        let step = max(1, n / 4)
        func lowSwap(entry e: Int, cue c: Int) -> Int? {
            guard !echo else { return nil }
            // A Drop Swap flips everything half-way, low end included.
            if preset == .dropSwap { return n / 2 }
            let ready = stride(from: n / 2, to: n, by: step).first { k in
                let r = (c + k)..<(c + k + 4)
                return sb.meanActivity(.bass, bars: r) > 0.5 && sb.meanActivity(.drums, bars: r) > 0.5
            } ?? n
            let aLeaves = (min(2, ready)..<ready).first { k in
                let a = (e + k)..<(e + k + 2), b = (c + k)..<(c + k + 2)
                return sa.meanActivity(.bass, bars: a) < 0.3 && sa.meanActivity(.drums, bars: a) < 0.3
                    && sb.meanActivity(.bass, bars: b) > 0.5 && sb.meanActivity(.drums, bars: b) > 0.5
            }
            return aLeaves ?? ready
        }
        /// Bar (from B's entry) where B takes over: its beat drops or the
        /// low end changes hands.
        func switchBar(_ sw: Int?) -> Int { echo ? 0 : preset == .dropSwap ? n / 2 : sw ?? n }

        /// Worth building into (roll, silence, drop) at bar `switchAt`: B's
        /// hook or a real lift of B there, with A's beat there to roll, and
        /// only if B really lands, its first two bars at full level (not a
        /// pickup or a break before the section proper: a roll and a
        /// silence into two quiet bars is an anticlimax). Decided with the
        /// spot, since A is gone at such a switch rather than lingering.
        func dropMoment(e: Int, c: Int, switchAt: Int) -> Bool {
            guard !echo, switchAt >= 4,
                  sa.meanActivity(.drums, bars: (e + switchAt - 2)..<(e + switchAt)) > 0.5,
                  min(sb.meanLoudness(bars: (c + switchAt)..<(c + switchAt + 1)),
                      sb.meanLoudness(bars: (c + switchAt + 1)..<(c + switchAt + 2))) >= sb.referenceLoudness - 3
            else { return false }
            let rise = sb.meanLoudness(bars: (c + switchAt)..<(c + switchAt + 8))
                - sb.meanLoudness(bars: (c + switchAt - 4)..<(c + switchAt))
            return preset == .dropSwap || sb.hook(c + switchAt) >= 0.4
                || (bound(boundB, c + switchAt) >= 0.5 && rise >= 3)
        }
        let powerA = AutoPlacement.powers(sa, trim: trimA), powerB = AutoPlacement.powers(sb, trim: trimB)
        /// Whether the melodies clash at this spot, heard in the notes both
        /// songs play where they'd overlap (as the builder will judge it on
        /// the audio), not only guessed from the two keys. Where they do,
        /// B's melody and voice wait for the swap, and the spot is judged
        /// as that: planned as a blend, it would play as A alone.
        let chromaA = sa.barChroma, chromaB = sb.barChroma
        func notesClash(e: Int, c: Int, sw: Int?) -> Bool {
            guard !echo, let chromaA, let chromaB else { return keysClash }
            let q = n / 4, s = preset == .dropSwap ? n / 2 : min(n, max(1, sw ?? n / 2))
            let until = min(max(s, q + 2), max(q + 2, n / 2)) + 2
            func sum(_ x: [[Float]], _ r: Range<Int>) -> [Float]? {
                let bars = r.clamped(to: 0..<x.count)
                guard !bars.isEmpty else { return nil }
                var out = [Float](repeating: 0, count: 12)
                for b in bars { for p in 0..<12 { out[p] += x[b][p] } }
                return out.contains { $0 > 0 } ? out : nil
            }
            guard let a = sum(chromaA, (e + q)..<(e + until)), let b = sum(chromaB, (c + q)..<(c + until))
            else { return keysClash }
            return !Harmony.fits(a, b, tolerance: keysClash ? Harmony.keysClashTolerance : Harmony.clashTolerance)
        }
        let pausesA = sa.vocalQuietBeats, pausesB = sb.vocalQuietBeats

        var best = (entry: entries.last ?? max(0, barsA - n), cue: cues.first ?? 0, handoff: vocalIn,
                    lowSwap: lowSwap(entry: entries.last ?? 0, cue: cues.first ?? 0), score: -Float.infinity)
        var bestHeard: Int?, bestVocal: Double?
        for e in entries.isEmpty ? [max(0, latest)] : entries {
            // A side: beat under the first half, energy before and during.
            let drumsA = min(1.2, sa.meanActivity(.drums, bars: e..<(e + max(1, span / 2))))
            // Before the transition: for a Wash Out, before its bars.
            let lead = echo ? min(n, 8) : 0
            let preA = sa.meanLoudness(bars: (e - lead - 8)..<(e - lead)) + trimA
            let duringA = sa.meanLoudness(bars: e..<(e + max(1, span / 2))) + trimA
            var scoreA: Float = echo ? 0 : drumsA
            // Leaving out of a breakdown starts the transition on a floor
            // that has already cooled.
            scoreA -= 0.2 * max(0, refA - preA - 2)
            scoreA -= 0.10 * max(0, preA - duringA - 3)
            scoreA += 0.6 * bound(boundA, e) + 0.3 * bound(boundA, e + span)
            if let soloFrom {
                scoreA -= pacing(sa, from: soloFrom, to: e - lead, barSeconds: a.grid.barSeconds,
                                 skipping: skip.flatMap { e >= $0.upperBound ? $0 : nil })
            } else {
                scoreA += 0.3 * Float(e) / Float(max(1, barsA))
            }
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
                score -= 0.4 * Float(c) / Float(max(1, barsB))
                let sw = lowSwap(entry: e, cue: c)
                let clashHere = notesClash(e: e, c: c, sw: sw)
                // The payoff: B's hook lands right as B takes over (a Wash
                // Out drops straight into it), or B has a real drop there.
                let switchAt = switchBar(sw)
                let drop = dropMoment(e: e, c: c, switchAt: switchAt)
                score += 1.2 * sb.hook(c + switchAt)
                if preset == .stemSwap {
                    let rise = sb.meanLoudness(bars: (c + switchAt)..<(c + switchAt + 8))
                        - sb.meanLoudness(bars: (c + switchAt - 4)..<(c + switchAt))
                    score += 0.5 * bound(boundB, c + switchAt) * min(1, max(0, (rise - 2) / 6))
                }
                if preset == .dropSwap {
                    // Worth it only onto a real drop: a new section of B at
                    // the switch that's clearly louder than B's bars before
                    // it, ideally as a section of A ends.
                    let h = n / 2
                    let rise = sb.meanLoudness(bars: (c + h)..<(c + h + 8)) - sb.meanLoudness(bars: c..<(c + h))
                    // A cut onto anything less than a real drop is just a
                    // hard cut: not a Drop Swap spot at all.
                    guard rise >= 4, bound(boundB, c + h) >= 0.5 else { continue }
                    score += 1.0 * bound(boundB, c + h) * min(1, max(0, (rise - 2) / 6))
                    score += 0.4 * bound(boundA, e + h)
                    score -= 0.6 * sa.meanActivity(.vocals, bars: (e + h - 1)..<(e + h + 1))
                }
                if let sw, sw < span {
                    // The real change happens at the swap: best on a new
                    // section of B and the end of one of A's.
                    score += 0.4 * bound(boundB, c + sw) + 0.3 * bound(boundA, e + sw)
                }
                // B's vocal may also come in right on the switch, so a hook
                // landing there isn't muted until the end of the blend.
                let options = sw.map { $0 > n / 2 && $0 < n && !handoffs.contains($0) ? handoffs + [$0] : handoffs } ?? handoffs
                for handoff in options {
                    // No mashup over notes that clash.
                    if clashHere && handoff == mash { continue }
                    var s = score + (handoff == vocalIn ? 0.15 : 0)
                    var heard: Int?
                    var heardVocal: Double?
                    if handoff == mash {
                        // B singing over A's beat is the moment, best with
                        // its hook.
                        s += 0.5 * min(1, sb.meanActivity(.vocals, bars: (c + handoff)..<(c + n / 2)))
                        s += 0.8 * sb.hook(c + handoff)
                    }
                    s -= 1.5 * sb.meanActivity(.vocals, bars: c..<(c + handoff))
                    s += 0.6 * sb.meanActivity(.vocals, bars: (c + handoff)..<(c + handoff + 4))
                    // The mix, bar by bar, as the automation will play it,
                    // through B's first two phrases on its own too: no hole
                    // in the middle, no pile-up either, and no lull right
                    // after the swap or B dropping into its breakdown as
                    // soon as it has the floor.
                    // The simulation below adds at most two (eight bars of
                    // both songs), and everything after it only takes
                    // away: a spot that can't beat the best even so isn't
                    // worth simulating.
                    if s + 2 <= best.score { continue }
                    if let powerA, let powerB {
                        // B's vocal where the builder will find its line.
                        // A mashup only happens if it works as it plays
                        // (grooves lock, B's voice sits on A's chords, a line
                        // starts clean in time); otherwise B's vocal comes
                        // in from half-way as usual. The spot has to work
                        // either way: a mashup is the bonus, not the blend.
                        // Likewise B's drums only layer under A's where the
                        // two grooves lock, which is measured on the audio
                        // later: the blend has to hold with B's melody,
                        // bass and voice alone too.
                        struct Plan { let vocalBar: Int, mashup: Bool, vin: Double, drumsLayer: Bool }
                        var plans: [Plan] = []
                        if !echo, handoff == mash {
                            let w = TransitionBuilder.mashupWindow(bars: n)
                            plans.append(Plan(vocalBar: handoff, mashup: true,
                                              vin: AutoPlacement.vocalEntry(sb, cue: c, target: w.earliest,
                                                                            earliest: w.earliest, latest: w.latest),
                                              drumsLayer: true))
                        }
                        let v = min(n, max(n / 2, handoff))
                        // Clashing keys: B's voice waits for the swap. So it
                        // does where the beats don't lock (the builder only
                        // lets it sing over A's beat where they do).
                        // Where B takes the low end before half-way, its voice
                        // may come in from there, on its own beat.
                        let early = min(n, sw ?? n) < n / 2 ? sw : nil
                        let swap = early ?? max(n / 2, min(n, sw ?? n))
                        // Aimed at the handoff while A sings there, else at
                        // B's next line from its floor (as the builder does).
                        func entry(from first: Int) -> Double {
                            let aim = sa.isActive(.vocals, bar: e + first) && first >= n / 2
                                ? min(max(v, first), max(first, min(n, sw ?? n))) : first
                            return echo ? 0 : AutoPlacement.vocalEntry(sb, cue: c, target: Double(aim),
                                                                       earliest: Double(first), latest: Double(max(v, first)) + 4)
                        }
                        let usual = entry(from: clashHere ? swap : early ?? n / 2)
                        plans.append(Plan(vocalBar: v, mashup: false, vin: usual, drumsLayer: true))
                        if preset == .stemSwap {
                            // First: usually the worst, so the rest can be
                            // skipped once the spot can't win.
                            plans.insert(Plan(vocalBar: v, mashup: false, vin: entry(from: swap), drumsLayer: false), at: 0)
                        }
                        heardVocal = (plans.first { $0.mashup } ?? plans[plans.count - 1]).vin
                        var worstPenalty: Float = 0, fewest = Int.max
                        let aim = min(8, n / 2 + 2)
                        for plan in plans {
                            func shape(room: Double) -> TransitionShape {
                                TransitionShape.cached(preset, bars: n, vocalBar: plan.vocalBar, keysClash: clashHere,
                                                       lowSwap: sw, mashup: plan.mashup, room: room, dropMoment: drop,
                                                       vocalIn: echo ? nil : plan.vin, drumsLayer: plan.drumsLayer)
                            }
                            let flat = shape(room: 0)
                            let room = preset == .stemSwap
                                ? AutoPlacement.room(flat, a: powerA, e: e, b: powerB, c: c, from: step,
                                                     to: max(step + 1, sw ?? n))
                                : 0
                            let shape = room == 0 ? flat : shape(room: room)
                            // The floor is A's energy: B landing in its own
                            // breakdown is as much a hole as a gap in the
                            // blend. Per bar, so short and long blends
                            // compete fairly. Measured from A at full power,
                            // not from whatever A played last: after a
                            // breakdown that would call a dead floor level.
                            let floor = max(preA, refA - 4) - 2.5, ceiling = max(preA, postB) + 2.5
                            let bars = shape.first..<(shape.last + 8)
                            var penalty: Float = 0
                            for k in bars {
                                let level = shape.mixLevel(k, a: powerA, e: e, b: powerB, c: c)
                                let hole = max(0, floor - level)
                                penalty += 0.1 * hole + 0.02 * hole * hole + 0.04 * max(0, level - ceiling)
                            }
                            worstPenalty = max(worstPenalty, penalty * 24 / Float(bars.count))
                            // A transition, not two songs in a row: both
                            // clearly heard for a while.
                            fewest = min(fewest, (shape.first..<shape.last).filter {
                                shape.together($0, a: powerA, e: e, b: powerB, c: c)
                            }.count)
                            // The worst plan so far already sinks it.
                            if s - worstPenalty + 0.25 * Float(min(fewest, aim)) - (echo ? 0 : 0.5 * Float(max(0, aim - fewest)))
                                <= best.score { break }
                        }
                        s -= worstPenalty
                        let both = fewest
                        s += 0.25 * Float(min(both, aim))
                        // Under six is two songs in a row, whatever else
                        // it has: a hook on the switch doesn't make up for
                        // it. Aim for eight in a long blend (the level
                        // estimates run a dB or two either way), fewer in a
                        // quick one: B's parts come in one at a time, and
                        // more than that is piling up, not blending.
                        if !echo && both < aim { s -= 0.5 * Float(aim - both) }
                        heard = both
                    }
                    guard !echo else {
                        // B's beat drops with its vocal open: not in the
                        // middle of a line. A's vocal should find a line end
                        // in the bridge's last bars.
                        if let pausesB, !(pausesB.isQuiet(4 * c - 1) || pausesB.isQuiet(4 * c)) { s -= 0.8 }
                        if let pausesA, !pausesA.hasPause(in: (4 * (e - 3))...(4 * e)) { s -= 0.3 }
                        if s > best.score { best = (e, c, handoff, sw, s); bestHeard = heard; bestVocal = heardVocal }
                        continue
                    }
                    // A's vocal leaves when B's arrives (where it will
                    // really come in) or B takes the low end, whichever is
                    // first; anything A sings later is cut.
                    let out = min(Int((heardVocal ?? Double(handoff)).rounded(.down)), sw ?? n)
                    s -= 1.5 * sa.meanActivity(.vocals, bars: (e + out)..<(e + max(out + 1, span)))
                    s -= 0.3 * sa.meanActivity(.vocals, bars: (e + out - 1)..<(e + out))
                    // Best between lines on both sides: a vocal singing
                    // through the handover gets cut in two.
                    func through(_ s: TrackStructure, _ bar: Int) -> Float {
                        min(s.meanActivity(.vocals, bars: (bar - 1)..<bar), s.meanActivity(.vocals, bars: bar..<(bar + 1)))
                    }
                    s -= 0.8 * through(sb, c + handoff) + 0.4 * through(sa, e + out)
                    // To the beat: a clean line start for B's vocal where the
                    // builder will look for one (half-way to four bars past
                    // the handoff), a line end for A's near its exit.
                    // Without one, B's voice has to fade in mid-sentence.
                    let window = handoff == mash ? (handoff, n / 2)
                        : clashHere ? (max(n / 2, min(n, sw ?? n)), max(min(n, max(n / 2, handoff)), min(n, sw ?? n)) + 4)
                        : (n / 2, min(n, max(n / 2, handoff)) + 4)
                    if let pausesB, !pausesB.hasPause(in: (4 * (c + window.0))...(4 * (c + window.1))) { s -= 0.8 }
                    if let pausesA, !pausesA.hasPause(in: (4 * (e + out - 4))...(4 * (e + out + 2))) { s -= 0.3 }
                    if s > best.score { best = (e, c, handoff, sw, s); bestHeard = heard; bestVocal = heardVocal }
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

        var payoff: [String] = []
        let switchAt = switchBar(best.lowSwap)
        if sb.hook(best.cue + switchAt) >= 0.4 { payoff.append(echo ? "drops into B's hook" : "B's hook on the switch") }
        let isMashup = handoff == mash
        if isMashup { payoff.append("mashup: B sings over A's beat") }
        let drops = dropMoment(e: best.entry, c: best.cue, switchAt: switchAt)
        if drops { payoff.append("roll into the drop") }
        notes.insert(contentsOf: payoff, at: 0)
        return Result(entryBar: best.entry, cueBar: best.cue, vocalHandoff: handoff, lowSwap: best.lowSwap,
                      reason: notes.joined(separator: " · "), score: best.score, mashup: isMashup,
                      dropMoment: drops, payoff: payoff, together: bestHeard, expectedVocalIn: bestVocal)
    }
}
