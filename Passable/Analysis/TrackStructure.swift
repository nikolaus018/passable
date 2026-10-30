import Accelerate

/// Bar-by-bar activity of each stem, which is most of what a DJ reads off a
/// track when choosing where to mix: where the drums come in, where the
/// vocal starts, where it finally stops.
struct TrackStructure: Codable, Equatable {
    /// Per stem, per bar: RMS relative to that stem's loud bars (≈0…1+).
    var activity: [String: [Float]]
    /// Level of the whole track per bar, in dB (RMS, full scale = 0).
    var loudness: [Float] = []
    /// How loud the track sounds when it's going: `referenceLoudness`
    /// measured K-weighted (ITU-R BS.1770), as the ear weighs it. Plain RMS
    /// is ruled by the sub-bass, so an 808 track read loud and was turned
    /// down under a bright pop one. Optional: measured on load when missing.
    var heardReference: Float?
    /// Per stem, per bar: level in dB, all of it and below 150 Hz. What a
    /// transition does to each stem (fades, filters, low kills) is judged
    /// from these before anything is rendered. Optional so structures
    /// measured before they existed still decode; the loader re-measures.
    var stemLevel: [String: [Float]]?
    var stemLowLevel: [String: [Float]]?
    /// How "below 150 Hz" was measured (see `measure`); structures
    /// measured another way are measured again on load.
    var lowSplit: Int?
    static let lowSplit = 2
    /// dB under the song's loud level that a stem's loud bars count as at
    /// the least, when its activity is measured (see `measure`); how
    /// activity was measured, so older structures are measured again.
    static let activityFloor: Float = -30
    static let activityCap: Float = 2
    var activityMeasure: Int?
    static let activityMeasure = 2
    /// The vocal's level per beat, in dB: where its lines start and stop,
    /// which bars are too coarse for. Optional like the above.
    var vocalBeatLevel: [Float]?
    /// The same per sixteenth: where its words start and stop. A line that
    /// ends on the "and" of four leaves no whole beat silent. Optional like
    /// the above.
    var vocalSixteenthLevel: [Float]?
    /// Per bar, the 12 pitch-class energies of the vocal alone, as measured:
    /// whether it sits on the other song's chords. Optional like the above.
    var vocalChroma: [[Float]]?
    /// Per bar, 0…1: how strongly a hook (the chorus, the drop: what the
    /// crowd waits for) starts there. Optional like the above.
    var hookStart: [Float]?
    /// Per bar, the 12 pitch-class energies of the melody and vocal: where
    /// the song repeats itself, for hooks and for jumps. Optional like the
    /// above.
    var barChroma: [[Float]]?
    /// Per bar, the 12 pitch-class energies of the melody and bass line, as
    /// measured (not scaled per bar): the notes that layer when two songs
    /// blend, so bars add up to what the builder hears in the audio.
    /// Optional like the above.
    var harmonyChroma: [[Float]]?
    /// The same of the melody alone: what sits on the other song's melody
    /// and bass line while its own bass line is still out.
    var melodyChroma: [[Float]]?
    /// The vocal's lines as sung (see `Lyrics`): empty if no words were
    /// heard in it; nil if it hasn't been listened to. `lyricsTried` is
    /// the languages that were on the Mac when it was (see
    /// `Lyrics.available`), so a song is heard again once its language
    /// arrives.
    var vocalLines: [VocalLine]?
    var lyricsTried: String?
    /// Those lines on the song's grid: the sixteenth (from its first
    /// downbeat) each starts on and has ended by, in the order they're
    /// sung; and per bar how much of what's sung there comes back
    /// elsewhere in the song (0…1: a chorus; -1: nothing sung).
    var lineStarts: [Int]?, lineEnds: [Int]?
    var lyricRepeat: [Float]?
    /// The same per sixteenth, for looking up quickly: 4 where a part of
    /// the vocal starts (`partStart`), 8 inside one (`midPart`), 16 where
    /// a sentence ends and 32 a clause at a comma (`clauseEnd`), 64 inside
    /// a sentence (`midSentence`).
    var lineMarks: [UInt8]?
    /// The words as sung, on the grid: start and end of each in turn, in
    /// sixteenths from the first downbeat (fractions kept). nil: no word
    /// times heard.
    var wordSpans: [Double]?
    /// How the marks were made: structures whose marks were made another
    /// way have their lines put on the grid again on load.
    var linesVersion: Int?
    static let linesVersion = 6

    /// How loud the track is when it's going: the level of its loud bars
    /// (80th percentile), which is what a DJ matches with the trim knob.
    /// Integrated loudness would be dragged down by intros and breakdowns.
    var referenceLoudness: Float {
        let bars = loudness.filter { $0 > -60 }.sorted()
        guard !bars.isEmpty else { return -14 }
        return bars[min(bars.count - 1, Int(Double(bars.count) * 0.8))]
    }

    func meanLoudness(bars: Range<Int>) -> Float {
        // (Bars wholly outside the song have no level.)
        let from = max(0, bars.lowerBound), to = min(loudness.count, bars.upperBound)
        guard from < to else { return -90 }
        let r = from..<to
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
        let from = max(0, bars.lowerBound), to = min(a.count, bars.upperBound)
        guard from < to else { return 0 }
        return a[from..<to].reduce(0, +) / Float(to - from)
    }

    /// `heardReference` of a song: the 80th percentile of its bars' level
    /// through the BS.1770 K-weighting (a +4 dB shelf above 1.7 kHz and a
    /// high-pass at 38 Hz), bars under -60 dB left out.
    static func heardReference(stems: [StemKind: StemAudio], grid: BeatGrid) -> Float {
        let sr = AudioIO.sampleRate
        let count = stems.values.map(\.count).min() ?? 0
        var shelf = Biquad(), pass = Biquad()
        shelf.set(.highShelf(frequency: 1681.97, gainDB: 4.0), sampleRate: sr)
        pass.set(.highPass(frequency: 38.135, q: 0.5003), sampleRate: sr)
        var levels: [Float] = []
        var bar = 0
        while true {
            let start = Int(grid.downbeat(bar) * sr), end = Int(grid.downbeat(bar + 1) * sr)
            guard end <= count, end > start else { break }
            bar += 1
            guard start >= 0 else { continue }
            let n = end - start
            var l = [Float](repeating: 0, count: n), r = l
            for stem in stems.values {
                vDSP_vadd(l, 1, stem.left.pointer + start, 1, &l, 1, vDSP_Length(n))
                vDSP_vadd(r, 1, stem.right.pointer + start, 1, &r, 1, vDSP_Length(n))
            }
            shelf.process(&l, &r, count: n)
            pass.process(&l, &r, count: n)
            var ml: Float = 0, mr: Float = 0
            vDSP_measqv(l, 1, &ml, vDSP_Length(n))
            vDSP_measqv(r, 1, &mr, vDSP_Length(n))
            levels.append(10 * log10(max((ml + mr) / 2, 1e-9)))
        }
        let loud = levels.filter { $0 > -60 }.sorted()
        guard !loud.isEmpty else { return -14 }
        return loud[min(loud.count - 1, Int(Double(loud.count) * 0.8))]
    }

    static func measure(stems: [StemKind: StemAudio], grid: BeatGrid) -> TrackStructure {
        let sr = AudioIO.sampleRate
        var activity: [String: [Float]] = [:]
        var rawActivity: [String: (bars: [Float], reference: Float)] = [:]
        var stemLevel: [String: [Float]] = [:], stemLowLevel: [String: [Float]] = [:]
        for (kind, stem) in stems {
            var bars: [Float] = [], levels: [Float] = [], lows: [Float] = []
            // "Below 150 Hz" is what a low kill takes away: the stem less
            // what the mixer's isolator leaves of it (see
            // `MixRenderer.updateFilters`), so a killed stem is judged by
            // exactly what's heard of it. (A gentle low-pass, as this
            // was, counted much of a kick's body above 150 Hz as "the
            // rest": drums with their lows killed were planned louder
            // than they play.)
            var isolator = [Biquad(), Biquad(), Biquad()]
            for (i, q) in [0.5176, 0.7071, 1.9319].enumerated() { isolator[i].set(.highPass(frequency: 150, q: q), sampleRate: sr) }
            var bar = 0
            while true {
                let start = Int(grid.downbeat(bar) * sr), end = Int(grid.downbeat(bar + 1) * sr)
                guard end <= stem.count else { break }
                // (A bar that starts before the file, where a grid nudged
                // earlier puts its first downbeat: nothing to read there.)
                guard start >= 0 else { bars.append(0); levels.append(-90); lows.append(-90); bar += 1; continue }
                let n = end - start
                var l: Float = 0, r: Float = 0
                vDSP_rmsqv(stem.left.pointer + start, 1, &l, vDSP_Length(n))
                vDSP_rmsqv(stem.right.pointer + start, 1, &r, vDSP_Length(n))
                bars.append((l + r) / 2)
                var ml: Float = 0, mr: Float = 0
                vDSP_measqv(stem.left.pointer + start, 1, &ml, vDSP_Length(n))
                vDSP_measqv(stem.right.pointer + start, 1, &mr, vDSP_Length(n))
                levels.append(10 * log10(max((ml + mr) / 2, 1e-9)))
                let total = (ml + mr) / 2
                var restL = Array(UnsafeBufferPointer(start: stem.left.pointer + start, count: n))
                var restR = Array(UnsafeBufferPointer(start: stem.right.pointer + start, count: n))
                for i in isolator.indices { isolator[i].process(&restL, &restR, count: n) }
                vDSP_measqv(restL, 1, &ml, vDSP_Length(n))
                vDSP_measqv(restR, 1, &mr, vDSP_Length(n))
                lows.append(10 * log10(max(total - (ml + mr) / 2, 1e-9)))
                bar += 1
            }
            stemLevel[kind.rawValue] = levels
            stemLowLevel[kind.rawValue] = lows
            // Normalise to the stem's own loud bars so a quiet-but-present
            // vocal still counts, and separation bleed (a few % of the loud
            // level) doesn't.
            let reference = bars.sorted().dropFirst(Int(Double(bars.count) * 0.9)).first ?? 0
            activity[kind.rawValue] = reference > 1e-5 ? bars.map { $0 / reference } : bars.map { _ in 0 }
            rawActivity[kind.rawValue] = (bars, reference)
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
        /// The vocal's level over every `1 / parts` of a beat.
        func vocalLevels(parts: Int) -> [Float] {
            guard let vocals = stems[.vocals] else { return [] }
            var out: [Float] = []
            let perBar = Double(4 * parts)
            var i = 0
            while true {
                let start = Int(grid.time(bars: Double(i) / perBar) * sr)
                let end = Int(grid.time(bars: Double(i + 1) / perBar) * sr)
                guard end <= vocals.count else { break }
                guard start >= 0 else { out.append(-90); i += 1; continue }
                var l: Float = 0, r: Float = 0
                vDSP_measqv(vocals.left.pointer + start, 1, &l, vDSP_Length(end - start))
                vDSP_measqv(vocals.right.pointer + start, 1, &r, vDSP_Length(end - start))
                out.append(10 * log10(max((l + r) / 2, 1e-9)))
                i += 1
            }
            return out
        }
        let vocalBeats = vocalLevels(parts: 1)
        // Harmony and melody per bar (the melody stems and the vocal, which
        // is what a chorus repeats), for finding the hooks.
        func chromaPerBar(_ parts: [StemAudio], normalised: Bool) -> [[Float]] {
            var chroma: [[Float]] = []
            var bar = 0
            while true {
                let start = Int(grid.downbeat(bar) * sr), end = Int(grid.downbeat(bar + 1) * sr)
                guard parts.allSatisfy({ end <= $0.count }) else { break }
                bar += 1
                guard start >= 0 else { chroma.append([Float](repeating: 0, count: 12)); continue }
                let n = end - start
                var mono = [Float](repeating: 0, count: n)
                for channel in parts.flatMap({ [$0.left, $0.right] }) {
                    vDSP_vadd(mono, 1, channel.pointer + start, 1, &mono, 1, vDSP_Length(n))
                }
                chroma.append(KeyDetector.computeChroma(samples: mono, sampleRate: sr, normalised: normalised).map(Float.init))
            }
            return chroma
        }
        let chroma = stems[.other].map { chromaPerBar([$0] + [stems[.vocals]].compactMap { $0 }, normalised: true) } ?? []
        // A stem that is hardly there (an instrumental's vocal stem: only
        // what the separation let through) has loud bars of next to
        // nothing, and against those one bar of a little more bleed read
        // as hundreds of times its "loud" level, which placement then took
        // for a voice or a bass line arriving. Its loud bars count as at
        // least `activityFloor` dB under the song's own.
        let loud = loudness.filter { $0 > -60 }.sorted()
        if !loud.isEmpty {
            let song = pow(10, loud[min(loud.count - 1, Int(Double(loud.count) * 0.8))] / 20)
            let floor = song * pow(10, Self.activityFloor / 20)
            for (kind, raw) in rawActivity {
                let reference = max(raw.reference, floor)
                // (And a stem that plays in only a few bars, its "loud"
                // level that of its silence, is at most twice as active as
                // loud.)
                activity[kind] = raw.bars.map { min(Self.activityCap, $0 / reference) }
            }
        }
        var structure = TrackStructure(activity: activity, loudness: loudness, stemLevel: stemLevel,
                                       stemLowLevel: stemLowLevel, lowSplit: Self.lowSplit, vocalBeatLevel: vocalBeats)
        structure.hookStart = hookStarts(chroma: chroma, structure: structure)
        structure.barChroma = chroma
        // What the builder judges a blend's notes on: melody and bass line.
        structure.harmonyChroma = stems[.other].map { chromaPerBar([$0] + [stems[.bass]].compactMap { $0 }, normalised: false) } ?? []
        structure.melodyChroma = stems[.other].map { chromaPerBar([$0], normalised: false) } ?? []
        structure.vocalSixteenthLevel = vocalLevels(parts: 4)
        structure.vocalChroma = stems[.vocals].map { chromaPerBar([$0], normalised: false) } ?? []
        structure.heardReference = heardReference(stems: stems, grid: grid)
        structure.activityMeasure = Self.activityMeasure
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
            let from = max(0, r.lowerBound), to = min(n, r.upperBound)
            return from < to ? power[from..<to].reduce(0, +) / Float(to - from) : 0
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
            let from = max(0, r.lowerBound), to = min(a.count, r.upperBound)
            return from < to ? a[from..<to].reduce(0, +) / Float(to - from) : 0
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

    /// 0…1: how strongly a hook starts on the phrase that starts on `bar`.
    /// (`hookStart` is measured eight bars at a time and peaks a bar or
    /// two into the hook as often as on its first; a hook that starts on
    /// the phrase's downbeat was then missed from the phrase's start.)
    func hook(from bar: Int) -> Float { (bar...(bar + 2)).map { hook($0) }.max() ?? 0 }

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

extension TrackStructure {
    /// Puts the song's lines on its grid (see `lineStarts`). Again
    /// whenever the grid changes.
    mutating func setLines(_ lines: [VocalLine]?, tried: String?, grid: BeatGrid) {
        vocalLines = lines
        lyricsTried = tried
        linesVersion = Self.linesVersion
        // (The words aren't used for the hooks: tried, lines that come
        // back counting as much as harmony that does, placement chased
        // hooks into worse handovers.)
        if let chroma = barChroma { hookStart = Self.hookStarts(chroma: chroma, structure: self) }
        guard let lines, !lines.isEmpty else {
            (lineStarts, lineEnds, lyricRepeat, lineMarks, wordSpans) = (lines == nil ? nil : [], lines == nil ? nil : [], nil, nil, nil)
            return
        }
        let times = lines.flatMap(\.wordTimes)
        wordSpans = times.isEmpty ? nil : times.map { grid.bars(at: $0) * Double(VocalPhrasing.slots) }
        // (Each stretch between two pauses of a line counts as one: see
        // `VocalLine.breaks`.)
        func slot(_ t: Double) -> Int { Int((grid.bars(at: t) * Double(VocalPhrasing.slots)).rounded()) }
        // The recogniser stretches a line's first word back over the
        // silence before it (and its last over the one after), and runs a
        // line on through a pause it hears as no full stop. The voice's
        // own level says where it really sounds: each stretch is trimmed
        // to that, and split where it falls silent for three sixteenths
        // or more.
        let level = vocalSixteenthLevel ?? [], reference = vocalReference
        func sounds(_ k: Int) -> Bool {
            guard let reference, k >= 0, k < level.count else { return true }
            return !VocalPhrasing.quiet(level[k], reference)
        }
        var starts: [Int] = [], ends: [Int] = []
        // (And for each, the line it's a stretch of, and whether it starts it.)
        var owner: [Int] = [], opens: [Bool] = []
        // (Where a stretch ends a clause: the sentence (true), or at a
        // comma (false). Ends of the others are breaths inside a clause.)
        var closes: [Int: Bool] = [:]
        for (i, line) in lines.enumerated() {
            let marks = [line.start] + line.breaks.filter { $0 > line.start && $0 < line.end } + [line.end]
            let first = starts.count
            func stretch(_ a: Int, _ b: Int) {
                starts.append(a)
                ends.append(b)
                owner.append(i)
                opens.append(starts.count - 1 == first)
            }
            for (from, to) in zip(marks, marks.dropFirst()) where slot(to) > slot(from) {
                defer { if starts.count > first { closes[starts.count - 1] = to == marks.last } }
                var k = slot(from), run: Int?
                let end = slot(to)
                var silent = 0
                while k < end {
                    if sounds(k) {
                        if run == nil { run = k }
                        silent = 0
                    } else if let r = run {
                        silent += 1
                        if silent == 3 {
                            stretch(r, k - 2)
                            run = nil
                        }
                    }
                    k += 1
                }
                if let r = run {
                    // (To where it last sounded: a trailing silence isn't sung.)
                    var e = end
                    while e > r + 1, !sounds(e - 1) { e -= 1 }
                    stretch(r, e)
                }
            }
        }
        (lineStarts, lineEnds) = (starts, ends)
        var marks = [UInt8](repeating: 0, count: VocalPhrasing.slots * (loudness.count + 1) + 2)
        lyricRepeat = (0..<loudness.count).map { g in
            let from = grid.downbeat(g), to = grid.downbeat(g + 1), bar = to - from
            var sung = 0.0, back = 0.0
            for line in lines {
                let overlap = min(to, line.end) - max(from, line.start)
                guard overlap > 0 else { continue }
                sung += overlap
                back += overlap * min(1, Double(line.repeats) / 2)
            }
            return sung > 0.1 * bar ? Float(back / sung) : -1
        }
        // The parts the voice sings (a verse, a chorus, a hook): it comes
        // back after a rest, or a new part starts under it, on the first
        // line of it: the words go from lines sung once to lines that come
        // back (a verse into its chorus) or the other way, or the music
        // turns a corner where the line starts. Inside one a singer goes
        // from line to line with hardly a breath, and the recogniser makes
        // a sentence of every bar or two: one that starts there is still
        // the middle of the verse, and a voice let in on it is heard
        // cutting in mid-sentence (Don't Stop The Music, a verse sung
        // through from bar 11 to 35, let in on bar 24).
        // (Line by line, not on four-bar phrases: where a song's phrases
        // are counted two bars off, its chorus was no part at all.)
        let n = VocalPhrasing.slots
        let boundary = boundaryStrength()
        let corners = Set(boundary.indices.filter { g in
            boundary[g] >= 0.5 && (max(0, g - 2)...min(boundary.count - 1, g + 2)).allSatisfy { boundary[$0] <= boundary[g] }
        })
        /// A line sung once (0), or one that comes back (1); nil: once more
        /// only, which says neither.
        func kind(_ i: Int) -> Int? { lines[i].repeats >= 2 ? 1 : lines[i].repeats == 0 ? 0 : nil }
        var parts: [(start: Int, end: Int)] = []
        var lastKind: Int?
        for j in starts.indices.sorted(by: { starts[$0] < starts[$1] }) {
            let (a, b, i) = (starts[j], ends[j], owner[j])
            // The words turn: this line is another kind than the last
            // known one, and so is the next (one line alone is no part).
            let k = kind(i)
            let words = opens[j] && k != nil && lastKind != nil && k != lastKind
                && (i + 1 < lines.count ? kind(i + 1) ?? k : k) == k
            if opens[j], let k { lastKind = k }
            // The music turns on the bar the line starts on (up to two
            // beats of pickup, or a beat late).
            let g = Int((Double(a + n / 2) / Double(n)).rounded(.down))
            let music = opens[j] && corners.contains(g) && a <= g * n + 4
            // (Once to a part: not again half a bar on.)
            let turns = (words || music) && (parts.last.map { $0.start < a - n / 2 } ?? true)
            if let last = parts.last, a - last.end < Self.partRest, !turns {
                parts[parts.count - 1].end = max(last.end, b)
            } else {
                if let last = parts.last { parts[parts.count - 1].end = min(last.end, a) }
                parts.append((a, b))
            }
        }
        func mark(_ k: Int, _ bit: UInt8) { if k >= 0 && k < marks.count { marks[k] |= bit } }
        for p in parts {
            // (On the sixteenth its first word starts: a sixteenth later
            // clips the word, one earlier has the last of the line before.)
            mark(p.start, 4)
            let from = max(0, p.start + 2), to = min(marks.count, p.end)
            if from < to { for k in from..<to { marks[k] |= 8 } }
        }
        // Where a voice can be taken out between the words: at the end of
        // a sentence, or of a clause at a comma; not on a breath in the
        // middle of one ("I gotta get my body | moving").
        for (j, sentence) in closes { mark(ends[j], sentence ? 16 : 32) }
        for i in lines.indices {
            let own = starts.indices.filter { owner[$0] == i }
            guard let a = own.map({ starts[$0] }).min(), let b = own.map({ ends[$0] }).max() else { continue }
            for k in (a + 2)..<max(a + 2, b - 1) { mark(k, 64) }
        }
        lineMarks = marks
    }

    /// Whether a voice taken out on sixteenth `slot` leaves between two
    /// clauses of its words: a sentence's end, or a comma's.
    func clauseEnd(at slot: Int) -> Bool {
        guard linesVersion == Self.linesVersion, let marks = lineMarks else { return false }
        return slot >= 0 && slot < marks.count && marks[slot] & (16 | 32) != 0
    }

    /// Whether sixteenth `slot` is in the middle of one of the recogniser's
    /// sentences (nil: the song's words weren't heard).
    func midSentence(at slot: Int) -> Bool? {
        guard linesVersion == Self.linesVersion, let starts = lineStarts, !starts.isEmpty, let marks = lineMarks else { return nil }
        return slot >= 0 && slot < marks.count && marks[slot] & 64 != 0
    }

    /// Sixteenths a word's heard start and end are trusted to: the
    /// recogniser's times are close, not exact (the audio then says where
    /// in a gap the voice is quietest).
    static let wordMargin = 0.3

    /// Whether a word is being sung at sixteenth `at` (a fraction of one
    /// is a moment inside it), by the recogniser's word times: well past
    /// its start and short of its end. nil: no word times heard.
    func inWord(at s: Double) -> Bool? {
        guard linesVersion == Self.linesVersion, let w = wordSpans, !w.isEmpty else { return nil }
        let m = Self.wordMargin
        return words(near: s).contains { w[2 * $0] + m < s && s < w[2 * $0 + 1] - m }
    }

    /// Whether a word starts or ends within half a sixteenth of `at`: a
    /// gap between two words as heard, where a voice may be cut.
    func wordEdge(at s: Double) -> Bool {
        guard linesVersion == Self.linesVersion, let w = wordSpans, !w.isEmpty else { return false }
        return words(near: s).contains { abs(w[2 * $0] - s) <= 0.5 || abs(w[2 * $0 + 1] - s) <= 0.5 }
    }

    /// The words that may be sung around sixteenth `s` (they're in order):
    /// the two that start last before it, and the one after.
    private func words(near s: Double) -> Range<Int> {
        guard let w = wordSpans else { return 0..<0 }
        var lo = 0, hi = w.count / 2
        while lo < hi {
            let mid = (lo + hi) / 2
            if w[2 * mid] <= s { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 2)..<min(w.count / 2, lo + 1)
    }

    /// Sixteenths the voice has to rest for, at the least, for what it
    /// sings next to be a new part of the song: two beats. (Between two
    /// lines of a verse a singer takes a breath; parts come every 16 bars
    /// or so at this, about a verse or a chorus.)
    static let partRest = 8

    /// Whether a part of the vocal starts on sixteenth `slot`: where a
    /// voice is let in (see `setLines`). False for a song whose words
    /// weren't heard.
    func partStart(at slot: Int) -> Bool {
        guard linesVersion == Self.linesVersion, let marks = lineMarks else { return false }
        return slot >= 0 && slot < marks.count && marks[slot] & 4 != 0
    }

    /// Whether sixteenth `slot` is in the middle of a part of the vocal: a
    /// voice let in there comes in mid-verse, whatever line starts there
    /// (nil: the song's words weren't heard).
    func midPart(at slot: Int) -> Bool? {
        guard linesVersion == Self.linesVersion, let starts = lineStarts, !starts.isEmpty, let marks = lineMarks else { return nil }
        return slot >= 0 && slot < marks.count && marks[slot] & 8 != 0
    }

    /// The song as it plays when its beat is looped: up to bar `entry` as
    /// it is; from there its drums, bass line and melody repeat the
    /// `bars` bars before it, for as long as anyone listens (through bar
    /// `through` at least), and its voice is gone. What a blend over the
    /// loop is judged on.
    /// - Parameter back: how many bars before `entry` the looped bars start
    ///   (`bars`: its last ones; more: the phrase before those, so a fill
    ///   that ends the part plays once, into the loop, and isn't repeated).
    func looped(from entry: Int, bars: Int, back: Int, through: Int) -> TrackStructure {
        guard bars > 0, back >= bars, entry >= back else { return self }
        let count = max(through + 1, loudness.count)
        func source(_ g: Int) -> Int { g < entry ? g : entry - back + (g - entry) % bars }
        /// `x` with `per` values to the bar, looped; `gone`: what a part
        /// that isn't looped reads from `entry` on.
        func loop<T>(_ x: [T], per: Int = 1, gone: T? = nil) -> [T] {
            guard !x.isEmpty else { return x }
            return (0..<(count * per)).map { i -> T in
                let g = i / per
                if g >= entry, let gone { return gone }
                return x[min(x.count - 1, source(g) * per + i % per)]
            }
        }
        var s = self
        let voice = StemKind.vocals.rawValue
        s.activity = activity.reduce(into: [:]) { $0[$1.key] = loop($1.value, gone: $1.key == voice ? 0 : nil) }
        s.stemLevel = stemLevel.map { $0.reduce(into: [:]) { $0[$1.key] = loop($1.value, gone: $1.key == voice ? -90 : nil) } }
        s.stemLowLevel = stemLowLevel.map { $0.reduce(into: [:]) { $0[$1.key] = loop($1.value, gone: $1.key == voice ? -90 : nil) } }
        s.vocalBeatLevel = vocalBeatLevel.map { loop($0, per: 4, gone: -90) }
        s.vocalSixteenthLevel = vocalSixteenthLevel.map { loop($0, per: 16, gone: -90) }
        let none = [Float](repeating: 0, count: 12)
        s.vocalChroma = vocalChroma.map { loop($0, gone: none) }
        s.hookStart = hookStart.map { loop($0, gone: 0) }
        s.barChroma = barChroma.map { loop($0) }
        s.harmonyChroma = harmonyChroma.map { loop($0) }
        s.melodyChroma = melodyChroma.map { loop($0) }
        // The level of what loops: the song there less its voice.
        s.loudness = loop(loudness)
        if let levels = s.stemLevel {
            for g in entry..<max(entry, s.loudness.count) {
                let power = levels.values.reduce(Float(0)) { $0 + (g < $1.count ? pow(10, $1[g] / 10) : 0) }
                s.loudness[g] = 10 * log10(max(power, 1e-9))
            }
        }
        return s
    }

    /// The song measured in another count of its bars (see `Metre`), on
    /// `grid` (its own, counted the same way): what a blend with a song at
    /// half or double its tempo is judged on, bar for bar.
    func counted(_ metre: Metre, grid: BeatGrid) -> TrackStructure {
        guard !metre.isOwn else { return self }
        /// `x` with `per` values to the bar: two joined to one, or each
        /// one as two.
        func regroup<T>(_ x: [T], per: Int = 1, _ join: (T, T) -> T, _ half: (T) -> T) -> [T] {
            guard metre.bars == 2 else { return x.flatMap { [half($0), half($0)] } }
            return stride(from: min(x.count, metre.first * per), to: x.count - 1, by: 2).map { join(x[$0], x[$0 + 1]) }
        }
        func level(_ x: [Float], per: Int = 1) -> [Float] {
            regroup(x, per: per, { 10 * log10(max((pow(10, $0 / 10) + pow(10, $1 / 10)) / 2, 1e-9)) }, { $0 })
        }
        // (Notes are summed over a bar as measured: twice the bar, twice
        // the sum.)
        func notes(_ x: [[Float]]) -> [[Float]] { regroup(x, { zip($0, $1).map(+) }, { $0.map { $0 / 2 } }) }
        var s = self
        s.activity = activity.mapValues { regroup($0, { (($0 * $0 + $1 * $1) / 2).squareRoot() }, { $0 }) }
        s.loudness = level(loudness)
        s.stemLevel = stemLevel.map { $0.mapValues { level($0) } }
        s.stemLowLevel = stemLowLevel.map { $0.mapValues { level($0) } }
        s.vocalBeatLevel = vocalBeatLevel.map { level($0, per: 4) }
        s.vocalSixteenthLevel = vocalSixteenthLevel.map { level($0, per: VocalPhrasing.slots) }
        s.vocalChroma = vocalChroma.map(notes)
        s.harmonyChroma = harmonyChroma.map(notes)
        s.melodyChroma = melodyChroma.map(notes)
        // The hooks stay where the song has them (found in its own bars),
        // and the lines are put on the new count.
        let hooks = hookStart.map { regroup($0, { max($0, $1) }, { $0 }) }
        s.barChroma = nil
        s.setLines(vocalLines, tried: lyricsTried, grid: grid)
        s.barChroma = barChroma.map {
            notes($0).map { bar in
                let top = bar.max() ?? 0
                return top > 0 ? bar.map { $0 / top } : bar
            }
        }
        s.hookStart = hooks
        return s
    }

    /// Whether the `bars` bars before bar `entry` make a bed to loop: the
    /// song at full power all through them, beat and bass line going.
    func loops(before entry: Int, bars: Int) -> Bool {
        entry >= bars && ((entry - bars)..<entry).allSatisfy { !sags($0) }
    }
}

/// Where a vocal is silent, beat by beat: where
/// its lines can be let in or taken out cleanly.
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
         drumsLayer: Bool = true, drumsLinger: Bool = true, room: Double = 0, dropMoment: Bool = false,
         vocalIn: Double? = nil, vocalOut: Double? = nil, carry: Bool = false, under: Double = 0) {
        self.init(lanes: TransitionBuilder.build(preset, lanes: Lane.allLanes(), start: 0, barSeconds: 1, bars: n,
                                                 vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap,
                                                 drumsLayer: drumsLayer, drumsLinger: drumsLinger, vocalIn: vocalIn,
                                                 vocalOut: vocalOut, mashup: mashup,
                                                 dropMoment: dropMoment, room: room, carry: carry, under: under),
                  preset: preset, bars: n)
    }

    private struct Key: Hashable {
        let preset: TransitionPreset, bars: Int, vocalBar: Int?, keysClash: Bool, lowSwap: Int?, mashup: Bool
        let room: Double, dropMoment: Bool, vocalIn: Double?, drumsLayer: Bool, drumsLinger: Bool, vocalOut: Double?
        let carry: Bool, under: Double
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
                       drumsLayer: Bool = true, drumsLinger: Bool = true, vocalOut: Double? = nil,
                       carry: Bool = false, under: Double = 0) -> TransitionShape {
        let key = Key(preset: preset, bars: n, vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap, mashup: mashup,
                      room: room, dropMoment: dropMoment, vocalIn: vocalIn, drumsLayer: drumsLayer,
                      drumsLinger: drumsLinger, vocalOut: vocalOut, carry: carry, under: under)
        cache.lock.lock()
        if let shape = cache.shapes[key] { cache.lock.unlock(); return shape }
        cache.lock.unlock()
        let shape = TransitionShape(preset, bars: n, vocalBar: vocalBar, keysClash: keysClash, lowSwap: lowSwap,
                                    mashup: mashup, drumsLayer: drumsLayer, drumsLinger: drumsLinger, room: room,
                                    dropMoment: dropMoment, vocalIn: vocalIn, vocalOut: vocalOut, carry: carry, under: under)
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
        // As the mixer plays it: a kill is an isolator, which leaves
        // exactly what the song's levels call "the rest" (see
        // `TrackStructure.measure`); a lesser cut or a boost is a shelf
        // under 150 Hz.
        let lowDB = LaneParameter.eqDecibels(lane[.low].value(at: t, default: 0.5))
        if lowDB <= MixRenderer.killDB {
            low *= 1e-4
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
    /// Whether three or more of the four tonal parts (each song's melody
    /// and voice) are clearly heard in bar `k`, each within 10 dB of all
    /// that plays above 150 Hz: too much at once (as SetLab measures it).
    func busy(_ k: Int, a: [StemKind: [Gains]], e: Int, b: [StemKind: [Gains]], c: Int) -> Bool {
        guard k >= first, k < last else { return false }
        var total: Float = 0, parts: [Float] = []
        for (s, p, bar) in [(DeckSide.a, a, e + k), (.b, b, c + k)] {
            for (stem, levels) in p where bar >= 0 && bar < levels.count {
                let heard = (gains[s]?[stem]?[k - first].high ?? 1) * levels[bar].high
                total += heard
                if stem == .other || stem == .vocals { parts.append(heard) }
            }
        }
        return parts.filter { $0 > 0.1 * total }.count >= 3
    }

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
    /// minute on its own (two with the blends either side, what a club DJ
    /// gives a record) even a song at full power has said what it has to
    /// say. Under three quarters of a minute, the songs just flicker past.
    /// - Parameter skipping: bars left out by a jump (not played at all).
    static func pacing(_ s: TrackStructure, from: Int, to: Int, barSeconds: Double,
                       skipping: Range<Int>? = nil) -> Float {
        let bars = (max(0, from)..<max(max(0, from), to)).filter { !(skipping?.contains($0) ?? false) }
        let sag = bars.filter { s.sags($0) }.count
        let seconds = Float(Double(bars.count) * barSeconds)
        return 0.1 * Float(sag) + 0.03 * max(0, seconds - 60) + 0.03 * max(0, 45 - seconds)
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
        // Where not even the most EQ brings B within reach (its intro is
        // too quiet under A), A isn't thinned at all: that only opened a
        // hole of 3 to 5 dB with nothing of B's to fill it.
        // (And no more than 8 dB of EQ: 12 took 6 dB off A's beat and
        // melody for bars on end, and the floor sagged 3 to 5 dB under a
        // B that was still 7 dB under it.)
        return Double((0...8).first { r in pb >= within * (kept + cuttable * pow(10, -0.055 * Float(r))) } ?? 0)
    }

    /// What a voice handed over on the edge of a part is worth to a spot
    /// (each voice, for a certain edge): as much as a hook on the switch
    /// and more.
    static let partWeight: Float = 2.2

    /// Bars before a cut's downbeat B's voice may come in on a pickup: a
    /// beat, in the half-beat gap and A's last echo.
    static let pickup = 0.25

    /// Where A's voice leaves, given where B's will really be singing (or
    /// B takes over): at the end of the phrase A is in, if that's no more
    /// than two bars before. A singer who starts the next phrase only to
    /// be cut a bar and a half into it sounds cut off; two bars of the two
    /// beats alone between one voice and the next sound like a handover.
    /// (Bars from the transition's start, which is a phrase start of A's.)
    static func phraseEnd(before target: Double) -> Double {
        let end = (target / 4).rounded(.down) * 4
        return end > 0 && target - end <= 2 ? end : target
    }

    /// The bar (from the transition's start) whose downbeat a voice leaving
    /// at `bar` leaves on: the one it's in the last three beats before, or
    /// just past.
    static func partBar(leaving bar: Double) -> Int { Int((bar + 0.75).rounded(.down)) }

    /// What it costs a spot that a voice has to be let in (`in`) or taken
    /// out (`out`) there on something less than a breath between lines:
    /// between two words a little, through a word (no cut to be found: it's
    /// cut on the downbeat) more. A DJ picks the moment the singer isn't
    /// singing.
    static func cutCost(in entry: VocalPhrasing.Cut?, out exit: VocalPhrasing.Cut?) -> Float {
        func cost(_ cut: VocalPhrasing.Cut?, word: Float, none: Float) -> Float {
            switch cut {
            case .line?: return 0
            case .word?: return word
            case nil: return none
            }
        }
        return cost(entry, word: 0.3, none: 1.0) + cost(exit, word: 0.4, none: 1.2)
    }

    /// A song's phrases, bar by bar: `edge` (0…1) is how much of a part of
    /// the song ends and another begins on the bar's downbeat, which is
    /// where a DJ hands a vocal over (the end of a chorus, the start of a
    /// verse, not between two lines of one); `starts` is whether a
    /// four-bar phrase starts there at all.
    ///
    /// Phrases are counted from where the song turns its corners (parts
    /// come or go, the level jumps: the peaks of `boundary`), eight bars at
    /// a time: the 32 beats a DJ counts. (Where the voice itself stops or
    /// starts is a bar early or late as often as not: lines begin with a
    /// pickup.) A clear corner on a phrase start is certainly a part's
    /// edge, the eight-bar marks between them very likely, four bars off
    /// those the middle of a phrase. Counted from the song's first bar instead, every phrase
    /// after a two-bar intro or a four-bar tag is taken for one that
    /// starts in the middle of a line. A vocal stem (doubles, ad-libs,
    /// reverb) rarely falls silent between a verse and a chorus, and the
    /// two share their notes, so neither silence nor melody finds these.
    static func phrases(_ s: TrackStructure, boundary: [Float]) -> (edge: [Float], starts: [Bool]) {
        let count = s.loudness.count
        let corners = boundary.indices.filter { g in
            g < count && boundary[g] >= 0.3
                && (max(0, g - 2)...min(boundary.count - 1, g + 2)).allSatisfy { boundary[$0] <= boundary[g] }
        }
        guard !corners.isEmpty else {
            // Nothing to count from: the phase most sections start on
            // (and, as below, no edge in the middle of a phrase).
            let phase = s.phrasePhase()
            let starts = (0..<count).map { (($0 - phase) % 4 + 4) % 4 == 0 }
            let edge: [Float] = (0..<count).map { !starts[$0] ? 0 : (($0 - phase) % 8 + 8) % 8 == 0 ? 0.7 : 0.2 }
            return (lyricEdges(s, edge: edge, starts: starts), starts)
        }
        var edge = [Float](repeating: 0, count: count), starts = [Bool](repeating: false, count: count)
        for g in 0..<count {
            // Which bars phrases start on around here: where the corners
            // nearby fall, the strong and the near ones counting most. One
            // corner found a bar off (they're peaks of a change measured
            // over four bars either side) doesn't move the count; a real
            // two-bar tag, with the corners after it, does.
            var four = [Float](repeating: 0, count: 4), eight = [Float](repeating: 0, count: 8)
            for c in corners {
                let weight = boundary[c] * exp(-Float(abs(c - g)) / 24)
                four[c % 4] += weight
                eight[c % 8] += weight
            }
            let p4 = four.indices.max { four[$0] < four[$1] }!
            let p8 = eight[p4] >= eight[p4 + 4] ? p4 : p4 + 4
            starts[g] = g % 4 == p4
            let turns = g < boundary.count && boundary[g] >= 0.5 && corners.contains(g)
            edge[g] = g % 4 != p4 ? 0 : turns ? 1 : g % 8 == p8 ? 0.7 : 0.2
        }
        return (lyricEdges(s, edge: edge, starts: starts), starts)
    }

    /// `edge` with what the words say (see `Lyrics`), where they were
    /// heard. What's playing can change in the middle of a sentence, and a
    /// part of a song can end with nothing changing under the voice at
    /// all; the lines themselves know better:
    /// - a line sung through a phrase's downbeat (more than a pickup
    ///   before it, more than a word after) makes it no edge at all: a
    ///   voice handed over there is cut mid-sentence;
    /// - the voice starting after bars of silence, or stopping for bars,
    ///   is the edge of a part;
    /// - so is the song going from lines it comes back to (a chorus) to
    ///   lines it sings once (a verse), or the other way.
    private static func lyricEdges(_ s: TrackStructure, edge: [Float], starts: [Bool]) -> [Float] {
        guard let lineStarts = s.lineStarts, let lineEnds = s.lineEnds, !lineStarts.isEmpty,
              lineStarts.count == lineEnds.count else { return edge }
        let slots = VocalPhrasing.slots
        var edge = edge
        func repeats(_ bars: Range<Int>) -> Float? {
            let sung = bars.clamped(to: 0..<(s.lyricRepeat?.count ?? 0)).compactMap { g in
                s.lyricRepeat.flatMap { $0[g] >= 0 ? $0[g] : nil }
            }
            return sung.count >= 2 ? sung.reduce(0, +) / Float(sung.count) : nil
        }
        for g in edge.indices where starts[g] {
            let one = slots * g
            let lines = lineStarts.indices
            // More than two beats of it before the one (a pickup is
            // shorter), more than a beat after.
            if lines.contains(where: { lineStarts[$0] < one - 8 && lineEnds[$0] > one + 4 }) {
                edge[g] = min(edge[g], 0.1)
                continue
            }
            func sung(_ range: Range<Int>) -> Bool { lines.contains { lineStarts[$0] < range.upperBound && lineEnds[$0] > range.lowerBound } }
            let begins = !sung((one - 2 * slots)..<(one - 8)) && lines.contains { lineStarts[$0] >= one - 8 && lineStarts[$0] < one + slots }
            let stops = !sung((one + 4)..<(one + 2 * slots)) && lines.contains { lineEnds[$0] > one - slots && lineEnds[$0] <= one + 4 }
            if begins || stops {
                edge[g] = max(edge[g], 0.9)
            } else if let before = repeats((g - 4)..<g), let after = repeats(g..<(g + 4)), abs(after - before) >= 0.5 {
                edge[g] = 1
            }
        }
        return edge
    }

    /// The notes a song's voice sings over `bars`, per pitch class; nil if
    /// it has none there (or was measured before they were kept).
    static func vocalNotes(_ s: TrackStructure, bars: Range<Int>) -> [Float]? {
        guard let chroma = s.vocalChroma, let levels = s.stemLevel?[StemKind.vocals.rawValue] else { return nil }
        let r = bars.clamped(to: 0..<min(chroma.count, levels.count))
        guard !r.isEmpty else { return nil }
        let power = r.reduce(Float(0)) { $0 + pow(10, levels[$1] / 10) } / Float(r.count)
        guard 10 * log10(max(power, 1e-12)) > Harmony.heardFloor else { return nil }
        var out = [Float](repeating: 0, count: 12)
        for b in r { for p in 0..<12 { out[p] += chroma[b][p] } }
        return out.contains(where: { $0 > 0 }) ? out : nil
    }

    /// dB B's melody has to come down by to play under A's voice over
    /// bars `from..<to` of the blend (see `TransitionBuilder.under`): to
    /// 6 dB below the voice where A sings there, by 10 at most; whole dB.
    /// A lead vocal sits about that far over what accompanies it in its
    /// own song. 0 where A has no voice to speak of there.
    static func under(a: [StemKind: [TransitionShape.Gains]], e: Int, b: [StemKind: [TransitionShape.Gains]], c: Int,
                      from: Int, to: Int) -> Double {
        guard to > from, let voice = a[.vocals], let melody = b[.other] else { return 0 }
        func level(_ levels: [TransitionShape.Gains], _ first: Int) -> Float {
            let bars = ((first + from)..<(first + to)).clamped(to: 0..<levels.count)
            guard !bars.isEmpty else { return -120 }
            return 10 * log10(max(bars.reduce(Float(0)) { $0 + levels[$1].low + levels[$1].high } / Float(bars.count), 1e-12))
        }
        let sung = level(voice, e), played = level(melody, c)
        guard sung > -40 else { return 0 }
        return Double(min(10, max(0, (played - (sung - 6)).rounded())))
    }

    /// What looping A's beat costs a spot. A loop makes a blend where the
    /// song offers none (its voice done with a part, its beat held as a
    /// bed for the next song, as a DJ loops the last bars of a chorus), but
    /// it's the DJ's doing, not the record's: where A's own bars carry the
    /// blend as well, they play.
    static let loopCost: Float = 0.6

    /// How far before the loop starts A's voice may leave, and how far
    /// into it (bars): on the last word of the part that ends there.
    static let loopExit = (before: 0.75, after: 0.25)

    /// Bars B's voice may wait for a clean line past the bar it's due on
    /// (where A's leaves) where its words weren't heard: longer, and nobody
    /// sings for bars on end. It then comes in on the bar, eased in if it's
    /// mid-line. (Heard, it waits for the start of a part: `entryLatest`.)
    static let vocalWait = 2.0

    /// How long B's voice may wait to come in (bars from B's entry), due
    /// at `aim` in a blend of `bars`. Where its words were heard, for the
    /// start of a part to the blend's end: a few bars of the two beats
    /// alone are a handover, a singer cutting in mid-verse isn't. (Where
    /// waiting leaves bars with nobody singing, placement prices them and
    /// finds a spot where B's part starts as A's ends.)
    static func entryLatest(_ s: TrackStructure?, aim: Double, bars: Int) -> Double {
        s?.midPart(at: 0) != nil ? max(aim + vocalWait, Double(bars)) : aim + vocalWait
    }

    /// Bars before the bar it's due to leave on that A's voice may leave
    /// instead, at the end of a sentence (or a comma's clause): a beat or
    /// two alone between two singers is a handover, a sentence cut off on
    /// a breath isn't.
    static let exitBack = 2.0

    /// What it costs a spot that B's voice comes in in the middle of a
    /// part of it (see `TrackStructure.midPart`), on top of the part's edge
    /// it doesn't get: more than waiting a few bars for the next part.
    static let midPartCost: Float = 2.0

    /// Where the builder will cut a vocal in or out (bars from the
    /// transition's start, with the song at its bar `bar0` there), found
    /// from the per-sixteenth levels the way `VocalPhrasing.cut` finds it
    /// in the audio: the breath or the gap between words nearest `target`.
    /// No kind: it sings straight through, and is faded at `target`. The
    /// blend is judged with the vocals where they'll really come and go.
    static func vocalCut(_ s: TrackStructure, at bar0: Int, opening: Bool, target: Double, earliest: Double,
                         latest: Double) -> (bar: Double, kind: VocalPhrasing.Cut?) {
        // An instrumental has nothing to cut in two.
        guard let reference = s.vocalReference, s.vocalSixteenthLevel ?? s.vocalBeatLevel != nil else { return (target, .line) }
        let slots = Double(VocalPhrasing.slots), base = VocalPhrasing.slots * bar0
        let t = Int((target * slots).rounded()), past = target * slots - Double(t)
        /// (From the beats, each counted four times, for structures
        /// measured before per-sixteenth levels existed.)
        func level(_ j: Int) -> Float {
            if let fine = s.vocalSixteenthLevel { return j >= 0 && j < fine.count ? fine[j] : -90 }
            let beats = s.vocalBeatLevel ?? [], i = j >= 0 ? j / 4 : -1
            return i >= 0 && i < beats.count ? beats[i] : -90
        }
        // (Let in: on the start of a part; taken out: between clauses, as
        // the builder does.)
        let found = VocalPhrasing.cut(opening: opening, from: Int((earliest * slots).rounded(.up)) - t,
                                      through: Int((latest * slots).rounded(.down)) - t, reference: reference,
                                      turns: { opening ? s.partStart(at: base + t + $0) : s.clauseEnd(at: base + t + $0) },
                                      inside: { (opening ? s.midPart(at: base + t + $0) : s.midSentence(at: base + t + $0)) ?? false },
                                      sung: { s.inWord(at: Double(base + t + $0) + past) ?? false },
                                      between: { s.wordEdge(at: Double(base + t + $0) + past) }) {
            level(base + t + $0)
        }
        return found.map { (Double(t + $0.slot) / slots, $0.kind) } ?? (target, nil)
    }

    /// Where the builder will open B's vocal (bars from B's entry).
    static func vocalEntry(_ s: TrackStructure, cue c: Int, target: Double, earliest: Double,
                           latest: Double) -> Double {
        vocalCut(s, at: c, opening: true, target: target, earliest: earliest, latest: latest).bar
    }

    /// Where B's voice really sings from once its channel opens at bar
    /// `opening` (which may be the pause before a line), as the builder
    /// hears it in the audio: looked for up to bar `limit`.
    static func vocalSounds(_ s: TrackStructure, cue c: Int, from opening: Double, limit: Double) -> Double {
        guard let beats = s.vocalBeatLevel, let ref = s.vocalReference else { return opening }
        var j = Int((opening * 4).rounded(.up))
        while Double(j) / 4 < limit {
            let i = 4 * c + j
            if i >= 0, i < beats.count, beats[i] >= ref - 16 { break }
            j += 1
        }
        return max(opening, Double(j) / 4)
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
        /// The melodies clash at this spot (heard in the notes that overlap
        /// there, see `overlapClash`), so they swap rather than layer.
        var notesClash: Bool?
        /// The blend doesn't fit into what's left of A's music once A is
        /// back at its own tempo: it runs past the end of it.
        var overruns = false
        /// The jump offered was kept as an option (false: it left A no
        /// phrase to go out on, and A plays straight through).
        var jumps = true
        /// A's melody makes way before B's comes in, so A's beat (and
        /// voice) carry B's parts: see `TransitionBuilder.carry`.
        var carry = false
        /// A's beat loops under the blend: bars to the loop (0: A plays
        /// on as its song goes), and how many bars before the entry they
        /// start (see `TransitionBuilder.loop`).
        var loopBars = 0, loopBack = 0
    }

    /// Bars (from B's entry) in which the two melodies are heard together,
    /// in two parts, since what's under them changes hands in between:
    /// before the switch B's melody (in from a quarter in) sits on A's
    /// melody and bass line; from the switch, A's melody (until it has
    /// dissolved) sits on B's melody and bass line. The builder judges the
    /// audio over the same stretches.
    static func melodyOverlap(_ preset: TransitionPreset, bars n: Int,
                              lowSwap: Int?) -> (before: Range<Int>, after: Range<Int>) {
        let sw = TransitionBuilder.switchBar(preset, bars: n, lowSwap: lowSwap)
        let q = n / 4, until = max(q + 1, Int(TransitionBuilder.melodyDissolve(preset, bars: n, switchAt: sw)) + 2)
        let split = min(max(q, Int(sw)), until)
        return (q..<split, split..<until)
    }

    /// The notes a song plays over `bars`, per pitch class: its melody and
    /// bass line, or its melody alone; nil if there are none (or it was
    /// measured before per-bar notes existed).
    static func notes(_ s: TrackStructure, bars: Range<Int>, shift: Int = 0, melodyOnly: Bool = false) -> [Float]? {
        guard let chroma = (melodyOnly ? s.melodyChroma : nil) ?? s.harmonyChroma ?? s.barChroma else { return nil }
        let r = bars.clamped(to: 0..<chroma.count)
        guard !r.isEmpty else { return nil }
        // Only parts that are really there (as the builder hears it, see
        // `Harmony.heardFloor`): bleed has pitch classes too.
        if let levels = s.stemLevel {
            var power: Float = 0
            for stem in melodyOnly ? [StemKind.other] : [.other, .bass] {
                guard let l = levels[stem.rawValue] else { continue }
                for b in r where b < l.count { power += pow(10, l[b] / 10) }
            }
            guard 10 * log10(max(power / Float(r.count), 1e-12)) > Harmony.heardFloor else { return nil }
        }
        var out = [Float](repeating: 0, count: 12)
        for b in r { for p in 0..<12 { out[p] += chroma[b][p] } }
        guard out.contains(where: { $0 > 0 }) else { return nil }
        return shift == 0 ? out : Harmony.transposed(out, by: shift)
    }

    /// How badly the two songs' notes clash where their melodies overlap
    /// (see `Harmony.clash`), with A entering its bar `e` and B cued at
    /// `c`, each as it's heard (pitched by its shift): the worse of the two
    /// stretches of `melodyOverlap`, each judged on what plays in it (a
    /// bass line that's still out doesn't vouch for its melody). nil if
    /// there are no notes to compare.
    /// - Parameter measure: `Harmony.clash` (how far the two are from one
    ///   scale) or `Harmony.roughness` (how many of their notes grate).
    static func overlapClash(a: TrackStructure, aShift: Int = 0, entry e: Int, b: TrackStructure, bShift: Int = 0,
                             cue c: Int, preset: TransitionPreset, bars n: Int, lowSwap: Int?,
                             measure: ([Float], [Float]) -> Float = Harmony.clash) -> Float? {
        let overlap = melodyOverlap(preset, bars: n, lowSwap: lowSwap)
        func clash(_ bars: Range<Int>, lowEndIsAs: Bool) -> Float? {
            guard !bars.isEmpty,
                  let na = notes(a, bars: (e + bars.lowerBound)..<(e + bars.upperBound), shift: aShift, melodyOnly: !lowEndIsAs),
                  let nb = notes(b, bars: (c + bars.lowerBound)..<(c + bars.upperBound), shift: bShift, melodyOnly: lowEndIsAs)
            else { return nil }
            return measure(na, nb)
        }
        return [clash(overlap.before, lowEndIsAs: true), clash(overlap.after, lowEndIsAs: false)].compactMap { $0 }.max()
    }

    /// - Parameters:
    ///   - trimA, trimB: the decks' level matches (dB), so energies compare
    ///     as heard.
    ///   - entryRange: bars of A the transition may start on (in a set: not
    ///     before A has had its time).
    ///   - keysClash: the melodies will be swapped rather than layered,
    ///     which changes what plays when.
    ///   - clashAbove: how badly the notes that overlap at a spot may
    ///     clash before they're swapped there (`Harmony.tolerance` of the
    ///     two keys; nil: from `keysClash`).
    ///   - mashup: B's vocal may sing over A's beat from a quarter into the
    ///     blend (the keys fit and the tempos are close).
    ///   - soloFrom: A's bar from which it has the floor to itself (in a
    ///     set: once its own transition in is over). Given, the exit is
    ///     paced for a crowd; nil, it favours letting A play out.
    ///   - skip: bars of A a jump leaves out, if A plays that far: the
    ///     transition starts before them or well after.
    ///   - aShift, bShift: semitones each song plays pitched by, so their
    ///     notes are compared as they're heard.
    ///   - drumsLock: the two grooves are known to lock, so B's drums will
    ///     build in under A's: spots aren't also judged without that.
    ///   - drumsLinger: and A's then play on under B's after the swap
    ///     (known only with `drumsLock`; otherwise the worst case covers it).
    ///   - spot: the entry and cue are given (chosen by hand): only what
    ///     happens there is worked out.
    ///   - glide: bars B takes to glide back to its own tempo after the
    ///     blend, which come out of its time before the next one.
    ///   - runUp: bars A takes to glide to the blend's tempo before it:
    ///     it has to be back at its own before it sets off again.
    static func place(a: TrackAnalysis, b: TrackAnalysis, bars n: Int, preset: TransitionPreset,
                      trimA: Float = 0, trimB: Float = 0, entryRange: ClosedRange<Int>? = nil,
                      keysClash: Bool = false, clashAbove: Float? = nil, mashup: Bool = false, soloFrom: Int? = nil,
                      skip: Range<Int>? = nil, aShift: Int = 0, bShift: Int = 0, drumsLock: Bool = false,
                      drumsLinger: Bool = true, at spot: (entry: Int, cue: Int)? = nil, glide: Int = 0,
                      runUp: Int = 0, loop: Int = 0) -> Result {
        let barsA = a.grid.barCount(duration: a.duration)
        let barsB = b.grid.barCount(duration: b.duration)
        guard let whole = a.structure, let sb = b.structure, !whole.loudness.isEmpty, !sb.loudness.isEmpty else {
            return Result(entryBar: max(0, barsA - n - 8), cueBar: 0, vocalHandoff: n, reason: "")
        }
        let echo = preset == .echoOut
        // Looped, A's beat (drums, bass line, melody) repeats its last full
        // bars from the entry on and its voice is gone: what plays under B
        // is that bed, not what the song goes on to.
        let loop = preset == .stemSwap ? loop : 0
        /// Bars before the entry the loop's bars start: the phrase before
        /// the last where that's as full, so the fill that ends a part
        /// plays once, into the loop, and isn't repeated every four bars.
        func loopBack(_ e: Int) -> Int { whole.loops(before: e, bars: 2 * loop) ? 2 * loop : loop }
        /// A as it plays through a blend that starts on its bar `e`.
        func playing(_ e: Int) -> TrackStructure {
            loop > 0 ? whole.looped(from: e, bars: loop, back: loopBack(e), through: e + n + 12) : whole
        }
        // Bar (from B's entry) at which A's vocal is taken out and B's comes in.
        let swap = echo ? 0 : n / 2
        let vocalIn = echo ? 0 : n
        // (Over a loop B's voice comes in early wherever it sits, see below:
        // there is no voice of A's to wait for.)
        let mash = mashup && preset == .stemSwap && n >= 16 && loop == 0
            ? Int(TransitionBuilder.mashupWindow(bars: n).earliest) : nil
        let handoffs = (swap == vocalIn ? [vocalIn] : [vocalIn, swap]) + (mash.map { [$0] } ?? [])
        let span = echo ? 0 : n
        let boundA = whole.boundaryStrength(), boundB = sb.boundaryStrength()
        // Each song's phrases, counted from its own section changes: the
        // transition starts on one of A's and B is cued on one of its own,
        // and the voices hand over where parts end and begin.
        let (partsA, startsA) = AutoPlacement.phrases(whole, boundary: boundA)
        let (partsB, startsB) = AutoPlacement.phrases(sb, boundary: boundB)
        func onPhrase(_ starts: [Bool], _ g: Int) -> Bool { g >= 0 && g < starts.count ? starts[g] : g % 4 == 0 }
        let refA = whole.referenceLoudness + trimA, refB = sb.referenceLoudness + trimB
        func bound(_ x: [Float], _ i: Int) -> Float { i >= 0 && i < x.count ? x[i] : 0 }

        // A must still be playing music when the transition ends (a video's
        // spoken outro or fade doesn't count).
        // Nor fading out: the whole blend sits in A's full-level part.
        let musicEndA = (whole.loudness.lastIndex { $0 + trimA > refA - 5 } ?? barsA - 1) + 1
        // (A loop needs none of A's music past the entry.)
        let latest = max(0, min(barsA, musicEndA) - (loop > 0 ? 0 : max(1, span)))
        // The entry is someone's say (a spot chosen in the editor, the
        // next song brought in now): not for placement to pick.
        let given = spot != nil || entryRange.map { $0.lowerBound == $0.upperBound } ?? false
        // A Wash Out's bridge starts its bars before the entry: A's own
        // time on its own comes before that, not under it.
        let bridge = echo ? min(n, 8) : 0
        // Past a jump, only once the eight bars before the transition (and
        // a Wash Out's own) are all played ones.
        // The jump on offer, unless it turns out to leave A no phrase to go
        // out on (see below).
        var skip = skip
        // A bar that isn't four beats long (see `BeatGrid.wanders`) has no
        // place in a blend or just before it: the two songs' bars are
        // counted off against each other from the entry and the cue.
        func plainA(_ e: Int) -> Bool { a.grid.isRegular((e - max(8, bridge))..<(e + span + 1)) }
        func plainB(_ c: Int) -> Bool { b.grid.isRegular(c..<(c + span + 9)) }
        func onGrid(_ from: Int, _ through: Int) -> [Int] {
            guard from <= through else { return [] }
            // (Nor do the bars a jump leaves out count as A's time on its
            // own: past it, A has still played what it's owed.)
            let owed = entryRange?.lowerBound ?? 0
            return (from...through).filter { onPhrase(startsA, $0) && plainA($0) }
                // A bed to loop: full bars, played at the blend's tempo (A
                // has to get there first, on its own time). And where a
                // part of A ends (that's what a loop is set on: the last
                // bars of a chorus, not the middle of a verse), unless the
                // entry is given or A's music ends under the blend.
                .filter { e in
                    loop == 0 || (whole.loops(before: e, bars: loop) && e - loopBack(e) - runUp >= (soloFrom ?? 0)
                                  && (given || e + n > musicEndA || bound(partsA, e) >= 0.7))
                }
                .filter { e in
                    skip.map { e + span <= $0.lowerBound || (e - bridge - 8 >= $0.upperBound && e - $0.count >= owed) } ?? true
                }
        }
        var entries: [Int]
        // The blend doesn't fit into what's left of A's music.
        var overruns = false
        if let spot {
            entries = loop == 0 || whole.loops(before: spot.entry, bars: loop) ? [spot.entry] : []
        } else if loop > 0 {
            // Only where there's a bed to loop, after A's time on its own.
            let from = (entryRange?.lowerBound ?? Int(Double(barsA) * 0.45))
            entries = onGrid(from, min(entryRange?.upperBound ?? latest, latest))
        } else if let entryRange {
            // After A's time on its own; if A hasn't the bars left for
            // that and this blend, on the last phrase the blend still fits
            // on (A keeps what time it can), but not before A is back at
            // its own tempo. Always on A's phrases: where not even that
            // fits, the blend is too long for this song, starts on the
            // first phrase A is free on and runs past its music (and
            // costs: a shorter one that fits is the better plan).
            let wanted = entryRange.lowerBound + bridge
            let floor = min(wanted, (soloFrom ?? entryRange.lowerBound) + bridge + runUp)
            entries = onGrid(wanted, min(entryRange.upperBound, latest))
            // A jump takes bars out of the song: where A can then neither
            // leave before it nor play its time after it, there is no jump,
            // and A leaves from wherever suits. (With the jump kept, the
            // only phrase left was A's first free one: a song gone eight
            // seconds after it had the floor.)
            if entries.isEmpty, skip != nil {
                skip = nil
                entries = onGrid(wanted, min(entryRange.upperBound, latest))
            }
            if entries.isEmpty { entries = onGrid(floor, min(entryRange.upperBound, latest)).suffix(1) }
            if entries.isEmpty {
                let first = (floor..<(floor + 8)).first { onPhrase(startsA, $0) } ?? floor
                overruns = first > latest
                entries = [first]
            }
        } else {
            // On its own (the editor): from the song's second half.
            entries = onGrid(min(latest, Int(Double(barsA) * 0.45)), latest)
        }
        // Skipping more than ~45 % of B throws away too much of it. Far
        // enough to reach the first chorus: a DJ mixes pop in on the hook.
        // And B needs music left once the blend is over: its time on its
        // own and a way out. A short song cued half-way in is over as soon
        // as it has the floor (as the set's last one: straight into the
        // final fade).
        let musicEndB = (sb.loudness.lastIndex { $0 + trimB > refB - 5 } ?? barsB - 1) + 1
        let room = barsB - n - 8
        let lastCue = max(0, min(Int(Double(barsB) * 0.45), room,
                                 min(barsB, musicEndB) - span - glide - SetBuilder.minimumSoloBars(b.grid) - 16))
        var cues = (0...lastCue).filter { onPhrase(startsB, $0) && plainB($0) }
        // Too short for a cue on its phrase grid within that: its first
        // phrase if the song has the bars for it, else its first bar.
        if cues.isEmpty { cues = [(0...max(0, min(3, room))).first { onPhrase(startsB, $0) } ?? 0] }
        if let spot { cues = [spot.cue] }

        // Where the low end changes hands for an entry and a cue: the first
        // phrase from half-way where B's own kick and bass are really
        // there; if B is still building, A keeps it until B's drop at the
        // end. But if A's own low end leaves first (a breakdown starting
        // inside the blend), B's takes over right there, from the second
        // bar on (one to hear B's tops first), wherever it's ready: a DJ
        // doesn't leave the floor without a kick and bass for bars just
        // to swap them on a later downbeat.
        let step = max(1, n / 4)
        // Nowhere to loop: not a plan.
        guard loop == 0 || !entries.isEmpty else {
            return Result(entryBar: max(0, barsA - n - 8), cueBar: 0, vocalHandoff: n, reason: "", score: -.infinity)
        }
        func lowSwap(_ sa: TrackStructure, entry e: Int, cue c: Int) -> Int? {
            guard !echo else { return nil }
            // A Drop Swap flips everything half-way, low end included; a
            // Long Blend trades the lows half-way.
            if preset != .stemSwap { return Int(TransitionBuilder.switchBar(preset, bars: n, lowSwap: nil)) }
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
        func switchBar(_ sw: Int?) -> Int { Int(TransitionBuilder.switchBar(preset, bars: n, lowSwap: sw)) }

        /// Worth building into (roll, silence, drop) at bar `switchAt`: B's
        /// hook or a real lift of B there, with A's beat there to roll, and
        /// only if B really lands, its first two bars at full level (not a
        /// pickup or a break before the section proper: a roll and a
        /// silence into two quiet bars is an anticlimax). Decided with the
        /// spot, since A is gone at such a switch rather than lingering.
        func dropMoment(_ sa: TrackStructure, e: Int, c: Int, switchAt: Int) -> Bool {
            // A Stem Swap builds into one only from a blend long enough to
            // be a build (as the set builder plays it).
            guard !echo, switchAt >= 4, preset == .dropSwap || n >= SetBuilder.dropMomentBars,
                  sa.meanActivity(.drums, bars: (e + switchAt - 2)..<(e + switchAt)) > 0.5,
                  min(sb.meanLoudness(bars: (c + switchAt)..<(c + switchAt + 1)),
                      sb.meanLoudness(bars: (c + switchAt + 1)..<(c + switchAt + 2))) >= sb.referenceLoudness - 3
            else { return false }
            let rise = sb.meanLoudness(bars: (c + switchAt)..<(c + switchAt + 8))
                - sb.meanLoudness(bars: (c + switchAt - 4)..<(c + switchAt))
            return preset == .dropSwap || sb.hook(from: c + switchAt) >= 0.4
                || (bound(boundB, c + switchAt) >= 0.5 && rise >= 3)
        }
        let wholePower = AutoPlacement.powers(whole, trim: trimA), powerB = AutoPlacement.powers(sb, trim: trimB)
        // B's low end (kick, bass line, 808s below 150 Hz) bar by bar, and
        // how much of it its full sections carry (80th percentile).
        let lowB: [Float] = powerB.map { p in
            (0..<barsB).map { k in
                10 * log10(max(1e-9, p.values.reduce(Float(0)) { $0 + (k < $1.count ? $1[k].low : 0) }))
            }
        } ?? []
        let fullLowB = lowB.isEmpty ? 0 : lowB.sorted()[Int(Double(lowB.count - 1) * 0.8)]
        /// dB B's low end falls short of its full sections over the two bars
        /// from bar `bar` of B: where it takes the kick and bass over.
        func lowShort(at bar: Int) -> Float {
            // (Past B's end there's nothing to judge.)
            let from = max(0, bar), to = min(lowB.count, bar + 2)
            guard from < to, let landing = lowB[from..<to].max() else { return 0 }
            return max(0, fullLowB - landing)
        }
        /// Whether the melodies clash at this spot, heard in the notes both
        /// songs play where they'd overlap (as the builder will judge it on
        /// the audio), not only guessed from the two keys. Where they do,
        /// B's melody and voice wait for the swap, and the spot is judged
        /// as that: planned as a blend, it would play as A alone.
        func notesClash(_ sa: TrackStructure, e: Int, c: Int, sw: Int?) -> Bool {
            // A Wash Out never plays the two songs' notes together.
            guard !echo else { return false }
            // Songs analysed before per-bar notes existed: the keys are
            // all there is.
            guard whole.harmonyChroma ?? whole.barChroma != nil, sb.harmonyChroma ?? sb.barChroma != nil else { return keysClash }
            // No notes where the melodies would overlap: nothing to clash.
            guard let clash = overlapClash(a: sa, aShift: aShift, entry: e, b: sb, bShift: bShift, cue: c,
                                           preset: preset, bars: n, lowSwap: sw) else { return false }
            if clash > clashAbove ?? (keysClash ? Harmony.keysClashTolerance : Harmony.clashTolerance) { return true }
            // Or their notes grate, whatever scales they're in.
            let rough = overlapClash(a: sa, aShift: aShift, entry: e, b: sb, bShift: bShift, cue: c, preset: preset, bars: n,
                                     lowSwap: sw, measure: Harmony.roughness)
            return rough.map { $0 > Harmony.roughTolerance } ?? false
        }

        var best = (entry: entries.last ?? max(0, barsA - n), cue: cues.first ?? 0, handoff: vocalIn,
                    lowSwap: lowSwap(playing(entries.last ?? 0), entry: entries.last ?? 0, cue: cues.first ?? 0),
                    score: -Float.infinity)
        var bestHeard: Int?, bestVocal: Double?, bestCarry = false
        for e in entries.isEmpty ? [max(0, latest)] : entries {
            let sa = playing(e)
            let powerA = loop > 0 ? AutoPlacement.powers(sa, trim: trimA) : wholePower
            // A side: beat under the first half, energy before and during.
            let drumsA = min(1.2, sa.meanActivity(.drums, bars: e..<(e + max(1, span / 2))))
            // Before the transition: for a Wash Out, before its bars.
            let lead = echo ? min(n, 8) : 0
            let preA = sa.meanLoudness(bars: (e - lead - 8)..<(e - lead)) + trimA
            let duringA = sa.meanLoudness(bars: e..<(e + max(1, span / 2))) + trimA
            var scoreA: Float = (echo ? 0 : drumsA) - (overruns ? 4 : 0) - (loop > 0 ? AutoPlacement.loopCost : 0)
            // Leaving out of a breakdown starts the transition on a floor
            // that has already cooled.
            scoreA -= 0.2 * max(0, refA - preA - 2)
            scoreA -= 0.10 * max(0, preA - duringA - 3)
            // (Looped, A has no section of its own ending with the blend.)
            scoreA += 0.6 * bound(boundA, e) + (loop > 0 ? 0 : 0.3 * bound(boundA, e + span))
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
            for k in stride(from: 2, to: span, by: 1) where loop == 0 && bound(boundA, e + k) > 0.5 {
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
                let sw = lowSwap(sa, entry: e, cue: c)
                let clashHere = notesClash(sa, e: e, c: c, sw: sw)
                // The payoff: B's hook lands right as B takes over (a Wash
                // Out drops straight into it), or B has a real drop there.
                let switchAt = switchBar(sw)
                let drop = dropMoment(sa, e: e, c: c, switchAt: switchAt)
                score += 1.2 * sb.hook(from: c + switchAt)
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
                    guard (rise >= 4 && bound(boundB, c + h) >= 0.5) || spot != nil else { continue }
                    score += 1.0 * bound(boundB, c + h) * min(1, max(0, (rise - 2) / 6))
                    score += 0.4 * bound(boundA, e + h)
                    score -= 0.6 * sa.meanActivity(.vocals, bars: (e + h - 1)..<(e + h + 1))
                }
                if let sw, sw < span {
                    // The real change happens at the swap: best on a new
                    // section of B and the end of one of A's.
                    score += 0.4 * bound(boundB, c + sw) + (loop > 0 ? 0 : 0.3 * bound(boundA, e + sw))
                }
                // A's kick and bass leave on the switch (a cut's too): B must
                // have a low end there to take them over. Handed to a part
                // of B without one (a pre-chorus, a breakdown, a bare intro)
                // the floor loses its weight for bars, however loud B's top
                // is. A DJ swaps the bass where the next record's bass is.
                // (4 dB under its full sections is still a groove; 10 under
                // is the floor going thin for bars, which outweighs a hook.)
                score -= min(2.5, 0.25 * max(0, lowShort(at: c + switchAt) - 4))
                // B's vocal may also come in right on the switch, so a hook
                // landing there isn't muted until the end of the blend.
                let options = sw.map { $0 > n / 2 && $0 < n && !handoffs.contains($0) ? handoffs + [$0] : handoffs } ?? handoffs
                for handoff in options {
                    // No mashup over notes that clash.
                    if clashHere && handoff == mash { continue }
                    var s = score + (handoff == vocalIn ? 0.15 : 0)
                    var heard: Int?
                    var heardVocal: Double?, heardOut: Double?
                    // What each voice is cut on (nil: faded mid-word).
                    var heardIn: VocalPhrasing.Cut? = .line, heardExit: VocalPhrasing.Cut? = .line
                    // Whether B's voice comes in in the middle of a part
                    // of it (no part starts in reach), and A's leaves in
                    // the middle of one of its own.
                    var heardMid = false, heardOutMid = false
                    // And whether A's is cut off in the middle of a sentence
                    // (no clause of it ends in reach).
                    var heardOutCut = false
                    var heardCarry = false
                    var cautious: (out: Double?, vin: Double)?
                    if handoff == mash {
                        // B singing over A's beat is the moment, best with
                        // its hook.
                        s += 0.5 * min(1, sb.meanActivity(.vocals, bars: (c + handoff)..<(c + n / 2)))
                        s += 0.8 * sb.hook(from: c + handoff)
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
                    // (Two more for the voices handing over on the edges of
                    // two parts, which is only known once they're placed.)
                    if s + 2 + 2 * AutoPlacement.partWeight <= best.score { continue }
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
                        struct Plan {
                            let vocalBar: Int, mashup: Bool, vin: Double, drumsLayer: Bool
                            /// Where A's voice leaves (nil: the builder's own, with a mashup's).
                            var out: Double? = nil
                            /// What each voice is cut on (nil: mid-word, faded).
                            var inCut: VocalPhrasing.Cut? = .line, outCut: VocalPhrasing.Cut? = .line
                        }
                        /// A's voice sings until B's really does or B takes
                        /// the low end, whichever is first, leaving on the
                        /// breath or the gap between words nearest to that
                        /// (as the set builder decides it on the audio): up
                        /// to a bar before, or a little after while nobody
                        /// else is singing yet.
                        func exit(for vin: Double) -> (bar: Double, kind: VocalPhrasing.Cut?) {
                            // Looped, A's voice goes as the loop starts: on
                            // the last word of the part that ends there.
                            if loop > 0 {
                                return AutoPlacement.vocalCut(whole, at: e, opening: false, target: 0,
                                                              earliest: -AutoPlacement.loopExit.before,
                                                              latest: AutoPlacement.loopExit.after)
                            }
                            let limit = Double(min(n, sw ?? n))
                            let untilB = AutoPlacement.vocalSounds(sb, cue: c, from: vin, limit: max(vin + 4, Double(n)))
                            let target = AutoPlacement.phraseEnd(before: min(untilB, limit))
                            let after = clashHere ? 0 : target >= limit ? 0.5 : 2
                            return AutoPlacement.vocalCut(sa, at: e, opening: false, target: target,
                                                          earliest: target - min(AutoPlacement.exitBack, target),
                                                          latest: min(target + after, max(target, untilB), Double(n)))
                        }
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
                        func entry(from first: Int) -> (bar: Double, kind: VocalPhrasing.Cut?) {
                            let aim = sa.isActive(.vocals, bar: e + first) && first >= n / 2
                                ? min(max(v, first), max(first, min(n, sw ?? n))) : first
                            // (A cut or Wash Out drops B in whole, its
                            // voice with its beat: never held back while
                            // the song plays, then let in mid-verse. What
                            // counts is whether a line starts there, or a
                            // pickup a beat before, in the gap.)
                            if echo {
                                return AutoPlacement.vocalCut(sb, at: c, opening: true, target: 0,
                                                              earliest: -AutoPlacement.pickup, latest: 0)
                            }
                            return AutoPlacement.vocalCut(sb, at: c, opening: true, target: Double(aim),
                                                          // (Half a bar before its floor too: a line
                                                          // that starts with a pickup is let in on the
                                                          // pickup, not on a gap between its words
                                                          // just past the bar line.)
                                                          earliest: max(0, Double(aim) - (clashHere ? 0 : 0.5)),
                                                          latest: AutoPlacement.entryLatest(sb, aim: Double(aim), bars: n))
                        }
                        /// Before the swap B's voice sings over A's melody
                        /// and bass line: only where it sits on them (as
                        /// the builder checks on the audio). Otherwise it
                        /// waits for the swap.
                        func sitsOnA(from first: Int, until swap: Int) -> Bool {
                            guard swap > first, let chords = AutoPlacement.notes(sa, bars: (e + first)..<(e + swap)),
                                  let voice = AutoPlacement.vocalNotes(sb, bars: (c + first)..<(c + swap)) else { return true }
                            return Harmony.clash(chords, voice) <= Harmony.fitTolerance
                        }
                        // Over A's beat looped, with A's voice gone, B's
                        // may come in with its melody a quarter in: the
                        // loop is a bed for the new song, not a part of
                        // the old one to sing against. (Where a quarter in
                        // is a phrase of B's: in a blend of sixteen bars.
                        // From the first bar was tried: it left fewer bars
                        // with nobody singing, and thinner blends with
                        // more voices let in mid-line.)
                        // A quarter in, too, where A's part ends there and
                        // B's begins: one singer hands over to the next on
                        // the edge of both parts, over A's beat.
                        let q = n / 4
                        // (Both only where the grooves are known to lock: the
                        // builder lets a voice over the other song's beat
                        // only then, and a spot chosen for the handover
                        // would play as something else.)
                        let partsMeet = drumsLock && n >= 16 && bound(partsA, e + q) >= 0.7 && bound(partsB, c + q) >= 0.7
                        // From the first bar where A's voice is gone already
                        // (a loop) and B's part starts with the blend: held
                        // back, it would come in in the middle of that part.
                        // (Nor, with A's voice gone, is there anything for it
                        // to wait for where B is already singing at its cue.)
                        let partStarts = drumsLock && loop > 0 && bound(partsB, c) >= 0.7 && sb.meanActivity(.vocals, bars: c..<(c + q)) > 0.3
                        let floor = clashHere ? swap
                            : early ?? (echo ? n / 2
                                        : partStarts && sitsOnA(from: 0, until: swap) ? 0
                                        : n >= 16 && (loop > 0 || partsMeet) && sitsOnA(from: n / 4, until: swap) ? n / 4
                                        : sitsOnA(from: n / 2, until: swap) ? n / 2 : swap)
                        func plan(from first: Int, drumsLayer: Bool) -> Plan {
                            let vin = entry(from: first)
                            // (On a cut A's beat may ride on alone for up to four
                            // bars after its singer's last line.)
                            let ahead = n <= 1 ? 0.0 : 1.0, back = n <= 1 ? 4.0 : 3.0
                            let out = echo ? AutoPlacement.vocalCut(sa, at: e, opening: false, target: -ahead,
                                                                    earliest: -back, latest: 0)
                                : exit(for: vin.bar)
                            return Plan(vocalBar: v, mashup: false, vin: vin.bar, drumsLayer: drumsLayer,
                                        out: echo ? nil : out.bar, inCut: vin.kind, outCut: out.kind)
                        }
                        plans.append(plan(from: floor, drumsLayer: true))
                        if preset == .stemSwap, !drumsLock {
                            // First: usually the worst, so the rest can be
                            // skipped once the spot can't win.
                            plans.insert(plan(from: swap, drumsLayer: false), at: 0)
                        }
                        let heardPlan = plans.first { $0.mashup } ?? plans[plans.count - 1]
                        heardVocal = heardPlan.vin
                        heardOut = heardPlan.out
                        heardMid = sb.midPart(at: VocalPhrasing.slots * c
                                                + Int((heardPlan.vin * Double(VocalPhrasing.slots)).rounded())) == true
                        let outSlot = heardPlan.out.map { VocalPhrasing.slots * e + Int(($0 * Double(VocalPhrasing.slots)).rounded()) }
                        heardOutMid = outSlot.map { whole.midPart(at: $0) == true } ?? false
                        heardOutCut = outSlot.map { whole.midSentence(at: $0) == true && !whole.clauseEnd(at: $0) } ?? false
                        // (And as the cautious plan would have them, where the
                        // grooves aren't known to lock: see below.)
                        if preset == .stemSwap, !drumsLock, !heardPlan.mashup { cautious = (plans[0].out, plans[0].vin) }
                        (heardIn, heardExit) = (heardPlan.inCut, heardPlan.outCut)
                        let aim = min(8, n / 2 + 2)
                        /// The worst any of the plans does: its holes and
                        /// pile-ups, and the bars both songs are heard in.
                        func judge(carry: Bool, bail: Bool) -> (penalty: Float, fewest: Int, busy: Int) {
                            var worstPenalty: Float = 0, fewest = Int.max, busiest = 0
                            for plan in plans {
                                // B's melody under A's voice for as long as it sings.
                                let under = preset == .stemSwap && !clashHere && !plan.mashup
                                    ? AutoPlacement.under(a: powerA, e: e, b: powerB, c: c, from: step,
                                                          to: Int((plan.out ?? Double(sw ?? n)).rounded(.up)))
                                    : 0
                                func shape(room: Double) -> TransitionShape {
                                    TransitionShape.cached(preset, bars: n, vocalBar: plan.vocalBar, keysClash: clashHere,
                                                           lowSwap: sw, mashup: plan.mashup, room: room, dropMoment: drop,
                                                           vocalIn: echo ? nil : plan.vin, drumsLayer: plan.drumsLayer,
                                                           drumsLinger: !drumsLock || drumsLinger, vocalOut: plan.out,
                                                           carry: (carry || loop > 0) && !plan.mashup, under: under)
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
                                // Three or four melodies and voices at once,
                                // for more than a bar or two: clutter.
                                let busy = (shape.first..<shape.last).filter {
                                    shape.busy($0, a: powerA, e: e, b: powerB, c: c)
                                }.count
                                penalty += 0.4 * Float(max(0, busy - 2))
                                busiest = max(busiest, busy)
                                worstPenalty = max(worstPenalty, penalty * 24 / Float(bars.count))
                                // A transition, not two songs in a row: both
                                // clearly heard for a while.
                                fewest = min(fewest, (shape.first..<shape.last).filter {
                                    shape.together($0, a: powerA, e: e, b: powerB, c: c)
                                }.count)
                                // The worst plan so far already sinks it.
                                if bail, s - worstPenalty + 0.25 * Float(min(fewest, aim))
                                    - (echo ? 0 : 0.5 * Float(max(0, aim - fewest))) <= best.score { break }
                            }
                            return (worstPenalty, fewest, busiest)
                        }
                        var (worstPenalty, fewest, busy) = judge(carry: false, bail: true)
                        // Where B would hardly be heard under all of A, A's
                        // melody can make way before B's comes in, and A's
                        // beat and voice carry B's parts (what a DJ loops
                        // A's bare beat for). A remedy, not a habit: only
                        // for a blend that falls short, where it clearly
                        // gains and opens no hole.
                        if preset == .stemSwap, !clashHere, handoff != mash, fewest < aim, loop == 0 {
                            let carried = judge(carry: true, bail: false)
                            if carried.fewest >= fewest + 2, carried.penalty <= worstPenalty + 0.5 {
                                (worstPenalty, fewest, busy) = carried
                                heardCarry = true
                            }
                        }
                        // Or where A sings on through the bars both melodies
                        // would play: three parts at once for bars. A's
                        // melody makes way there too, if that costs the
                        // blend nothing.
                        if preset == .stemSwap, !clashHere, handoff != mash, loop == 0, !heardCarry, busy > 2 {
                            let carried = judge(carry: true, bail: false)
                            if carried.busy < busy, carried.penalty <= worstPenalty, carried.fewest >= fewest - 1 {
                                (worstPenalty, fewest, busy) = carried
                                heardCarry = true
                            }
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
                        // in the bridge's last bars. (B landing mid-line on
                        // a cut is the first thing heard of it: twice the
                        // cost of a blend's entry.)
                        s -= AutoPlacement.cutCost(in: heardIn, out: heardExit)
                            + AutoPlacement.cutCost(in: heardIn, out: .line)
                        // (Nor in the middle of a verse: twice too.)
                        s -= heardMid ? 2 * AutoPlacement.midPartCost : 0
                        s += AutoPlacement.partWeight * (bound(partsA, e)
                                                         + (heardMid ? 0 : bound(partsB, c + Int((heardVocal ?? 0).rounded()))))
                        // (And B's voice shouldn't trail its beat by bars.)
                        s -= 0.3 * Float(heardVocal ?? 0)
                        if s > best.score { best = (e, c, handoff, sw, s); bestHeard = heard; bestVocal = heardVocal; bestCarry = heardCarry }
                        continue
                    }
                    // A's vocal leaves when B's arrives (where it will
                    // really come in) or B takes the low end, whichever is
                    // first; anything A sings later is cut.
                    let out = min(Int((heardOut ?? heardVocal ?? Double(handoff)).rounded(.down)), sw ?? n)
                    s -= 1.5 * sa.meanActivity(.vocals, bars: (e + out)..<(e + max(out + 1, span)))
                    s -= 0.3 * sa.meanActivity(.vocals, bars: (e + out - 1)..<(e + out))
                    // Between lines on both sides: where the builder will
                    // find no breath or gap between words to cut on, a
                    // voice is faded through the sentence it's singing.
                    s -= AutoPlacement.cutCost(in: heardIn, out: heardExit)
                    // And where: a singer is taken out at the end of a part
                    // and let in at the start of one, not between two lines
                    // of a verse. That, more than a clean cut, is what makes
                    // a handover sound meant.
                    // (B's let in mid-verse is no edge, whatever bar it's on;
                    // nor is A's taken out with its verse half sung, if
                    // less of a flaw: B's voice takes the ear from there. At
                    // half as much as here, blends shortened to find A's
                    // part ends: 10 bars of both songs fewer in 10
                    // transitions, for handovers no cleaner by the words.
                    // Cut off mid-sentence, more.)
                    s -= (heardMid ? AutoPlacement.midPartCost : 0) + (heardOutMid ? AutoPlacement.midPartCost / 4 : 0)
                        + (heardOutCut ? AutoPlacement.midPartCost / 2 : 0)
                    s += AutoPlacement.partWeight * ((heardOutMid ? 0 : bound(partsA, e + AutoPlacement.partBar(leaving: heardOut ?? Double(out))))
                                + (heardMid ? 0 : bound(partsB, c + Int((heardVocal ?? Double(handoff)).rounded()))))
                    // And nobody singing where a song has words: A's voice
                    // gone before B's has come (or B's held back where A
                    // has nothing to sing) is a hole in the blend's middle.
                    let from = heardOut ?? Double(out), to = heardVocal ?? Double(handoff)
                    let silent = (0..<n).filter { k in
                        let a = sa.isActive(.vocals, bar: e + k), b = sb.isActive(.vocals, bar: c + k)
                        return (a || b) && !(a && Double(k) < from) && !(b && Double(k + 1) > to)
                    }.count
                    s -= 0.3 * Float(max(0, silent - 1))
                    // Where the grooves aren't known to lock, the voices may
                    // hand over as the cautious plan has them instead (B's
                    // waiting for the swap): the bars nobody would sing
                    // then, at half the price, as the risk it is.
                    if let cautious {
                        let from = cautious.out ?? Double(out), to = cautious.vin
                        let risk = (0..<n).filter { k in
                            let a = sa.isActive(.vocals, bar: e + k), b = sb.isActive(.vocals, bar: c + k)
                            return (a || b) && !(a && Double(k) < from) && !(b && Double(k + 1) > to)
                        }.count
                        // (In full over a loop: A's voice is gone from the
                        // first bar, so those bars are nobody singing for
                        // certain if B's waits.)
                        s -= (loop > 0 ? 0.3 : 0.15) * Float(max(0, risk - silent))
                    }
                    if s > best.score { best = (e, c, handoff, sw, s); bestHeard = heard; bestVocal = heardVocal; bestCarry = heardCarry }
                }
            }
        }
        var notes: [String] = []
        let handoff = best.handoff
        let sa = playing(best.entry)
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
        if sb.hook(from: best.cue + switchAt) >= 0.4 { payoff.append(echo ? "drops into B's hook" : "B's hook on the switch") }
        let isMashup = handoff == mash
        if isMashup { payoff.append("mashup: B sings over A's beat") }
        let drops = dropMoment(sa, e: best.entry, c: best.cue, switchAt: switchAt)
        if drops { payoff.append("roll into the drop") }
        notes.insert(contentsOf: payoff, at: 0)
        return Result(entryBar: best.entry, cueBar: best.cue, vocalHandoff: handoff, lowSwap: best.lowSwap,
                      reason: notes.joined(separator: " · "), score: best.score, mashup: isMashup,
                      dropMoment: drops, payoff: payoff, together: bestHeard, expectedVocalIn: bestVocal,
                      notesClash: notesClash(sa, e: best.entry, c: best.cue, sw: best.lowSwap), overruns: overruns,
                      jumps: skip != nil,
                      carry: bestCarry, loopBars: loop, loopBack: loop > 0 ? loopBack(best.entry) : 0)
    }
}
