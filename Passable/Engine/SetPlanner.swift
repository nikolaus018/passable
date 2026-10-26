import Accelerate
import CryptoKit
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

    /// B's rate while it plays under A: exactly 1 where the tempos are
    /// the same (see `TimeMap.sameTempo`).
    static func rate(a: Double, b: Double) -> Double {
        guard a > 0, b > 0 else { return 1 }
        let r = a / (b * tempoMultiplier(a: a, b: b))
        return abs(r - 1) < TimeMap.sameTempo ? 1 : r
    }

    /// How the two songs of a blend share the stretch: the rate each plays
    /// at through it (`b / a` is B's `rate` to A). A small one is B's
    /// alone, as a DJ nudges the incoming record; a bigger one they split,
    /// each moving half-way (in ratio) to a tempo between the two, so
    /// neither is heard far off its own: A glides there over its last
    /// bars alone, B glides home from there afterwards.
    static func shared(_ rate: Double) -> (a: Double, b: Double) {
        guard abs(rate - 1) > shareAbove else { return (1, rate) }
        let b = rate.squareRoot()
        return (b / rate, b)
    }

    /// Stretches up to this are the incoming song's alone.
    static let shareAbove = 0.03

    /// Beyond this (B's rate to A), the two aren't beat-matched: B comes in
    /// on a cut, each song at its own tempo (see `TransitionPreset.echoOut`
    /// at one bar). Up to it they meet half-way (see `shared`), each no
    /// more than 5 % off its own tempo: what a club DJ's pitch fader does
    /// with key lock on before a record everyone knows sounds too fast or
    /// too slow. (At 42 %, as this was, every steady pair was blended, and
    /// songs played up to 19 % off their own tempo: heard as wrong at once.
    /// 146 into 135 BPM, 8 %, still blends.)
    static let maxStretch = 0.10

    /// What a cut or Wash Out costs the set's order, against a blend's
    /// roughly -2 (great) to +1 (weak): a last resort. (At 1.5 a 68-song
    /// set took 4 cuts where 3 would do; at 3 it takes 3, with 3 fewer
    /// blends where the two songs are hardly heard together; 5 gives the
    /// same order of cuts.) Variable only for passable-render's trials.
    nonisolated(unsafe) static var cutCost = 3.0

    /// Up to this (each song no more than 4 % off its own tempo) a blend
    /// may run long. Past it the blend is a quick one: both songs are off
    /// their own tempo through it, which is heard the longer it lasts.
    static let easyStretch = 0.08

    static func recommendedPreset(rate: Double) -> TransitionPreset {
        abs(rate - 1) > maxStretch ? .echoOut : .stemSwap
    }

    /// As above, from the two tempos. (Songs detected at half or double
    /// time of each other share a beat too: see `Metre`.)
    static func recommendedPreset(a: Double, b: Double) -> TransitionPreset {
        recommendedPreset(rate: rate(a: a, b: b))
    }

    /// The preset for two songs: as their tempos say, unless one of them
    /// has no steady tempo at all (a drummer's: see `BeatGrid.downbeats`).
    /// Two beats can't be laid over each other where one of them wanders;
    /// such a song is bridged in and out on its downbeats.
    static func preset(_ a: TrackAnalysis, _ b: TrackAnalysis) -> TransitionPreset {
        a.grid.isSteady && b.grid.isSteady ? recommendedPreset(a: a.grid.bpm, b: b.grid.bpm) : .echoOut
    }

    /// Bars B takes to glide from A's tempo back to its own once A is gone:
    /// about 0.5 % per bar, as a DJ rides the pitch fader back over half a
    /// minute while a record plays alone, so no one hears the song speed up
    /// or slow down. (At 1.5 % a bar, as this was, 4.5 % went by in three
    /// bars, six seconds: heard as the song changing speed.)
    static func glideBars(rate: Double) -> Int {
        let percent = abs(rate - 1) * 100
        return percent < 0.05 ? 1 : min(16, max(2, Int((percent / 0.5).rounded(.up))))
    }

    /// Bars A takes to glide to the blend's tempo before it (0 where the
    /// stretch is all B's).
    static func runUpBars(rate: Double) -> Int {
        let a = shared(rate).a
        return a == 1 ? 0 : glideBars(rate: a)
    }

    /// Level match for a track, in dB. Boosts are capped: past that a quiet
    /// track would just be squashed by the limiter.
    /// `targetLoudness` as heard (K-weighted): pop and dance masters read
    /// 0.4 dB lower K-weighted than plain on average (30 songs), so the
    /// set as a whole plays as loud as it did.
    static let targetHeard: Float = -12.4

    static func trimDB(_ analysis: TrackAnalysis?) -> Double {
        guard let structure = analysis?.structure else { return 0 }
        if let heard = structure.heardReference { return Double(max(-12, min(8, targetHeard - heard))) }
        return Double(max(-12, min(8, targetLoudness - structure.referenceLoudness)))
    }

    /// No automatic blend runs longer than this, whatever the songs would
    /// allow: past it a crowd hears two songs fighting, not a mix. In
    /// seconds, because that's what feels long: 16 bars stay possible down
    /// to 86 BPM.
    static let maxBlendSeconds = 45.0

    static func keysClash(_ a: MusicalKey, _ b: MusicalKey) -> Bool {
        b.harmonicShift(toMatch: a, limit: 0) == nil
    }

    /// The most an automatic transition pitches a song to fit the one
    /// before: not at all. A song plays shifted for all of its time in the
    /// set, the next one is then fitted to it as it sounds (and shifted in
    /// turn), and a song everyone knows a semitone off its key is noticed
    /// more than the blend it buys. Keys that clash swap melodies instead;
    /// a shift can still be chosen by hand in the editor.
    static let maxKeyShift = 0

    /// Tempos this close layer a vocal over the other song's beat without
    /// the stretch being heard.
    static let mashupStretch = 0.05

    /// Bars to a loop of the outgoing song's beat: one four-bar phrase,
    /// which is what a DJ loops (shorter is a stutter, longer goes round
    /// too seldom to be a bed).
    static let loopBars = 4
}

/// Everything decided about one transition, from the two analyses alone.
struct PairPlan: Equatable {
    var preset: TransitionPreset
    var bars: Int
    /// B's rate during the overlap (1 for Wash Out).
    var rate: Double
    var placement: AutoPlacement.Result
    /// The melodies clash even after B's shift, so they are swapped: heard
    /// in the notes that overlap at the placed spot, or failing that
    /// guessed from the two keys.
    var keysClash: Bool
    /// B's pitch shift, for the whole time it plays.
    var semitones: Int = 0
    /// The two drum grooves were found to lock at this spot (from the
    /// songs' own drum hits), so it was placed for B's drums building in
    /// under A's rather than for the worst case of them not layering.
    var drumsLock = false

    var stretchPercent: Double { (rate - 1) * 100 }
    /// The rates A and B play at through the blend (see `MixMath.shared`).
    var shared: (a: Double, b: Double) { preset == .echoOut ? (1, 1) : MixMath.shared(rate) }

    /// - Parameter aShift: semitones A itself plays shifted by (its own
    ///   transition in), so B is fitted to the key A is heard in.
    /// - Parameter soloFrom: A's bar from which it plays on its own, to
    ///   pace its exit (see `AutoPlacement.pacing`).
    /// - Parameter drums: both songs' drum hits (`BeatAlign.attacks(of:)`),
    ///   to tell whether the grooves lock where the pair is placed. Without
    ///   them every spot is judged as if they might not.
    /// - Parameter fixed: the spot, preset, length and key are the user's
    ///   (see `TransitionEdit.byHand`): only what happens inside is planned.
    static func make(a: TrackAnalysis, b: TrackAnalysis, entryRange: ClosedRange<Int>? = nil, aShift: Int = 0,
                     soloFrom: Int? = nil, skip: Range<Int>? = nil, drums: (a: [Float], b: [Float])? = nil,
                     fixed: TransitionEdit? = nil, clashing: Bool = false, locking: Bool = false,
                     loops: Bool = true) -> PairPlan {
        let rate = MixMath.rate(a: a.grid.bpm, b: b.grid.bpm)
        // (A song without a steady tempo is bridged whatever was chosen
        // for it: there is no beat to lay another on.)
        let steady = a.grid.isSteady && b.grid.isSteady
        // Songs read at half or double time of each other: B is planned
        // as counted in A's bars (see `Metre`), and cued in its own. Two
        // of its bars to one can be counted from either of them: both
        // are tried, since a part of B may start on any bar of its own.
        // (Only where the two are beat-matched at all: a cut plays B in its
        // own bars.)
        if steady, (fixed?.preset ?? MixMath.preset(a, b)) != .echoOut,
           MixMath.tempoMultiplier(a: a.grid.bpm, b: b.grid.bpm) != 1 {
            var counts = [Metre(a: a.grid, b: b.grid, cue: fixed?.cueBar ?? 0)]
            if fixed == nil, counts[0].bars == 2 { counts.append(Metre(a: a.grid, b: b.grid, cue: 1)) }
            return counts.map { metre -> PairPlan in
                let counted = b.counted(metre)
                func plan(_ fixed: TransitionEdit?) -> PairPlan {
                    make(a: a, b: counted, entryRange: entryRange, aShift: aShift, soloFrom: soloFrom, skip: skip,
                         drums: drums, fixed: fixed, clashing: clashing, locking: locking, loops: loops)
                }
                var chosen = fixed
                chosen?.cueBar = metre.counted(fixed?.cueBar ?? 0)
                var made = plan(chosen)
                // (Each of B's bars counted as two: it is cued on the first
                // half of one, where its downbeat is.)
                if metre.bars == 0.5, fixed == nil, made.placement.cueBar % 2 != 0 {
                    made = plan(TransitionEdit(entryBar: made.placement.entryBar, cueBar: made.placement.cueBar - 1,
                                               preset: made.preset, bars: made.bars, semitones: made.semitones, lanes: [],
                                               byHand: false))
                }
                made.placement.cueBar = metre.own(made.placement.cueBar)
                return made
            }.max { $0.placement.score < $1.placement.score }!
        }
        let fixed = steady || fixed?.preset == .echoOut ? fixed : nil
        let preset = fixed?.preset ?? MixMath.preset(a, b)
        let aKey = a.key.transposed(by: aShift)
        // Where the keys clash, B could be pitched into A's key (up to
        // `MixMath.maxKeyShift`, which allows none): then the melodies can
        // layer and B can sing over A's beat. The shift stays on for all of
        // B, and a song everyone knows sounds wrong off its key, so it
        // costs a lot: only a much better blend would be worth it.
        var shifts = [0]
        if MixMath.keysClash(aKey, b.key),
           let shift = b.key.harmonicShift(toMatch: aKey, limit: MixMath.maxKeyShift), shift != 0 {
            shifts.append(shift)
        }
        func clash(_ shift: Int) -> Bool { MixMath.keysClash(aKey, b.key.transposed(by: shift)) }
        func place(_ preset: TransitionPreset, _ bars: Int, _ shift: Int, _ drumsLock: Bool,
                   _ drumsLinger: Bool, _ loop: Int) -> AutoPlacement.Result {
            AutoPlacement.place(a: a, b: b, bars: bars, preset: preset,
                                trimA: Float(MixMath.trimDB(a)), trimB: Float(MixMath.trimDB(b)),
                                entryRange: entryRange, keysClash: clash(shift),
                                // (Heard to clash on the audio, wherever placed: see
                                // `SetBuilder.build(clashed:)`.)
                                clashAbove: clashing ? -.infinity : Harmony.tolerance(aKey, b.key.transposed(by: shift)),
                                mashup: !clash(shift) && abs(rate - 1) < MixMath.mashupStretch, soloFrom: soloFrom,
                                skip: skip, aShift: aShift, bShift: shift, drumsLock: drumsLock, drumsLinger: drumsLinger,
                                at: fixed.map { ($0.entryBar, $0.cueBar) },
                                glide: preset == .echoOut ? 0 : MixMath.glideBars(rate: MixMath.shared(rate).b),
                                runUp: preset == .echoOut ? 0 : MixMath.runUpBars(rate: rate), loop: loop)
        }
        // The key estimate only proposes the shift; the notes that will
        // overlap at the spot it was placed on decide. B keeps its own key
        // wherever that sits: it moves only where its notes clearly clash
        // there and the shift clearly fixes that.
        func shiftPays(_ preset: TransitionPreset, _ bars: Int, _ shift: Int, _ p: AutoPlacement.Result) -> Bool {
            guard preset != .echoOut, let sa = a.structure, let sb = b.structure else { return false }
            func heard(_ bShift: Int) -> Float? {
                AutoPlacement.overlapClash(a: sa, aShift: aShift, entry: p.entryBar, b: sb, bShift: bShift, cue: p.cueBar,
                                           preset: preset, bars: bars, lowSwap: p.lowSwap)
            }
            guard let own = heard(0), let shifted = heard(shift) else { return false }
            // And only for a real blend: fitting notes that are hardly heard
            // together anyway aren't worth a song off its key.
            guard let together = p.together, together >= min(6, bars / 2 + 2) else { return false }
            return own > Harmony.shiftTolerance && shifted <= Harmony.clashTolerance && own - shifted >= 0.04
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
        var options = [(preset: preset, bars: preset.defaultBars, prior: preset == .echoOut ? 0 : length(preset.defaultBars),
                        loop: 0)]
        if preset == .echoOut {
            if steady {
                // Two steady beats too far apart in tempo: a cut on the
                // one, so the beat goes on. A beatless bridge between two
                // songs that both have a beat is a hole in the floor.
                options = [(.echoOut, 1, 0, 0)]
            } else {
                // A song without a steady beat: a shorter bridge too (two
                // bars for A's beat to leave, two of its melody floating
                // on), or a cut. Which one leaves less of a hole where
                // it's placed is for the simulation to say.
                options.append((.echoOut, 4, 0, 0))
                options.append((.echoOut, 1, 0, 0))
            }
        }
        if preset == .stemSwap {
            options.append((.stemSwap, 8, length(8), 0))
            options.append((.dropSwap, 16, length(16) - 0.2, 0))
            options.append((.dropSwap, 8, length(8) - 0.2, 0))
            // And each Stem Swap over A's beat looped (see
            // `TransitionBuilder.loop`): four bars, the phrase a DJ loops.
            if loops {
                options.append((.stemSwap, 16, length(16), MixMath.loopBars))
                options.append((.stemSwap, 8, length(8), MixMath.loopBars))
            }
        }
        options = options.filter { $0.preset == .echoOut || Double($0.bars) * barSeconds <= MixMath.maxBlendSeconds
            || $0.bars <= 8 }
        // Tempos far apart: a quick blend. Both songs are well off their
        // own tempo through it, which is heard the longer it lasts.
        if abs(rate - 1) > MixMath.easyStretch { options = options.filter { $0.preset == .echoOut || $0.bars <= 8 } }
        if let fixed {
            options = [(fixed.preset, fixed.bars, 0, 0)]
            if fixed.preset == .stemSwap { options.append((fixed.preset, fixed.bars, 0, MixMath.loopBars)) }
            shifts = [fixed.semitones]
        }
        typealias Candidate = (preset: TransitionPreset, bars: Int, shift: Int, placement: AutoPlacement.Result, prior: Float)
        func search(drumsLock: Bool, drumsLinger: Bool = true) -> Candidate {
            options.flatMap { option in shifts.map { (option, $0) } }
                .map { option, shift -> Candidate in
                    (option.preset, option.bars, shift,
                     place(option.preset, option.bars, shift, drumsLock, drumsLinger, option.loop),
                     option.prior - 1.0 * Float(abs(shift)))
                }
                .filter { $0.shift == 0 || fixed != nil || shiftPays($0.preset, $0.bars, $0.shift, $0.placement) }
                .max { $0.placement.score + $0.prior < $1.placement.score + $1.prior }!
        }
        /// Whether the two grooves clearly lock where `c` puts the blend,
        /// and whether A's drums can then play on under B's after the swap.
        func locks(_ c: Candidate) -> (before: Bool, after: Bool) {
            guard let drums, c.preset != .echoOut else { return (false, false) }
            let start = a.grid.downbeat(c.placement.entryBar)
            let sw = TransitionBuilder.switchBar(c.preset, bars: c.bars, lowSwap: c.placement.lowSwap)
            let lock = BeatAlign.predicted(a: drums.a, b: drums.b, from: start, to: start + Double(c.bars) * barSeconds,
                                           split: start + sw * barSeconds,
                                           bOffset: start - b.grid.scaled(by: rate).downbeat(c.placement.cueBar),
                                           rate: rate,
                                           loop: c.placement.loopBars > 0
                                               ? (Double(c.placement.loopBack) * barSeconds, Double(c.placement.loopBars) * barSeconds)
                                               : nil)
            return (lock.clearlyGrooves, lock.groovesAfter)
        }
        // Without knowing whether the grooves lock, every spot is judged by
        // its worst case: B's drums not layering under A's. Most of what
        // makes a blend a blend is lost in that case, so a pair whose
        // grooves do lock was placed (and priced, for the set's order) as
        // if they didn't. Where they lock at the spot found that way, the
        // pair is placed again for what will really play, and that spot
        // kept if they lock there too.
        var best = search(drumsLock: false), drumsLock = false
        // (Heard to lock on the audio where the worst case was planned:
        // see `SetBuilder.build(locked:)`.)
        let found = locking ? (before: true, after: locks(best).after) : locks(best)
        if found.before {
            // A's drums linger past the swap only where they sit there too:
            // placed for what was found, and once more without them if at
            // the new spot they don't.
            var layered = search(drumsLock: true, drumsLinger: found.after)
            var there = locks(layered)
            if there.before, found.after, !there.after {
                layered = search(drumsLock: true, drumsLinger: false)
                there = locks(layered)
            }
            if there.before || locking { (best, drumsLock) = (layered, true) }
        }
        // Whether the melodies swap is what placement heard at the spot it
        // chose (the keys only for songs analysed without notes to go by):
        // that is what will play, and what the pair is priced on.
        return PairPlan(preset: best.preset, bars: best.bars, rate: best.preset == .echoOut ? 1 : rate,
                        placement: best.placement,
                        keysClash: best.preset != .echoOut && (best.placement.notesClash ?? clash(best.shift)),
                        semitones: best.shift, drumsLock: drumsLock)
    }

    /// Lower is better. What a DJ weighs when picking the next record:
    /// how far it has to be stretched, whether the keys sit together,
    /// whether the energy keeps going, and how well the two songs' sections
    /// line up for a blend.
    func cost(a: TrackAnalysis, b: TrackAnalysis) -> Double {
        let stretch = abs(MixMath.rate(a: a.grid.bpm, b: b.grid.bpm) - 1) * 100
        var cost: Double
        // A Wash Out or a cut is priced as one whatever the tempos say:
        // it's a jump in tempo, fine once, not all night. A blend costs as
        // much more as the songs are pulled off their own tempos.
        switch stretch {
        case _ where preset == .echoOut: cost = MixMath.cutCost + 0.05 * stretch // fine once, not all night
        case ..<3: cost = 0.05 * stretch
        default: cost = 0.15 + 0.14 * (stretch - 3)
        }
        // Clashing songs can't blend, only swap: next to each other they
        // sound like two songs in a row. (A Wash Out never plays the two
        // together, and is priced as what it is above.)
        if keysClash, preset != .echoOut { cost += 1.2 }
        // Nor can a blend where placement already knows the two are hardly
        // heard together (a short one, B's intro too thin under A): as much
        // two songs in a row as a clash, so priced like one.
        // (0.4 a bar short: at 0.2 a 58-song set ordered itself into 14
        // such pairs where a set ordered by hand had 10.)
        if preset != .echoOut, let together = placement.together {
            cost += 0.4 * Double(max(0, min(6, bars / 2 + 2) - together))
        }
        // A song a semitone off its own key, for all of its time in the
        // set: only worth it where nothing else sits.
        cost += 0.5 * Double(abs(semitones))
        // A lift is how a set builds; a drop is what empties a floor, and
        // one big drop far more than the same in small steps.
        let drop = SetOrdering.energy(a) - SetOrdering.energy(b)
        cost += drop > 0 ? 2.0 * drop + 6.0 * drop * drop : 0.2 * -drop
        cost -= 0.3 * Double(placement.score)
        return cost
    }
}

/// Pair prices for ordering, kept between launches: a pair is planned in
/// full to be priced (tens of milliseconds), and a set of 58 songs has
/// 3,306 of them. Keyed by each song's analysis, so a song analysed again
/// (or a planner that prices differently: `version`) is priced again.
enum PairCosts {
    /// Bumped whenever planning or pricing changes.
    static let version = "7"

    /// One file per version: prices of another planner are dropped with
    /// it, not carried until the file fills up.
    private static var folder: URL { StemCache.root.deletingLastPathComponent() }
    private static var url: URL { folder.appendingPathComponent("pair-costs-\(version).json") }
    private static let lock = NSLock()

    static func fingerprint(_ analysis: TrackAnalysis) -> String {
        // (Keys sorted: a dictionary's are written in an order that changes
        // with every launch, and an analysis has several. Unsorted, no
        // song had the same fingerprint twice and nothing was ever
        // remembered from one launch to the next.)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(analysis)) ?? Data()
        return SHA256.hash(data: data + Data(version.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func load() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    static func save(_ costs: [String: Double]) {
        lock.lock(); defer { lock.unlock() }
        // (No more than a few sets' worth: oldest entries aren't tracked, so
        // past that it starts over.)
        let kept = costs.count > 200_000 ? [:] : costs
        if let data = try? JSONEncoder().encode(kept) { try? data.write(to: url, options: .atomic) }
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("pair-costs") && old.lastPathComponent != url.lastPathComponent {
            try? FileManager.default.removeItem(at: old)
        }
    }
}

enum SetOrdering {
    /// The same song twice: two downloads of one record (a video's audio
    /// and the single, say), which a DJ never plays twice in a set. Same
    /// key, tempo within 0.5 %, and the song's chords over its whole length
    /// alike to 0.998 (two copies measured 0.9993 and 0.9995 on a 68-song
    /// library; the closest two different songs, 0.9924 at 4 % apart).
    static func sameRecording(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Bool {
        guard a.key == b.key, a.grid.bpm > 0, abs(a.grid.bpm / b.grid.bpm - 1) < 0.005 else { return false }
        func profile(_ t: TrackAnalysis) -> [Float]? {
            guard let bars = t.structure?.harmonyChroma ?? t.structure?.barChroma, !bars.isEmpty else { return nil }
            var p = [Float](repeating: 0, count: 12)
            for bar in bars { for k in 0..<min(12, bar.count) { p[k] += bar[k] } }
            let norm = p.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return norm > 0 ? p.map { $0 / norm } : nil
        }
        guard let pa = profile(a), let pb = profile(b) else { return false }
        return zip(pa, pb).reduce(0) { $0 + $1.0 * $1.1 } >= 0.998
    }

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
    /// - Parameter drums: each song's drum hits (`BeatAlign.attacks(of:)`),
    ///   so pairs whose grooves lock are priced as the blends they'll be.
    /// - Parameter remembered: keep each pair's price on disk (see
    ///   `PairCosts`): ordering the same songs again, or a set sharing
    ///   songs with one ordered before, only prices the pairs it hasn't.
    static func costMatrix(_ analyses: [TrackAnalysis], drums: [[Float]?]? = nil, remembered: Bool = false) -> [[Double]] {
        let n = analyses.count
        let prints = remembered ? analyses.map(PairCosts.fingerprint) : []
        let known = remembered ? PairCosts.load() : [:]
        // Every pair is independent: all cores at once.
        var flat = [Double](repeating: 0, count: n * n)
        flat.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: n * n) { k in
                let i = k / n, j = k % n
                guard i != j else { return }
                if remembered, let cost = known[prints[i] + prints[j]] { out[k] = cost; return }
                // As the set will play it: A has the floor from about a
                // quarter in (after its own transition in), and leaves
                // paced for a crowd, not wherever suits this pair best.
                let a = analyses[i], soloFrom = a.grid.barCount(duration: a.duration) / 4
                let hits = drums.flatMap { d in d[i].flatMap { x in d[j].map { (a: x, b: $0) } } }
                // (Priced without a loop, which only ever makes a pair
                // better, and is decided when the set is built: twice as
                // quick, for a long set half a minute less of ordering.)
                out[k] = PairPlan.make(a: a, b: analyses[j], entryRange: (soloFrom + SetBuilder.minimumSoloBars(a.grid))...Int.max,
                                       soloFrom: soloFrom, drums: hits, loops: false).cost(a: a, b: analyses[j])
            }
        }
        if remembered {
            var all = known
            for i in 0..<n { for j in 0..<n where i != j { all[prints[i] + prints[j]] = flat[i * n + j] } }
            PairCosts.save(all)
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
            analyses.map { b in MixMath.preset(a, b) == .echoOut }
        }
    }

    /// A song between two Wash Outs is heard only between two beatless
    /// bridges: it flickers past with no beat carried in or out. A song in
    /// a tempo of its own belongs at an end of the set, not wedged in.
    static let washOutPairPenalty = 1.5

    /// A Wash Out is fine once, not all night: every one after a set's
    /// first costs this much more. Two songs out of the others' tempo
    /// range belong next to each other, not each behind a bridge of its own.
    static let extraWashOutPenalty = 0.75

    /// A set builds. Each transition is priced for the energy it drops,
    /// but a set that peaks and then winds down song by song in small
    /// steps pays little of that: the songs with the least drive belong
    /// before the peak, not after it.
    static let lostEnergyPenalty = 1.0

    /// The order with the lowest total cost: every transition's own, and
    /// what the set as a whole pays for (Wash Outs after the first, a song
    /// wedged between two, energy lost and not won back; see `total`).
    /// Exact for sets of up to twelve songs, local search beyond.
    /// - Parameter energies: each song's `energy`, so the set builds: see
    ///   `lostEnergyPenalty`.
    static func order(_ costs: [[Double]], washOuts: [[Bool]]? = nil, energies: [Double]? = nil, shakes: Int? = nil) -> [Int] {
        let n = costs.count
        // Two songs have an order too: whichever leads into the other best.
        guard n > 1 else { return Array(0..<n) }
        if n <= 12 { return exact(costs, washOuts, energies) }
        return search(costs, washOuts, energies, shakes: shakes)
    }

    /// `order` for a set too long to try every order of: the best of a
    /// greedy chain from every song, each tidied by moving single songs;
    /// then, from there, shaken and settled again and again (runs of songs
    /// moved or turned round as one, and a few runs swapped at random to
    /// get out of an order no single move improves), keeping what's
    /// better. Always the same for the same songs.
    static func search(_ costs: [[Double]], _ washOuts: [[Bool]]? = nil, _ energies: [Double]? = nil,
                       shakes: Int? = nil) -> [Int] {
        let n = costs.count
        guard n > 2 else { return Array(0..<n) }
        var best = Array(0..<n), bestCost = Double.infinity
        for start in 0..<n {
            var path = greedy(costs, from: start)
            improve(&path, costs, washOuts, energies, blocks: 1)
            let c = total(path, costs, washOuts, energies)
            if c < bestCost { bestCost = c; best = path }
        }
        // Then runs of two and three songs that belong together, moved as one.
        improve(&best, costs, washOuts, energies, blocks: 3)
        bestCost = settle(&best, costs, washOuts, energies)
        guard n >= 8 else { return best }
        var random = SplitMix(state: 0x9E37_79B9_7F4A_7C15)
        // About as much work whatever the set's length (each settle costs
        // ~n³): ~500 rounds at 68 songs, a few seconds, where more search
        // stopped finding anything better (2000 and 10,000 gave the same
        // order; the 86 used before left two more cuts in).
        for _ in 0..<(shakes ?? max(60, min(2000, 160_000_000 / (n * n * n)))) {
            // Three cuts, the two middle runs swapped: a change no move of
            // one run undoes in one step.
            var cuts = (0..<3).map { _ in 1 + Int(random.next() % UInt64(n - 1)) }.sorted()
            guard cuts[0] < cuts[1], cuts[1] < cuts[2] else { continue }
            if cuts[2] == n { cuts[2] = n - 1; guard cuts[1] < cuts[2] else { continue } }
            var path = Array(best[..<cuts[0]]) + best[cuts[1]..<cuts[2]] + best[cuts[0]..<cuts[1]] + best[cuts[2]...]
            let cost = settle(&path, costs, washOuts, energies)
            if cost < bestCost - 1e-9 { (best, bestCost) = (path, cost) }
        }
        return best
    }

    /// A small, fixed random sequence (the same set always gets the same
    /// order).
    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Takes the best single move there is (a run of up to three songs
    /// moved elsewhere, either way round, or any run turned round where
    /// it is) until none improves the order; returns its cost.
    private static func settle(_ path: inout [Int], _ costs: [[Double]], _ washOuts: [[Bool]]?,
                               _ energies: [Double]?) -> Double {
        let n = path.count
        var current = total(path, costs, washOuts, energies)
        // Every move, priced on all cores: (block start, length; 0 = turn
        // round the run from `i` to `j`), then the best taken, ties to the
        // first in this order (the same set always gets the same order).
        struct Move { let i: Int, length: Int, j: Int, reversed: Bool }
        var moves: [Move] = []
        for length in 1...min(3, n - 1) {
            for i in 0...(n - length) {
                for j in 0...(n - length) where j != i {
                    moves.append(Move(i: i, length: length, j: j, reversed: false))
                    if length > 1 { moves.append(Move(i: i, length: length, j: j, reversed: true)) }
                }
            }
        }
        for i in 0..<(n - 1) { for j in (i + 1)..<n { moves.append(Move(i: i, length: 0, j: j, reversed: true)) } }
        /// The song at `p` once `m` is made on `base`, without making it.
        @inline(__always) func song(_ p: Int, _ m: Move, _ base: UnsafeBufferPointer<Int>) -> Int {
            if m.length == 0 { return p >= m.i && p <= m.j ? base[m.i + m.j - p] : base[p] }
            func rest(_ q: Int) -> Int { q < m.i ? base[q] : base[q + m.length] }
            if p < m.j { return rest(p) }
            if p < m.j + m.length { let k = p - m.j; return base[m.i + (m.reversed ? m.length - 1 - k : k)] }
            return rest(p - m.length)
        }
        func apply(_ m: Move, to path: [Int]) -> [Int] {
            var p = path
            if m.length == 0 { p[m.i...m.j].reverse(); return p }
            let block = Array(p[m.i..<(m.i + m.length)])
            p.removeSubrange(m.i..<(m.i + m.length))
            p.insert(contentsOf: m.reversed ? block.reversed() : block, at: m.j)
            return p
        }
        let chunks = max(1, min(moves.count, ProcessInfo.processInfo.activeProcessorCount * 4))
        while true {
            var found = [(cost: Double, index: Int)](repeating: (.infinity, -1), count: chunks)
            let base = path
            base.withUnsafeBufferPointer { base in
                found.withUnsafeMutableBufferPointer { out in
                    let out = out
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        var best = (cost: Double.infinity, index: -1)
                        var k = c * moves.count / chunks
                        let end = (c + 1) * moves.count / chunks
                        while k < end {
                            let m = moves[k]
                            let cost = total(count: n, costs, washOuts, energies) { song($0, m, base) }
                            if cost < best.cost { best = (cost, k) }
                            k += 1
                        }
                        out[c] = best
                    }
                }
            }
            guard let best = found.filter({ $0.index >= 0 }).min(by: { ($0.cost, $0.index) < ($1.cost, $1.index) }),
                  best.cost < current - 1e-9 else { return current }
            (path, current) = (apply(moves[best.index], to: path), best.cost)
        }
    }

    /// Songs added to a set that already has its order go where they fit
    /// best, each in turn; the songs already there stay as they are (a
    /// set that reshuffles from top to bottom for one new song is no set
    /// to get to know). `path` and `new` are indices into `costs`.
    static func insert(_ new: [Int], into path: [Int], _ costs: [[Double]], washOuts: [[Bool]]? = nil,
                       energies: [Double]? = nil) -> [Int] {
        var path = path, left = new
        while !left.isEmpty {
            var best: (cost: Double, song: Int, at: Int)?
            for (k, song) in left.enumerated() {
                for at in 0...path.count {
                    var p = path
                    p.insert(song, at: at)
                    let c = total(p, costs, washOuts, energies)
                    if c < best?.cost ?? .infinity { best = (c, k, at) }
                }
            }
            guard let best else { break }
            path.insert(left.remove(at: best.song), at: best.at)
        }
        return path
    }

    static func total(_ path: [Int], _ costs: [[Double]], _ washOuts: [[Bool]]? = nil,
                      _ energies: [Double]? = nil) -> Double {
        path.withUnsafeBufferPointer { p in total(count: p.count, costs, washOuts, energies) { p[$0] } }
    }

    /// `total` of the order whose song at each place `song` gives.
    @inline(__always)
    static func total(count n: Int, _ costs: [[Double]], _ washOuts: [[Bool]]?, _ energies: [Double]?,
                      song: (Int) -> Int) -> Double {
        guard n > 0 else { return 0 }
        var sum = 0.0, peak = 0.0, washOutCount = 0, previousWashOut = false
        var last = song(0)
        if let energies { peak = energies[last] }
        for k in 1..<max(1, n) {
            let next = song(k)
            sum += costs[last][next]
            if let energies {
                peak = max(peak, energies[next])
                sum += lostEnergyPenalty * (peak - energies[next])
            }
            if let washOuts {
                let w = washOuts[last][next]
                if w {
                    washOutCount += 1
                    if previousWashOut { sum += washOutPairPenalty }
                }
                previousWashOut = w
            }
            last = next
        }
        if washOuts != nil, n > 2 { sum += extraWashOutPenalty * Double(max(0, washOutCount - 1)) }
        return sum
    }

    /// Shortest Hamiltonian path over the full cost of `total`, by dynamic
    /// programming over (songs played, last song, Wash Outs so far): what
    /// a path has cost depends on no more than that (its hardest song so
    /// far is that of the songs played).
    private static func exact(_ costs: [[Double]], _ washOuts: [[Bool]]?, _ energies: [Double]?) -> [Int] {
        let n = costs.count, full = 1 << n
        // 0: no Wash Out yet; 1: one before, the last transition wasn't; 2: the last transition was one.
        let flags = 3
        var peak = [Double](repeating: 0, count: full)
        if let energies {
            for mask in 1..<full {
                let low = mask.trailingZeroBitCount
                peak[mask] = max(peak[mask & (mask - 1)], energies[low])
            }
        }
        func index(_ mask: Int, _ last: Int, _ flag: Int) -> Int { (mask * n + last) * flags + flag }
        var dp = [Double](repeating: .infinity, count: full * n * flags)
        var parent = [Int32](repeating: -1, count: full * n * flags)
        for i in 0..<n { dp[index(1 << i, i, 0)] = 0 }
        for mask in 1..<full {
            for last in 0..<n where mask & (1 << last) != 0 {
                for flag in 0..<flags {
                    let here = dp[index(mask, last, flag)]
                    guard here < .infinity else { continue }
                    for next in 0..<n where mask & (1 << next) == 0 {
                        let m = mask | (1 << next)
                        var c = here + costs[last][next]
                        var f = flag == 0 ? 0 : 1
                        if washOuts?[last][next] == true {
                            if flag != 0 { c += extraWashOutPenalty }
                            if flag == 2 { c += washOutPairPenalty }
                            f = 2
                        }
                        if let energies { c += lostEnergyPenalty * (peak[m] - energies[next]) }
                        if c < dp[index(m, next, f)] {
                            dp[index(m, next, f)] = c
                            parent[index(m, next, f)] = Int32(last * flags + flag)
                        }
                    }
                }
            }
        }
        var best = (last: 0, flag: 0, cost: Double.infinity)
        for last in 0..<n {
            for flag in 0..<flags where dp[index(full - 1, last, flag)] < best.cost {
                best = (last, flag, dp[index(full - 1, last, flag)])
            }
        }
        var (last, flag, mask) = (best.last, best.flag, full - 1)
        var path = [last]
        while true {
            let p = parent[index(mask, last, flag)]
            guard p >= 0 else { break }
            mask &= ~(1 << last)
            (last, flag) = (Int(p) / flags, Int(p) % flags)
            path.append(last)
        }
        return path.reversed()
    }

    private static func greedy(_ costs: [[Double]], from start: Int) -> [Int] {
        var path = [start]
        var left = Set(0..<costs.count).subtracting([start])
        // Ties go to the lower index: a Set's order changes from launch to
        // launch, and the same songs should always give the same set.
        while let next = left.sorted().min(by: { costs[path.last!][$0] < costs[path.last!][$1] }) {
            path.append(next)
            left.remove(next)
        }
        return path
    }

    /// Or-opt: move single songs, or runs of up to `blocks` songs, to a
    /// better spot until nothing improves.
    private static func improve(_ path: inout [Int], _ costs: [[Double]], _ washOuts: [[Bool]]? = nil,
                                _ energies: [Double]? = nil, blocks: Int = 1) {
        var improved = true
        while improved {
            improved = false
            let current = total(path, costs, washOuts, energies)
            outer: for length in 1...max(1, blocks) where length < path.count {
                for i in 0...(path.count - length) {
                    var rest = path
                    let block = Array(rest[i..<(i + length)])
                    rest.removeSubrange(i..<(i + length))
                    for j in 0...rest.count where j != i {
                        var p = rest
                        p.insert(contentsOf: block, at: j)
                        if total(p, costs, washOuts, energies) < current - 1e-9 {
                            path = p
                            improved = true
                            break outer
                        }
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
    /// The automation was drawn by hand and plays as it is. Otherwise only
    /// the spot, preset, length and key were chosen: the set writes the
    /// automation for them itself, from what it hears there (grooves,
    /// notes, vocal lines), exactly as it does for its own plans.
    var byHand = true
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
        byHand = try c.decodeIfPresent(Bool.self, forKey: .byHand) ?? true
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
        /// Its automation and rolls from its way in alone, as written
        /// before its way out was added: what's reused of it when the set
        /// is built again and its way in hasn't changed.
        var incoming: (envelopes: [StemKind: [Envelope]], rolls: [Roll]) = ([:], [])

        var stems: [StemKind: StemAudio] { matched?.stems ?? loaded.stems }

        /// Master time of a moment in the track's own (unstretched) clock
        /// (for a skipped moment: where it would have been).
        func master(_ seconds: Double) -> Double {
            // (The jump lies where the track plays at its own tempo: what
            // it leaves out is as long in the set as in the song.)
            let skipped = skip.map { seconds >= $0.to ? $0.to - $0.from : 0 } ?? 0
            return offset + map.output(seconds * AudioIO.sampleRate) / AudioIO.sampleRate - skipped
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
        var from: Int, to: Int
        let plan: PairPlan
        /// What was actually used: the plan's, or the hand edit's.
        let edit: TransitionEdit
        let isEdited: Bool
        /// Master seconds.
        var start: Double, end: Double
        /// Master seconds at which the incoming song is back at its own tempo.
        var settled: Double
        let barSeconds: Double
        /// Master seconds minus A's own seconds around the transition (A is
        /// at its own tempo there), i.e. set time minus editor time.
        var delta: Double
        /// Bars of A the transition may start on: not before A is back at its
        /// own tempo.
        let entryRange: ClosedRange<Int>
        /// Where the transition itself begins: B's first bar, or where a
        /// Wash Out's bridge starts taking A's beat away.
        var begins: Double {
            start - (edit.preset == .echoOut ? Double(max(1, min(8, edit.bars))) : 0) * barSeconds
        }
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
        /// B's hats alone layered under A's beat (see `TransitionBuilder.hats`).
        var hatsLayered = false
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
        /// How B's vocal came in: "breath" (before a line), "word" (in the
        /// gap before a word), "bar" (opened on the downbeat, singing),
        /// "grid" (on the bar, nothing sounding); nil if automatic phrasing
        /// wasn't used.
        var vocalInKind: String?
        /// What A's vocal left on: "line" (a breath between lines), "word"
        /// (a gap between words), "bar" (cut on the downbeat, singing); nil
        /// if automatic phrasing wasn't used.
        var vocalOutKind: String?
        /// Bars of A a club edit left out before this transition.
        var skippedBars = 0
        /// The melodies were heard to clash, so they were swapped rather
        /// than layered.
        var melodiesClash = false
        /// dB A's drums and melody made way for B's (EQ).
        var room = 0.0
        /// Bars of A's beat that loop under the blend (0: none).
        var loopBars = 0
        /// What it was built from and what it wrote on the outgoing song:
        /// built again from the same, it's taken over as it is, moved to
        /// where it then plays (see `SetBuilder.build(previous:)`).
        var made: Made?

        struct Made {
            let key: SetBuilder.BuildKey
            let outgoing: [StemKind: [Envelope]]
            let outgoingRolls: [Roll]
        }

        /// The same transition `seconds` later in the set.
        func moved(by seconds: Double, from: Int, to: Int) -> Transition {
            var t = self
            (t.from, t.to) = (from, to)
            t.start += seconds
            t.end += seconds
            t.settled += seconds
            t.delta += seconds
            t.vocalOut = vocalOut.map { $0 + seconds }
            t.vocalIn = vocalIn.map { $0 + seconds }
            t.dropAt = dropAt.map { $0 + seconds }
            t.made = made.map {
                Made(key: $0.key, outgoing: $0.outgoing.mapValues { $0.map { $0.shifted(by: seconds) } },
                     outgoingRolls: $0.outgoingRolls.map { $0.shifted(by: seconds) })
            }
            return t
        }
    }

    var tracks: [Track]
    var transitions: [Transition]
    var length: Double
    /// What building it learnt from the audio about pairs whose plan it
    /// didn't bear out (see `SetBuilder.build`): carried into the next
    /// build, which then plans them right first time.
    var learned = Learned()

    struct Learned {
        var unlocked: Set<PairKey> = [], clashed: Set<PairKey> = [], locked: Set<PairKey> = []
    }

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
    ///   - split: where the drums change hands (master seconds; nil:
    ///     half-way). Before it B's tops layer under A's kit, after it A's
    ///     may linger under B's, and each side is judged on its own.
    static func nudge(a: StemAudio, aOffset: Double, b: StemAudio, bOffset: Double,
                      from: Double, to: Double, split: Double? = nil) -> Result {
        let perSecond = AudioIO.sampleRate / Double(onsetHop)
        let pad = 2 * maxNudge
        let bFrom = from - bOffset - pad
        guard let ea = onsets(a, from: from - aOffset, to: to - aOffset),
              let eb = onsets(b, from: bFrom, to: to - bOffset + pad) else { return Result(nudge: 0, lock: 1) }
        return nudge(ea: ea, eb: eb, from: from, to: to, split: split, scale: perSecond, shift: -(bOffset + bFrom) * perSecond)
    }

    private final class SongAttacks: @unchecked Sendable {
        let lock = NSLock()
        var songs: [URL: [Float]?] = [:]
    }
    private static let songAttacks = SongAttacks()

    /// Each song's drum hits (`attacks(of:)`), measured once per song and
    /// app run, all cores at once.
    static func attacks(of songs: [TrackProcessor.Loaded]) -> [[Float]?] {
        var out = [[Float]?](repeating: nil, count: songs.count)
        out.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: songs.count) { i in
                let key = songs[i].directory
                songAttacks.lock.lock()
                let known = songAttacks.songs[key]
                songAttacks.lock.unlock()
                if let known { out[i] = known; return }
                let measured = songs[i].stems[.drums].flatMap(attacks(of:))
                songAttacks.lock.lock()
                songAttacks.songs[key] = .some(measured)
                songAttacks.lock.unlock()
                out[i] = measured
            }
        }
        return out
    }

    /// Every drum attack of a song (see `attacks`), frame k at `k ·
    /// onsetHop` samples of the stem; nil if it has none.
    static func attacks(of drums: StemAudio) -> [Float]? {
        var mono = [Float](repeating: 0, count: drums.count)
        var half: Float = 0.5
        vDSP_vasm(drums.left.pointer, 1, drums.right.pointer, 1, &half, &mono, 1, vDSP_Length(drums.count))
        return attacks(mono)
    }

    /// `nudge` before B has been rendered at A's tempo, from the two songs'
    /// own attacks: B's hits keep their shape when it's stretched and land
    /// where its time map puts them, so they can be placed without the
    /// audio. What ordering and planning go by; the builder still measures
    /// the rendition that plays.
    /// - Parameters:
    ///   - a, b: `attacks(of:)` of each song's drums.
    ///   - from, to, split: on A's own clock (seconds).
    ///   - bOffset: A's clock at which B's first frame plays.
    ///   - rate: B's rate through the blend.
    ///   - loop: A's beat loops from `from` on (seconds before `from` its
    ///     looped stretch starts, and how long that is): its hits there
    ///     are those of the loop, over and over.
    static func predicted(a: [Float], b: [Float], from: Double, to: Double, split: Double?, bOffset: Double,
                          rate: Double, loop: (back: Double, length: Double)? = nil) -> Result {
        let perSecond = AudioIO.sampleRate / Double(onsetHop)
        if let loop {
            let source = Int((from - loop.back) * perSecond), length = Int(loop.length * perSecond)
            let count = Int((to - from) * perSecond)
            guard source >= 0, length > 0, source + length <= a.count, Double(count) > perSecond else {
                return Result(nudge: 0, lock: 1)
            }
            let looped = (0..<count).map { a[source + $0 % length] }
            return nudge(ea: looped, eb: b, from: from, to: to, split: split, scale: rate * perSecond,
                         shift: -bOffset * rate * perSecond)
        }
        let first = max(0, Int(from * perSecond)), last = min(a.count, Int(to * perSecond))
        guard Double(last - first) > perSecond else { return Result(nudge: 0, lock: 1) }
        // B's own time at A's clock t is (t − bOffset) · rate.
        return nudge(ea: Array(a[first..<last]), eb: b, from: Double(first) / perSecond, to: to, split: split,
                     scale: rate * perSecond, shift: -bOffset * rate * perSecond)
    }

    /// `nudge` on the attacks themselves: `ea`'s frame 0 at master `from`,
    /// and master time t at frame `t · scale + shift` of `eb`.
    private static func nudge(ea: [Float], eb: [Float], from: Double, to: Double, split: Double?, scale: Double,
                              shift: Double) -> Result {
        let sr = AudioIO.sampleRate, hop = Double(onsetHop)
        func score(_ lag: Double, _ frames: Range<Int>) -> Double {
            var sum = 0.0
            for i in frames where ea[i] > 0 {
                let master = from + Double(i) * hop / sr
                let j = (master - lag) * scale + shift
                let k = Int(j)
                guard j >= 0, k + 1 < eb.count else { continue }
                let f = j - Double(k)
                sum += Double(ea[i]) * (Double(eb[k]) * (1 - f) + Double(eb[k + 1]) * f)
            }
            return sum
        }
        // Every two bars on their own: how well the two patterns' hits land
        // together at each lag. A real offset shows up the same in most
        // windows. Each half of the blend is judged on its own: before the
        // swap it's A's kit under B's tops, after it the other way round,
        // and grooves can sit differently.
        let window = max(1, Int((to - from) / 8 * sr / hop))
        let frame = hop / sr, reach = Int((maxNudge / frame).rounded())
        /// A window's score at every lag from -reach to reach frames, as a
        /// share of its best, and the lag (seconds) its hits land together
        /// at.
        typealias Curve = [Double]
        typealias Window = (curve: Curve, lag: Double)
        /// Where a curve peaks (seconds). Whole onset frames (a
        /// millisecond) first, then the peak's own shape through the best
        /// and its neighbours: hits are sharp, so it's a V (two lines of
        /// equal slope), not a parabola, which would pull the offset
        /// towards the nearest frame.
        func peak(_ scores: [Double]) -> Double {
            let k = scores.indices.max { scores[$0] < scores[$1] }!
            var lag = Double(k - reach)
            if k > 0, k < scores.count - 1 {
                let left = scores[k - 1], right = scores[k + 1]
                let fall = scores[k] - min(left, right)
                if fall > 0 { lag += 0.5 * (right - left) / fall }
            }
            return lag * frame
        }
        // Only a window whose hits line up clearly better at one lag than
        // at any other says anything about the groove. In a sparse intro (a
        // few hats, a lone snare against a full kit) several lags far
        // apart score about the same and the best one is noise: counted
        // as votes, such bars called beats that sit together perfectly
        // "won't lock" (measured: their best lag beat the one the full
        // bars lock at by 2–18 %). Nor is a best lag at the edge of the
        // search a peak: the hits meet somewhere past it, if at all.
        //
        // Two kits can also meet at two lags close together: the kicks at
        // one, the claps at another (one song's clap sits a little behind
        // its kick, the other's on it). Neither is the lag: at either, the
        // other pair flams. Where everything that scores nearly as well
        // as the best lies within 16 ms, the window's lag is the middle
        // of the best of that, where every pair of hits is within 8 ms:
        // under what's heard as a flam. (Such windows used to have no say, B stayed
        // where its grid put it, and the claps flammed by 19 ms.)
        func curves(_ frames: Range<Int>) -> [Window] {
            var out: [Window] = []
            for w in stride(from: frames.lowerBound, to: frames.upperBound - window + 1, by: window) {
                let f = w..<(w + window)
                guard ea[f].reduce(0, +) > 0 else { continue }
                let scores = (-reach...reach).map { score(Double($0) * frame, f) }
                let k = scores.indices.max { scores[$0] < scores[$1] }!
                let best = scores[k], mean = scores.reduce(0, +) / Double(scores.count)
                guard best > 0, best > 1.25 * mean, k > 0, k < scores.count - 1 else { continue }
                let curve = scores.map { $0 / best }
                // 12 ms: the far side of a hit's own width and of the
                // little a groove's bars differ among themselves.
                let strong = scores.indices.filter { scores[$0] >= 0.8 * best }
                if !strong.contains(where: { abs($0 - k) > 12 }) {
                    out.append((curve, peak(scores)))
                } else if let first = strong.first, let last = strong.last, last - first <= 16 {
                    // Between the lags that are all but as good as the
                    // best (a second pair of hits only four fifths as
                    // strong doesn't pull the lag off the first).
                    let top = scores.indices.filter { scores[$0] >= 0.9 * best }
                    out.append((curve, Double(top.first! + top.last! - 2 * reach) / 2 * frame))
                }
            }
            return out
        }
        /// A window sits at an offset if its hits land within 8 ms of it
        /// (a flam is heard from about 10).
        func sits(_ window: Window, at lag: Double) -> Bool { abs(window.lag - lag) <= 0.008 }
        /// The offset a clear majority of the windows sit at; nil if there
        /// are too few to say or they don't agree. Where they land
        /// together best taken as one (each counting the same), then the
        /// middle of those that sit there: bars at -1 and at 8 ms are all
        /// within 5 of 4, and 9 off each other's.
        func consensus(_ windows: [Window]) -> Double? {
            guard windows.count >= 2 else { return nil }
            var sum = [Double](repeating: 0, count: 2 * reach + 1)
            for w in windows { for k in sum.indices { sum[k] += w.curve[k] } }
            let common = peak(sum)
            let near = windows.map(\.lag).filter { abs($0 - common) <= 0.008 }
            if let low = near.min(), let high = near.max() {
                let lag = (low + high) / 2
                if 4 * windows.filter({ sits($0, at: lag) }).count >= 3 * windows.count { return lag }
            }
            // The windows can also sit in two groups a little apart (bars at
            // 14 and at 24 ms: the peak of them all is one group's, and the
            // other is 10 off it), all of them within 8 ms of the middle:
            // the most windows that fit a span of 16 ms, if that's a clear
            // majority, and the middle of that span.
            let lags = windows.map(\.lag).sorted()
            var best: (count: Int, lag: Double)?
            for (i, low) in lags.enumerated() {
                let group = lags[i...].prefix { $0 - low <= 0.016 }
                if group.count > best?.count ?? 0 { best = (group.count, (low + group.last!) / 2) }
            }
            guard let best, 4 * best.count >= 3 * windows.count else { return nil }
            return best.lag
        }
        let half = split.map { min(ea.count, max(0, Int((($0 - from) * sr / hop).rounded()))) } ?? ea.count / 2
        let first = curves(0..<half), second = curves(half..<ea.count)
        // One nudge moves all of B, and the two halves can each sit at their
        // own offset (B's intro hats against its main kit): their average
        // sits under neither, which called beats that lock clearly (26 ms
        // before the swap, 0 after) a flam throughout. Before the swap is
        // where both kits play for bars, so it decides; A's drums linger
        // after it only if they sit at the same nudge there.
        // A single window is too little to move B by: the two grids, each
        // fitted to its song's hits over the whole song, are better
        // evidence than two bars (one window's 31 ms put Safari 39 ms off
        // Good Feeling, whose grids met within 8).
        let all = first + second
        let nudge = consensus(first) ?? consensus(second) ?? 0
        // Before the swap it's A's kit under B's tops, after it the other
        // way round: each half can groove or not on its own.
        func lock(_ windows: [Window]) -> Double {
            windows.count < 2 ? 1 : Double(windows.filter { sits($0, at: nudge) }.count) / Double(windows.count)
        }
        // How much of the blend sits once nudged. Too few clear windows to
        // judge: the two beat grids (tracked, then nudged) are all there
        // is, and they agree by construction.
        return Result(nudge: abs(nudge) >= 0.003 ? nudge : 0, lock: all.count < 3 ? 1 : lock(all), lags: all.map(\.lag),
                      lockBefore: lock(first), lockAfter: lock(second), votesBefore: first.count, votesAfter: second.count)
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
        /// Windows before and after the swap that clearly had a lag.
        var votesBefore = 0, votesAfter = 0
        /// B's drums, layered under A's as the blend would play them,
        /// were heard to flam (see `SetBuilder`): they come in whole on
        /// the switch instead.
        var topsSplit = false
        /// The same of A's drums playing on under B's after the swap:
        /// they stop on it instead.
        var lingerSplit = false
        /// Two patterns that differ (a dancehall riddim over a straight
        /// beat) leave some windows without a clear lag, and those don't
        /// vote. Of the windows that do, a clear majority has to sit
        /// together: half the blend flamming is still a flam. B's tops
        /// layer under A's kit if the first half grooves.
        var grooves: Bool { lockBefore >= 0.75 && !topsSplit }
        /// A's drums play on under B's after the swap.
        var groovesAfter: Bool { grooves && lockAfter >= 0.75 && !lingerSplit }
        /// For a lock predicted from the songs' own hits rather than
        /// measured on the rendition: by a clear margin, since the rendition
        /// can still smear the soft hits a bare majority rests on. And on
        /// evidence: windows that show it before the swap, or, where B's
        /// tops are too sparse there to show anything (and so to flam),
        /// after it, where both full kits prove the two grids sit as one.
        /// With neither, the lock is only assumed.
        var clearlyGrooves: Bool {
            votesBefore >= 2 ? lockBefore > 0.8 : votesAfter >= 2 && lockAfter > 0.8
        }
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

    /// How far apart the hits of two drum parts land where both play (seconds
    /// B is late by, one value per stretch of `window` seconds in which
    /// the two clearly hit together at some lag), from what's heard: the
    /// two parts rendered as the mix plays them, frame 0 of each at the
    /// same moment. Anything past about 10 ms is heard as a flam.
    static func heardLags(a: [Float], b: [Float], window seconds: Double) -> [Double] {
        guard let ea = attacks(a), let eb = attacks(b) else { return [] }
        let fps = AudioIO.sampleRate / Double(onsetHop), reach = 40
        let window = Int(seconds * fps)
        guard window > 4 * reach else { return [] }
        var out: [Double] = []
        var w = 0
        while w + window <= min(ea.count, eb.count) {
            defer { w += window }
            let ra = Array(ea[w..<(w + window)]), rb = Array(eb[w..<(w + window)])
            let sa = ra.reduce(0, +), sb = rb.reduce(0, +)
            // Both kits really there, not one side's bleed or echo.
            guard sa > 0, sb > 0, min(sa, sb) / max(sa, sb) > 0.2 else { continue }
            let scores = (-reach...reach).map { lag -> Float in
                var dot: Float = 0
                for i in reach..<(window - reach) { dot += ra[i] * rb[i + lag] }
                return dot
            }
            let k = scores.indices.max { scores[$0] < scores[$1] }!
            let mean = scores.reduce(0, +) / Float(scores.count)
            // Playing at the same time and hitting together near some lag
            // (normalised correlation): a window with A's drums in one half
            // and B's in the other (a hard swap) has nothing that could
            // flam, and without a clear common lag it's two patterns, not
            // a flam.
            let norm = (ra.reduce(0) { $0 + $1 * $1 } * rb.reduce(0) { $0 + $1 * $1 }).squareRoot()
            guard norm > 0, scores[k] / norm > 0.2, scores[k] > 1.25 * mean else { continue }
            var lag = Double(k - reach)
            if k > 0, k < scores.count - 1 {
                let fall = scores[k] - min(scores[k - 1], scores[k + 1])
                if fall > 0 { lag += Double(0.5 * (scores[k + 1] - scores[k - 1]) / fall) }
            }
            out.append(lag / fps)
        }
        return out
    }

    /// The flam typical of those lags (seconds): in some windows the two
    /// patterns simply differ and meet anywhere.
    static func flam(_ lags: [Double]) -> Double {
        lags.isEmpty ? 0 : lags.map(abs).sorted()[lags.count / 2]
    }

    /// Whether two kits heard together flam: typically more than 10 ms
    /// apart, or clearly apart (20 ms) for two bars anywhere. (Two bars of
    /// a 28 ms flam between two that sit are still heard: the median
    /// called that pair locked.)
    static func flams(_ lags: [Double]) -> Bool {
        !lags.isEmpty && (flam(lags) > 0.010 || lags.contains { abs($0) > 0.020 })
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
        // `mono` is left plus right: half of it is the level per channel.
        guard 20 * log10(max(rms / 2, 1e-9)) > heardFloor else { return nil }
        return KeyDetector.computeChroma(samples: mono, sampleRate: sr).map(Float.init)
    }

    /// A part under this level (dB, per channel) has no notes to speak of:
    /// what's left of a melody in a drums-only intro is separation bleed,
    /// and its pitch classes are noise. Compared note for note it would
    /// count as much as the other song's full melody.
    static let heardFloor: Float = -50

    /// The two sit together: B's notes lie in A's scale (the diatonic
    /// scale A's notes fit best) about as well as in the scale that suits B
    /// best. A different chord of the same scale fits; notes a semitone or
    /// a tritone off don't.
    /// - Parameter tolerance: the most the two may `clash`.
    static func fits(_ a: [Float], _ b: [Float], tolerance: Float = fitTolerance) -> Bool {
        clash(a, b) <= tolerance
    }

    /// How much less the two together sit in one diatonic scale than each
    /// does on its own (0: they share one; whole scales a fifth apart
    /// ≈ 0.07, a whole tone ≈ 0.13, a tritone or semitone ≈ 0.3; real
    /// stretches of music use fewer notes and come out lower, see
    /// `clashTolerance`). Heard as one sound, which is what a blend is,
    /// rather than B measured against A's best guess of a scale (which let
    /// almost anything through).
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

    /// How rough the two sound together, note against note: how much of
    /// A's notes and B's (each as a share of its own) lie a semitone
    /// apart, or a tritone (counted for half), whatever scale either is
    /// in. `clash` asks whether the two share a scale, which a song in no
    /// plain major or minor (a Phrygian riff, a blues) answers wrongly,
    /// and which two songs a semitone apart can pass on a stretch that
    /// uses few notes.
    ///
    /// Measured on 80 songs (HarmonyProbe): eight bars of one song's melody
    /// and bass line against eight of another's melody, moved into its
    /// key and then by 0 to 11 semitones. Same key: the middle one reads
    /// 0.175, nine in ten under 0.20. A semitone or a tritone off: the
    /// middle one 0.24, nine in ten over 0.21. At `roughTolerance`, 3 % of
    /// each are on the wrong side; `clash` at its own best threshold
    /// misses 11 % of those clashes, and at the tolerance a blend of
    /// neighbouring keys is given, about a third.
    static func roughness(_ a: [Float], _ b: [Float]) -> Float {
        let sa = max(1e-6, a.reduce(0, +)), sb = max(1e-6, b.reduce(0, +))
        var rough: Float = 0
        for p in 0..<12 {
            let x = a[p] / sa
            rough += x * (b[(p + 1) % 12] + b[(p + 11) % 12]) / sb + 0.5 * x * b[(p + 6) % 12] / sb
        }
        return rough
    }

    /// Pitch classes moved up by `semitones`.
    static func transposed(_ chroma: [Float], by semitones: Int) -> [Float] {
        (0..<12).map { chroma[(($0 - semitones) % 12 + 12) % 12] }
    }

    /// `clash` of what two sets of stems play from master `from` to `to`;
    /// nil unless both have notes there.
    static func clash(_ a: [StemAudio], aOffset: Double, _ b: [StemAudio], bOffset: Double, from: Double,
                      to: Double) -> Float? {
        guard let ca = chroma(a, offset: aOffset, from: from, to: to),
              let cb = chroma(b, offset: bOffset, from: from, to: to) else { return nil }
        return clash(ca, cb)
    }

    /// `fits`, when both sides have notes to compare; nothing to clash
    /// with counts as fitting.
    static func fits(_ a: [StemAudio], aOffset: Double, _ b: [StemAudio], bOffset: Double, from: Double, to: Double,
                     tolerance: Float = fitTolerance) -> Bool {
        clash(a, aOffset: aOffset, b, bOffset: bOffset, from: from, to: to).map { $0 <= tolerance } ?? true
    }

    /// Where the songs' keys sit together (the same scale or a fifth
    /// apart), only a clear clash heard in the notes that overlap breaks up
    /// a blend; where they don't, the notes have to show clearly that this
    /// stretch fits all the same.
    /// Measured on songs with published keys, stretches of 4 to 16 s of one
    /// song's melody and bass line against another's melody: in fitting
    /// keys 9 in 10 stay under 0.02; three fifths or more apart the middle
    /// one is at 0.07, and 1 in 10 under -0.03 (two bars on notes both keys
    /// share). With these two, no fitting stretch was called a clash and
    /// about 4 in 5 of the clashing ones were (1 in 25 before).
    static let clashTolerance: Float = 0.07
    static let keysClashTolerance: Float = 0.01
    /// How badly the notes of a stretch may `clash` before two songs in
    /// these keys swap melodies there instead of layering them. Three
    /// fifths or more apart, the keys are believed whatever the stretch
    /// reads: a stretch of two such songs reads as fitting 1 time in 5 (a
    /// bar or two on notes both keys share), far more often than both keys
    /// are misread, and the next bar brings the notes they don't share.
    static func tolerance(_ a: MusicalKey, _ b: MusicalKey) -> Float {
        let d = abs(a.camelotNumber - b.camelotNumber)
        switch min(d, 12 - d) {
        case 0, 1: return clashTolerance
        case 2: return keysClashTolerance
        default: return -.infinity
        }
    }

    /// Past this `roughness`, two songs' notes grate: their melodies swap
    /// rather than layer, whatever their keys were read as.
    static let roughTolerance: Float = 0.206

    /// `roughness` of what two sets of stems play from master `from` to
    /// `to`; nil unless both have notes there.
    static func roughness(_ a: [StemAudio], aOffset: Double, _ b: [StemAudio], bOffset: Double, from: Double,
                          to: Double) -> Float? {
        guard let ca = chroma(a, offset: aOffset, from: from, to: to),
              let cb = chroma(b, offset: bOffset, from: from, to: to) else { return nil }
        return roughness(ca, cb)
    }

    /// A voice over the other song's chords (a mashup, an a cappella) has
    /// to sit in them, not merely avoid a clear clash.
    static let fitTolerance: Float = 0.04
    /// B is pitched only where its notes clash worse than this (see
    /// `PairPlan.make`): a song off its own key is noticed, so layering is
    /// given up long before that.
    static let shiftTolerance: Float = 0.10
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

/// Where vocal lines start and stop, to the sixteenth. A DJ lets the new
/// vocal in on the breath before its next line and takes the old one out on
/// the breath after its last, never mid-word; bars are too coarse for that,
/// and so are beats: a line that ends on the "and" of four and the next
/// that starts on the one leave no beat of the grid silent, and a voice was
/// then faded out through the sentence it was singing.
enum VocalPhrasing {
    /// What a voice is cut on.
    enum Cut: String {
        /// A breath between two lines: half a beat or more of silence.
        case line
        /// A gap between two words, a sixteenth long: the sentence isn't
        /// over, but no word is cut in two (and taken out here, its last
        /// word rings on in the echo).
        case word
    }

    /// Sixteenths to a bar.
    static let slots = 16

    /// Where to cut a voice in or out, as near to its target as the voice
    /// allows, in sixteenths from the target (slot k runs from k to k + 1).
    /// Taken out, the cut has to fall in a silent sixteenth; let in, the
    /// sixteenth before it has to be silent (whatever is sung from there on
    /// starts there). A voice that never falls silent (long notes, a
    /// reverb that fills the gaps) still has words: where a sixteenth is
    /// 10 dB under the one before, a word has died away, and where it is
    /// 10 dB over it, one starts. The target is where the voice's part ends
    /// or begins (a phrase boundary of its song, as placement chose it), so
    /// the cut stays with it: a gap between words right there beats a
    /// breath a beat away, which is a line into the next part, or one short
    /// of this one's end. Dense vocals (backing voices, a long reverb)
    /// leave few real breaths anyway. nil: it sings straight through
    /// `from...through`.
    /// - Parameter level: the voice's level (dB) over sixteenth k.
    /// - Parameter reference: the level it sings at.
    /// - Parameter turns: whether a clause of the lyrics ends at sixteenth
    ///   k (see `TrackStructure.clauseEnd`): between two sentences is a
    ///   line's end whether or not the voice breathes there, which a
    ///   rapper, or a chorus over its own backing voices, doesn't.
    /// - Parameter inside: whether a sentence of the lyrics is being sung
    ///   through sixteenth k (see `TrackStructure.midSentence`): a breath
    ///   there is a pause in the middle of it, cut only where nothing
    ///   clean is in reach.
    /// Let in, `turns` is where a part of the voice starts and `inside`
    /// the middle of one (see `TrackStructure.partStart`): a voice comes in
    /// on a part's start wherever one is in reach, never on a line in the
    /// middle of a verse because it's nearer.
    static func cut(opening: Bool, from: Int, through: Int, reference: Float, turns: ((Int) -> Bool)? = nil,
                    inside: ((Int) -> Bool)? = nil, level: (Int) -> Float) -> (slot: Int, kind: Cut)? {
        guard from <= through else { return nil }
        func silent(_ k: Int) -> Bool { quiet(level(k), reference) }
        var best: (slot: Int, kind: Cut, cost: Double)?, clean: (slot: Int, kind: Cut, cost: Double)?
        for k in from...through {
            let gap = opening ? k - 1 : k
            var kind: Cut?, extra = 0.0
            let turn = turns?(k) ?? false
            if silent(gap) {
                kind = silent(gap - 1) || silent(gap + 1) || turn ? .line : .word
            } else if opening ? level(k) - level(k - 1) >= 10 : level(k - 1) - level(k) >= 10 {
                (kind, extra) = turn ? (.line, 0.1) : (.word, 0.25)
            } else if turn {
                // (A breath, where there is one as near, is still the
                // cleaner cut.)
                (kind, extra) = (.line, 0.2)
            }
            guard let kind else { continue }
            // (By more than a bar's distance: a line that ends anywhere in
            // the window beats a cut through a sentence right on target.)
            let within = !turn && inside?(k) == true
            if within { extra += 4.4 }
            // Taken out late, it sings over the song that has taken over;
            // let in early, over the one that hasn't left.
            let wrongSide = opening ? k < 0 : k > 0
            let cost = 2 * Double(abs(k)) / Double(slots) + (kind == .word ? 0.25 : 0) + extra / 2 + (wrongSide ? 0.1 : 0)
            if cost < best?.cost ?? .infinity { best = (k, kind, cost) }
            if !within, cost < clean?.cost ?? .infinity { clean = (k, kind, cost) }
        }
        return (clean ?? best).map { ($0.slot, $0.kind) }
    }

    /// Mean square of `stem` over `length` seconds starting at `time`
    /// (seconds of the stem's own output), in dB.
    private static func level(_ stem: StemAudio, at time: Double, length: Double) -> Float {
        let sr = AudioIO.sampleRate
        let start = Int(time * sr), end = Int((time + length) * sr)
        guard start >= 0, end <= stem.count, end > start else { return -90 }
        var l: Float = 0, r: Float = 0
        vDSP_measqv(stem.left.pointer + start, 1, &l, vDSP_Length(end - start))
        vDSP_measqv(stem.right.pointer + start, 1, &r, vDSP_Length(end - start))
        return 10 * log10(max((l + r) / 2, 1e-9))
    }

    /// The level a vocal sings at: its loud bars (90th percentile).
    static func reference(_ structure: TrackStructure?) -> Float? { structure?.vocalReference }

    /// No more than breath and bleed.
    static func quiet(_ db: Float, _ reference: Float) -> Bool { db < reference - 16 }

    /// `cut` on the audio that plays: master time and kind of the cut
    /// nearest `target`, no earlier than `earliest` and no later than
    /// `latest` (master seconds).
    /// - Parameter offset: master time of the stem's output frame 0.
    /// - Parameter bar: seconds to a bar where it plays.
    /// - Parameter lines: the song's structure and the sixteenth of the
    ///   song that plays at `target`, to cut between its lines (see
    ///   `turns` above).
    static func cut(_ stem: StemAudio, offset: Double, reference: Float, opening: Bool, target: Double,
                    earliest: Double, latest: Double, bar: Double,
                    lines: (song: TrackStructure, slot: Int)? = nil) -> (time: Double, kind: Cut)? {
        let slot = bar / Double(slots)
        let turns: ((Int) -> Bool)? = lines.map { lines in
            opening ? { lines.song.partStart(at: lines.slot + $0) } : { lines.song.clauseEnd(at: lines.slot + $0) }
        }
        let inside: ((Int) -> Bool)? = lines.map { lines in
            opening ? { lines.song.midPart(at: lines.slot + $0) ?? false } : { lines.song.midSentence(at: lines.slot + $0) ?? false }
        }
        let found = cut(opening: opening, from: Int(((earliest - target) / slot).rounded(.up)),
                        through: Int(((latest - target) / slot).rounded(.down)), reference: reference, turns: turns,
                        inside: inside) { k in
            level(stem, at: target + Double(k) * slot - offset, length: slot)
        }
        return found.map { (target + Double($0.slot) * slot, $0.kind) }
    }

    /// Whether the vocal is sounding in the beat starting at `time` (master
    /// seconds): more than breath and bleed.
    static func sounding(_ stem: StemAudio, offset: Double, reference: Float, at time: Double, beat: Double) -> Bool {
        !quiet(level(stem, at: time - offset, length: beat), reference)
    }
}

/// Plans and renders a set from loaded tracks in a given order.
enum SetBuilder {
    /// Seconds every track gets on its own between its glide home and the
    /// next transition, so no record is just passed through: a verse or a
    /// hook, not a taste of one. (Eight bars, as this was, is 15 seconds of
    /// house: with a blend on either side the song was gone before anyone
    /// knew it.) Placement's pacing decides how much longer: as long as the
    /// song keeps its power.
    static let minimumSoloSeconds = 45.0

    /// The same in bars of a song.
    static func minimumSoloBars(_ grid: BeatGrid) -> Int {
        max(8, Int((minimumSoloSeconds / grid.barSeconds).rounded(.up)))
    }

    /// When the outgoing song of a pair leaves, by the say of whoever is
    /// playing the set: the bars the transition may start on (one bar: the
    /// next song is brought in there; from a bar on: this song is held
    /// until then), and the jump the song had been given when that was
    /// said (kept as it was: the song is playing).
    struct Exit: Equatable {
        var range: ClosedRange<Int>
        var skip: Range<Int>?
        /// A's bar its way out may start gliding from at the earliest (A
        /// is already playing up to there): where the next song is brought
        /// in now, A gets to the blend's tempo quicker rather than late.
        var wayOutFrom: Int? = nil
    }

    /// Everything a transition is built from (see `build(previous:)`).
    struct BuildKey: Equatable {
        let a: URL, b: URL
        let analysisA: TrackAnalysis, analysisB: TrackAnalysis
        /// A's rendition; B's way in (its way out is the next transition's).
        let renditionA: TrackProcessor.MatchPlan
        let rateB: Double, rampStartB: Double, rampLengthB: Double
        let skip: Range<Int>?
        let plan: PairPlan
        let edit: TransitionEdit
        let isEdited: Bool
        let entryRange: ClosedRange<Int>
        let rateA: Double, barSeconds: Double
        let shiftA: Int
        let drops: Bool
    }

    /// A Stem Swap rolls into a drop only from a blend at least this long:
    /// shorter, and there is no build for the roll to end.
    static let dropMomentBars = 16

    /// - Parameters:
    ///   - edits: hand-shaped transitions, by pair.
    ///   - reuse: renditions from the last build, reused when their plan
    ///     still matches, so an edit re-renders only what it changed.
    ///   - previous: the set as last built. A transition planned from the
    ///     same two songs, at the same spot and tempo, is taken over from
    ///     it rather than measured again: a change to one transition (an
    ///     edit, a request, the next song brought in now) then builds in a
    ///     moment, whatever the set's length.
    ///   - exits: when a song leaves, where that was said while it played
    ///     (see `Exit`).
    ///   - unlocked: pairs whose grooves were predicted to lock and then,
    ///     measured on the audio that plays, didn't: planned without
    ///     counting on B's drums building in under A's (see the end).
    static func build(_ tracks: [(url: URL, loaded: TrackProcessor.Loaded)], edits: [PairKey: TransitionEdit] = [:],
                      reuse: [URL: TrackProcessor.Matched] = [:], previous: SetMix? = nil,
                      exits: [PairKey: Exit] = [:], unlocked: Set<PairKey> = [], clashed: Set<PairKey> = [],
                      locked: Set<PairKey> = [],
                      processor: TrackProcessor,
                      progress: @escaping @Sendable (String) -> Void) async throws -> SetMix {
        precondition(!tracks.isEmpty)
        // (What the last build learnt still holds for the same pairs.)
        let unlocked = unlocked.union(previous?.learned.unlocked ?? [])
        let clashed = clashed.union(previous?.learned.clashed ?? [])
        let locked = locked.union(previous?.learned.locked ?? [])
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
        var transitions: [SetMix.Transition] = []
        // Where each track is back at its own tempo (its bars): transitions
        // out of it start no earlier, and automatic ones allow it some time
        // on its own first.
        // First every transition's plan, from the analyses alone: what B
        // has to be rendered as doesn't depend on any audio, so all the
        // renditions can then be made at once rather than one by one.
        struct Draft {
            let isEdited: Bool, byHand: Bool, skip: Range<Int>?, plan: PairPlan
            let entryRange: ClosedRange<Int>, edit: TransitionEdit
            /// The rates A and B play at through the blend, and a bar of it.
            let rateA: Double, rateB: Double, barSeconds: Double
        }
        var drafts: [Draft] = []
        // What each track is rendered as: its way in (B of one transition)
        // and its way out (A of the next).
        var plans = [TrackProcessor.MatchPlan(map: .constant(1), semitones: 0)]
        do {
            // Where each track is back at its own tempo (its bars):
            // transitions out of it start no earlier, and automatic ones
            // allow it some time on its own first.
            var settledBar = startBar
            var soloBars = max(32, minimumSoloBars(first.analysis.grid))
            let hits = BeatAlign.attacks(of: tracks.map(\.loaded))
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
                let asked = isEdited ? nil : exits[key]
                let skip = isEdited || k == 1 ? nil
                    : asked.map(\.skip) ?? a.analysis.structure?.skip(from: settledBar + 4, landingBy: barsA - 24)
                let lastBar = max(0, barsA - 1)
                let entryRange = min(settledBar, lastBar)...lastBar
                /// A Wash Out's bridge starts before its entry: not inside
                /// A's own way in.
                func inRange(_ edit: TransitionEdit) -> TransitionEdit {
                    var edit = edit
                    let bridge = edit.preset == .echoOut ? max(1, min(8, edit.bars)) : 0
                    edit.entryBar = min(max(edit.entryBar, min(entryRange.lowerBound + bridge, entryRange.upperBound)),
                                        entryRange.upperBound)
                    return edit
                }
                // Drawn by hand, it plays as drawn. Where only the spot,
                // preset, length or key were chosen, what happens there is
                // planned like any other transition, and written from the
                // audio below.
                let byHand = edits[key]?.byHand ?? false
                let chosen = edits[key].flatMap { $0.byHand ? nil : inRange($0) }
                let plan = PairPlan.make(a: a.analysis, b: b.analysis,
                                         entryRange: asked?.range ?? (settledBar + soloBars)...Int.max,
                                         aShift: shifts[k - 1], soloFrom: settledBar, skip: skip,
                                         drums: unlocked.contains(key) ? nil
                                             : hits[k - 1].flatMap { x in hits[k].map { (a: x, b: $0) } },
                                         fixed: chosen, clashing: clashed.contains(key),
                                         locking: locked.contains(key) && !unlocked.contains(key))
                let edit = inRange(byHand ? edits[key]! : TransitionEdit(
                    entryBar: plan.placement.entryBar, cueBar: plan.placement.cueBar, preset: plan.preset,
                    bars: plan.bars, semitones: plan.semitones, lanes: [], byHand: false))
                // B's shift is the plan's: decided there from the notes that
                // overlap at the spot, and placed and priced as that.
                // The two meet at a tempo between theirs (or at A's, for a
                // small stretch): A glides there over its last bars alone,
                // and plays at it to its end.
                let share = edit.preset == .echoOut ? (a: 1.0, b: 1.0) : MixMath.shared(MixMath.rate(a: ga.bpm, b: gb.bpm))
                let bar = ga.barSeconds / share.a
                let span = edit.preset == .echoOut ? 0 : edit.bars
                if share.a != 1 {
                    // (A loop repeats bars from before the entry: A is at
                    // the blend's tempo by where those start. A loop drawn
                    // over by hand is still in the edit's rolls.)
                    let drawn = edit.rolls.first { $0.side == .a && $0.seamless == true }
                    let back = byHand ? drawn.map { Int((($0.start - $0.anchor) / bar).rounded()) } ?? 0
                        : plan.placement.loopBack
                    let earliest = max(settledBar, asked?.wayOutFrom ?? settledBar)
                    let runUp = min(MixMath.glideBars(rate: share.a), max(0, edit.entryBar - back - earliest))
                    let from = plans[k - 1].map.output(ga.downbeat(edit.entryBar - back - runUp) * sr)
                    // (As many output frames as play `runUp` bars of A while
                    // its rate goes from 1 to its share.)
                    let length = runUp == 0 ? 1 : 2 * Double(runUp) * ga.barSeconds * sr / (1 + share.a)
                    plans[k - 1].map = plans[k - 1].map.exiting(at: from, length: length, rate: share.a)
                }
                // B glides home as the blend ends: every preset has A out
                // by then (at the blend's tempo it would drift off B's
                // gliding beat).
                let glideBars = edit.preset == .echoOut ? 0 : MixMath.glideBars(rate: share.b)
                let map = TimeMap.glide(rate: share.b,
                                        rampStart: (Double(span) * bar + gb.scaled(by: share.b).downbeat(edit.cueBar)) * sr,
                                        rampLength: Double(max(1, glideBars)) * bar * sr)
                plans.append(.init(map: map, semitones: edit.semitones))
                drafts.append(Draft(isEdited: isEdited, byHand: byHand, skip: skip, plan: plan, entryRange: entryRange,
                                    edit: edit, rateA: share.a, rateB: share.b, barSeconds: bar))
                shifts.append(edit.semitones)
                // (In B's own bars: two to a bar of the blend, or half of
                // one, where the songs are at half or double time.)
                let metre = edit.preset == .echoOut ? Metre() : Metre(a: ga, b: gb, cue: edit.cueBar)
                settledBar = edit.cueBar + metre.ownBars(span + glideBars)
                soloBars = minimumSoloBars(gb)
            }
        }

        // Every rendition not already at hand, a few at a time (each is
        // already spread over four cores, and holds a copy of its song).
        var renditions = reuse
        let jobs = tracks.indices.compactMap { i -> (url: URL, loaded: TrackProcessor.Loaded, plan: TrackProcessor.MatchPlan)? in
            let url = tracks[i].url
            if let r = renditions[url], r.plan.isSame(as: plans[i]) { return nil }
            return (url, tracks[i].loaded, plans[i])
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

        /// A track as it plays: rendered to its plan (the songs themselves
        /// where there's nothing to render).
        func rendition(_ i: Int) async throws -> TrackProcessor.Matched {
            if let cached = renditions[tracks[i].url], cached.plan.isSame(as: plans[i]) { return cached }
            return try await match(tracks[i].loaded, plan: plans[i], processor: processor)
        }
        let opener = try await rendition(0)
        var planned = [SetMix.Track(url: tracks[0].url, loaded: first, map: plans[0].map,
                                    matched: plans[0].map.isIdentity ? nil : opener,
                                    offset: -first.analysis.grid.downbeat(startBar), envelopes: [:])]
        var shifts = [0]
        var sinceDrop = 3
        // Pairs planned for grooves that lock which turned out not to, and
        // for melodies that layer which turned out to clash.
        var broken: Set<PairKey> = [], clashing: Set<PairKey> = [], locking: Set<PairKey> = []

        for k in 1..<tracks.count {
            if Task.isCancelled { throw CancellationError() }
            var a = planned[k - 1]
            let b = tracks[k].loaded
            let ga = a.loaded.analysis.grid, gb = b.analysis.grid
            let draft = drafts[k - 1]
            let isEdited = draft.isEdited, byHand = draft.byHand, plan = draft.plan, entryRange = draft.entryRange
            var skippedBars = 0
            if let skip = draft.skip, plan.placement.jumps, plan.placement.entryBar >= skip.upperBound {
                planned[k - 1].skip = (ga.downbeat(skip.lowerBound), ga.downbeat(skip.upperBound))
                a = planned[k - 1]
                skippedBars = skip.count
            }
            var edit = draft.edit
            // B as counted in the blend's bars (see `Metre`): what it plays
            // bar by bar through the blend is read off that.
            let metre = edit.preset == .echoOut ? Metre() : Metre(a: ga, b: gb, cue: edit.cueBar)
            let bCounted = b.analysis.counted(metre), cueCounted = metre.counted(edit.cueBar)
            // A bar of the blend: A's own, or shorter or longer where A has
            // come some of the way to B's tempo.
            let blendBar = draft.barSeconds

            // Editor time is the set's less a constant: A's own clock up
            // to where A starts for the blend's tempo (if it does), and
            // as it plays from there.
            let native = ga.downbeat(edit.entryBar)
            let start = a.master(native)
            let delta = start - native
            let span = edit.preset == .echoOut ? 0 : edit.bars
            let end = start + Double(span) * blendBar
            // Where A's stems sound from around its exit: placement keeps the
            // transition, and the bars heard before it, past any jump.
            let aOffset = a.stemOffset(at: start)
            // A's beat looped under the blend (see `TransitionBuilder.loop`):
            // everything heard of A's drums, bass line and melody from here
            // on is the loop, so that is what's measured, and the song's
            // bar-by-bar levels and notes are read the same way.
            let loop = byHand ? 0 : plan.placement.loopBars, loopBack = plan.placement.loopBack
            var aStems = a.stems, aPlays = aOffset
            if loop > 0 {
                aPlays = start - Double(loopBack) * blendBar
                aStems = looped(a.stems, offset: aOffset, from: start, back: Double(loopBack) * blendBar,
                                length: Double(loop) * blendBar, until: end + 4 * blendBar)
            }
            let saPlays = a.loaded.analysis.structure.map {
                loop > 0 ? $0.looped(from: edit.entryBar, bars: loop, back: loopBack, through: edit.entryBar + edit.bars + 12) : $0
            }
            let offset = start - gb.scaled(by: draft.rateB).downbeat(edit.cueBar)
            let map = plans[k].map
            let matched = try await rendition(k)
            // A roll into the drop is a moment only if it isn't every
            // transition: three without one in between, and only after a blend
            // long enough to be one. A Drop Swap is built on it, but
            // never right after another roll: two in a row is a routine.
            let drops = !byHand && plan.placement.dropMoment && edit.preset != .echoOut
                && (edit.preset == .dropSwap ? sinceDrop >= 1 : edit.bars >= dropMomentBars && sinceDrop >= 3)
            let buildKey = BuildKey(a: a.url, b: tracks[k].url, analysisA: a.loaded.analysis, analysisB: b.analysis,
                                    renditionA: plans[k - 1], rateB: map.rate, rampStartB: map.rampStart,
                                    rampLengthB: map.rampLength, skip: skippedBars > 0 ? draft.skip : nil, plan: plan,
                                    edit: draft.edit, isEdited: isEdited, entryRange: entryRange, rateA: draft.rateA,
                                    barSeconds: blendBar, shiftA: shifts[k - 1], drops: drops)
            if let previous, let old = previous.transitions.first(where: { $0.made?.key == buildKey }), let made = old.made,
               previous.tracks.indices.contains(old.to) {
                // Built before from exactly this: the same transition, at
                // wherever it now plays.
                let by = start - old.start
                let was = previous.tracks[old.to]
                var incoming = SetMix.Track(url: tracks[k].url, loaded: b, map: map, matched: matched, offset: was.offset + by,
                                            envelopes: was.incoming.envelopes.mapValues { $0.map { shift($0, by: by) } },
                                            rolls: was.incoming.rolls.map { $0.shifted(by: by) })
                incoming.incoming = (incoming.envelopes, incoming.rolls)
                for (stem, envelopes) in made.outgoing {
                    planned[k - 1].envelopes[stem] = merge(planned[k - 1].envelopes[stem], envelopes.map { shift($0, by: by) })
                }
                planned[k - 1].rolls += made.outgoingRolls.map { $0.shifted(by: by) }
                planned.append(incoming)
                transitions.append(old.moved(by: by, from: k - 1, to: k))
                shifts.append(old.edit.semitones)
                sinceDrop = byHand ? (old.edit.rolls.contains { $0.seamless != true } ? 0 : sinceDrop + 1)
                    : drops ? 0 : sinceDrop + 1
                continue
            }

            // Measured on the audio that plays: B's stretched drums against
            // A's. The glide may start a few ms off after the nudge; nobody
            // hears that, while re-stretching would cost a second render.
            var align = BeatAlign.Result(nudge: 0, lock: 1)
            if span > 0, let drumsA = aStems[.drums], let drumsB = matched.stems[.drums] {
                // Where the builder hands the drums over (its `sw`).
                let handover = TransitionBuilder.switchBar(edit.preset, bars: edit.bars, lowSwap: plan.placement.lowSwap)
                align = BeatAlign.nudge(a: drumsA, aOffset: aPlays, b: drumsB, bOffset: offset, from: start, to: end,
                                        split: byHand ? nil : start + handover * blendBar)
            }
            let nudge = align.nudge
            // Vocals hand over between lines, not mid-word.
            let keyA = a.loaded.analysis.key.transposed(by: shifts[k - 1]), keyB = b.analysis.key.transposed(by: edit.semitones)
            var keysClash = MixMath.keysClash(keyA, keyB)
            // Whether the melodies can layer is heard, not guessed from the
            // keys: the notes that will actually overlap decide, where
            // there are any, B as shifted. In two stretches, each judged on
            // what plays in it (see `AutoPlacement.melodyOverlap`): B's
            // melody on A's melody and bass line until the switch, then
            // A's melody on B's melody and bass line until it has dissolved.
            // B's bass line is out before the switch: counted there, it
            // vouched for a melody it wasn't playing under.
            if !byHand, span > 0, let otherA = aStems[.other], let otherB = matched.stems[.other] {
                let bar = blendBar
                let overlap = AutoPlacement.melodyOverlap(edit.preset, bars: edit.bars, lowSwap: plan.placement.lowSwap)
                /// How far from one scale the two are over `bars`, and how
                /// much their notes grate (see `Harmony.roughness`).
                func heard(_ bars: Range<Int>, _ partsA: [StemAudio?], _ partsB: [StemAudio?]) -> (clash: Float, rough: Float)? {
                    guard !bars.isEmpty,
                          let ca = Harmony.chroma(partsA.compactMap { $0 }, offset: aPlays,
                                                  from: start + Double(bars.lowerBound) * bar, to: start + Double(bars.upperBound) * bar),
                          let cb = Harmony.chroma(partsB.compactMap { $0 }, offset: offset + nudge,
                                                  from: start + Double(bars.lowerBound) * bar, to: start + Double(bars.upperBound) * bar)
                    else { return nil }
                    return (Harmony.clash(ca, cb), Harmony.roughness(ca, cb))
                }
                let both = [heard(overlap.before, [otherA, aStems[.bass]], [otherB]),
                            heard(overlap.after, [otherA], [otherB, matched.stems[.bass]])].compactMap { $0 }
                // No notes to compare: nothing to clash (as placement
                // judges it, see `AutoPlacement.notesClash`).
                // (How much the notes grate reads a little differently on
                // the audio than on the song's bars, and most stretches
                // are near the line: the blend was placed as layered or
                // swapped by the bars, and plays as placed unless the
                // audio is clearly over.)
                keysClash = plan.placement.notesClash == true
                    || both.contains { $0.clash > Harmony.tolerance(keyA, keyB) || $0.rough > Harmony.roughTolerance + 0.02 }
            } else if span == 0 {
                // A Wash Out never plays the two songs' notes together.
                keysClash = false
            }
            if !byHand, span > 0, keysClash, plan.placement.notesClash != true {
                clashing.insert(PairKey(from: a.url, to: tracks[k].url))
            }
            // The beats can sit at one lag and still not sit: one kit's hats
            // ahead of its clap, the other's on it, and no nudge closes
            // both. Which hits carry depends on what's heard (B's low end
            // killed, A's kit making room), so it's listened for: B's
            // drums layered under A's are rendered as the blend would
            // play them up to the swap, and if they flam there, they
            // aren't layered. B's beat then comes in whole on the switch.
            // Windows in which the two kits, rendered as they'd play before
            // the swap, were heard to hit together.
            var heardTogether = 0
            if !byHand, span > 0, align.grooves {
                let sw = TransitionBuilder.switchBar(edit.preset, bars: edit.bars, lowSwap: plan.placement.lowSwap)
                func written(room: Double, start: Double, bar: Double) -> TransitionBuilder.Made {
                    TransitionBuilder.make(edit.preset, lanes: Lane.allLanes(), start: start, barSeconds: bar, bars: edit.bars,
                                           vocalBar: max(edit.bars / 2, plan.placement.vocalHandoff), keysClash: keysClash,
                                           lowSwap: plan.placement.lowSwap, drumsLayer: true, drumsLinger: align.groovesAfter,
                                           dropMoment: plan.placement.dropMoment, room: room, loop: loop, loopBack: loopBack)
                }
                func lanes(room: Double, start: Double, bar: Double) -> [Lane] { written(room: room, start: start, bar: bar).lanes }
                var room = 0.0
                if edit.preset == .stemSwap, let sa = saPlays, let sb = bCounted.structure,
                   let pa = AutoPlacement.powers(sa, trim: Float(MixMath.trimDB(a.loaded.analysis))),
                   let pb = AutoPlacement.powers(sb, trim: Float(MixMath.trimDB(b.analysis))) {
                    let q = max(1, edit.bars / 4)
                    room = AutoPlacement.room(TransitionShape(lanes: lanes(room: 0, start: 0, bar: 1), preset: edit.preset, bars: edit.bars),
                                              a: pa, e: edit.entryBar, b: pb, c: cueCounted, from: q, to: max(q + 1, Int(sw)))
                }
                var outgoing = a
                var incoming = SetMix.Track(url: tracks[k].url, loaded: b, map: map, matched: matched, offset: offset + nudge,
                                            envelopes: [:])
                let trial = written(room: room, start: native, bar: blendBar)
                for lane in trial.lanes where lane.stem == .drums {
                    let shifted = lane.envelopes.map { shift($0, by: delta) }
                    if lane.side == .a {
                        outgoing.envelopes[.drums] = merge(outgoing.envelopes[.drums], shifted)
                    } else {
                        incoming.envelopes[.drums] = shifted
                    }
                }
                // (A's loop: its drums as they'll really play.)
                for roll in trial.rolls where roll.side == .a && roll.seamless == true {
                    outgoing.rolls.append(placed(roll, by: delta, on: a))
                }
                let pair = SetMix(tracks: [outgoing, incoming], transitions: [], length: end + 1)
                let frames = Int(Double(edit.bars) * blendBar * sr), swap = min(frames, Int(sw * blendBar * sr))
                func drums(_ track: Int) -> [Float] {
                    let renderer = MixRenderer(snapshot: pair.snapshot(masterGain: 1) { i, stem in i == track && stem == .drums })
                    renderer.setPositionImmediately(Int(start * sr))
                    var l = [Float](repeating: 0, count: frames), r = l
                    renderer.render(left: &l, right: &r, count: frames)
                    vDSP_vadd(l, 1, r, 1, &l, 1, vDSP_Length(frames))
                    return l
                }
                if frames > 0 {
                    let da = drums(0), db = drums(1)
                    // One stretch of the two hitting clearly apart is
                    // heard (there are only two or four to a blend).
                    let before = BeatAlign.heardLags(a: Array(da[0..<swap]), b: Array(db[0..<swap]), window: 2 * blendBar)
                    if BeatAlign.flams(before) { align.topsSplit = true }
                    heardTogether = before.count
                    // The same for A's drums playing on under B's after the
                    // swap: where they flam there, they stop on it.
                    let after = BeatAlign.heardLags(a: Array(da[swap...]), b: Array(db[swap...]), window: 2 * blendBar)
                    if BeatAlign.flams(after) { align.lingerSplit = true }
                }
            }
            /// The sixteenth of each song that plays at master `t`, with
            /// its lines (see `VocalPhrasing.cut`): the blend's bars are
            /// the songs' own; a Wash Out's B plays at its own tempo.
            func linesA(_ t: Double) -> (song: TrackStructure, slot: Int)? {
                a.loaded.analysis.structure.map {
                    ($0, VocalPhrasing.slots * edit.entryBar + Int(((t - start) / blendBar * Double(VocalPhrasing.slots)).rounded()))
                }
            }
            func linesB(_ t: Double) -> (song: TrackStructure, slot: Int)? {
                let bar = span > 0 ? blendBar : gb.barSeconds
                return bCounted.structure.map {
                    ($0, VocalPhrasing.slots * cueCounted + Int(((t - start) / bar * Double(VocalPhrasing.slots)).rounded()))
                }
            }
            // Where the two whole kits don't sit (or weren't known to), B's
            // hats alone may: rendered as they'd play against A's, both
            // above 6 kHz, two clear windows that don't flam.
            var hats = false
            if !byHand, span > 0, edit.preset == .stemSwap, !align.grooves {
                heardTogether = 0
                let sw = TransitionBuilder.switchBar(edit.preset, bars: edit.bars, lowSwap: plan.placement.lowSwap)
                let trial = TransitionBuilder.make(edit.preset, lanes: Lane.allLanes(), start: native, barSeconds: blendBar,
                                                   bars: edit.bars, vocalBar: max(edit.bars / 2, plan.placement.vocalHandoff),
                                                   keysClash: keysClash, lowSwap: plan.placement.lowSwap, drumsLayer: false,
                                                   drumsLinger: false, dropMoment: plan.placement.dropMoment, loop: loop,
                                                   loopBack: loopBack, hats: true)
                var outgoing = a
                var incoming = SetMix.Track(url: tracks[k].url, loaded: b, map: map, matched: matched, offset: offset + nudge,
                                            envelopes: [:])
                for lane in trial.lanes where lane.stem == .drums {
                    let shifted = lane.envelopes.map { shift($0, by: delta) }
                    if lane.side == .a { outgoing.envelopes[.drums] = merge(outgoing.envelopes[.drums], shifted) }
                    else { incoming.envelopes[.drums] = shifted }
                }
                for roll in trial.rolls where roll.side == .a && roll.seamless == true {
                    outgoing.rolls.append(placed(roll, by: delta, on: a))
                }
                let pair = SetMix(tracks: [outgoing, incoming], transitions: [], length: end + 1)
                let frames = Int(min(sw, Double(edit.bars)) * blendBar * sr)
                /// A track's drums as they'd play, whole or above 6 kHz.
                func hiss(_ track: Int, whole: Bool = false) -> [Float] {
                    let renderer = MixRenderer(snapshot: pair.snapshot(masterGain: 1) { i, stem in i == track && stem == .drums })
                    renderer.setPositionImmediately(Int(start * sr))
                    var l = [Float](repeating: 0, count: frames), r = l
                    renderer.render(left: &l, right: &r, count: frames)
                    if whole {
                        vDSP_vadd(l, 1, r, 1, &l, 1, vDSP_Length(frames))
                        return l
                    }
                    var hp1 = Biquad(), hp2 = Biquad()
                    hp1.set(.highPass(frequency: 6000, q: 0.707), sampleRate: sr)
                    hp2.set(.highPass(frequency: 6000, q: 0.707), sampleRate: sr)
                    hp1.process(&l, &r, count: frames)
                    hp2.process(&l, &r, count: frames)
                    vDSP_vadd(l, 1, r, 1, &l, 1, vDSP_Length(frames))
                    return l
                }
                if frames > Int(4 * blendBar * sr) {
                    let lags = BeatAlign.heardLags(a: hiss(0), b: hiss(1), window: 2 * blendBar)
                    hats = lags.count >= 2 && !BeatAlign.flams(lags)
                    // And B's hats against all of A's kit, as it's heard:
                    // hats that sit with A's hats can still land off its
                    // snare where A's own hats do (34 ms, on two songs
                    // never seen before).
                    // (No window past 10 ms: hats are where a flam is
                    // heard first.)
                    if hats, BeatAlign.heardLags(a: hiss(0, whole: true), b: hiss(1, whole: true), window: 2 * blendBar)
                        .contains(where: { abs($0) > 0.010 }) {
                        hats = false
                    }
                }
            }
            if !byHand, span > 0, plan.drumsLock, !align.grooves {
                broken.insert(PairKey(from: a.url, to: tracks[k].url))
            }
            // The other way round: placed for B's drums not building in,
            // and they sit with A's clearly on the audio. A blend placed
            // for that worst case may not be the best one there is.
            // (Shown by two windows of the kits' hits that agree, or heard:
            // the two rendered as they'd play, hitting together.)
            if !byHand, span > 0, edit.preset != .echoOut, !plan.drumsLock, align.grooves,
               (align.votesBefore >= 2 && align.lockBefore > 0.8) || heardTogether >= 1 {
                locking.insert(PairKey(from: a.url, to: tracks[k].url))
            }
            var vocalIn: Double?, vocalOut: Double?
            var mashup = false
            // Bar (from B's entry) before which B's vocal stays out.
            var vocalFloor = 0.0
            var vocalInKind: String?
            // What A's voice is taken out on ("line", "word"); nil: nothing
            // found to cut on (it's faded if it's singing there).
            var vocalOutKind: String?
            if !byHand, edit.preset == .echoOut {
                // A's voice floats on over the bridge and leaves on a
                // breath in its last bars; B's beat drops with its voice
                // open, or with it joining on its next word.
                // (On a cut it sings up to it, leaving on a line end in the
                // last four bars: A's beat may ride on alone after it.)
                let ahead = edit.bars <= 1 ? 0.0 : 1.0, back = edit.bars <= 1 ? 4.0 : 3.0
                if let vocalsA = a.stems[.vocals], let ref = VocalPhrasing.reference(a.loaded.analysis.structure),
                   let cut = VocalPhrasing.cut(vocalsA, offset: aOffset, reference: ref, opening: false,
                                               target: start - ahead * blendBar, earliest: start - back * blendBar,
                                               latest: start, bar: blendBar, lines: linesA(start - ahead * blendBar)) {
                    vocalOut = (cut.time - start) / blendBar
                    vocalOutKind = cut.kind.rawValue
                }
                // B lands whole: its voice opens with its beat, or a beat
                // before on a pickup. It's never held back while B's song
                // plays and let in on a breath further on (heard as the
                // singer cutting in mid-verse).
                vocalIn = 0
                vocalInKind = "bar"
                if let vocalsB = matched.stems[.vocals], let ref = VocalPhrasing.reference(bCounted.structure),
                   let cut = VocalPhrasing.cut(vocalsB, offset: offset + nudge, reference: ref, opening: true, target: start,
                                               earliest: start - AutoPlacement.pickup * blendBar, latest: start,
                                               bar: blendBar, lines: linesB(start)) {
                    vocalIn = (cut.time - start) / blendBar
                    vocalInKind = cut.kind == .line ? "breath" : "word"
                }
            }
            if !byHand, span > 0, let vocalsA = a.stems[.vocals], let vocalsB = matched.stems[.vocals] {
                let n = Double(edit.bars), bar = blendBar, beat = bar / 4
                let v = min(n, max(n / 2, Double(plan.placement.vocalHandoff)))
                let sw = TransitionBuilder.switchBar(edit.preset, bars: edit.bars, lowSwap: plan.placement.lowSwap)
                let refA = VocalPhrasing.reference(a.loaded.analysis.structure)
                if loop > 0 {
                    // A's voice goes as its beat starts to loop: on the last
                    // word of the part that ends there (or on the one).
                    let cut = refA.flatMap {
                        VocalPhrasing.cut(vocalsA, offset: aOffset, reference: $0, opening: false, target: start,
                                          earliest: start - AutoPlacement.loopExit.before * bar,
                                          latest: start + AutoPlacement.loopExit.after * bar, bar: bar, lines: linesA(start))
                    }
                    vocalOut = cut.map { ($0.time - start) / bar } ?? 0
                    vocalOutKind = cut?.kind.rawValue
                }
                // A mashup moment: B's vocal sings over A's beat from early
                // in the blend, where placement found it pays off. Only if
                // it can't go wrong as it plays: the grooves lock, B's line
                // starts clean in the window, and A's vocal (if any) has
                // finished a line by then.
                // B's voice has to sit on A's chords, as they play there.
                if plan.placement.mashup, edit.preset == .stemSwap, !keysClash, align.grooves,
                   let refB = VocalPhrasing.reference(bCounted.structure),
                   Harmony.fits([aStems[.other], aStems[.bass]].compactMap { $0 }, aOffset: aPlays,
                                [vocalsB], bOffset: offset + nudge,
                                from: start + n / 4 * bar, to: start + n / 2 * bar) {
                    let window = TransitionBuilder.mashupWindow(bars: edit.bars)
                    if let entry = VocalPhrasing.cut(vocalsB, offset: offset + nudge, reference: refB, opening: true,
                                                     target: start + window.earliest * bar,
                                                     earliest: start + window.earliest * bar,
                                                     latest: start + window.latest * bar, bar: bar, lines: linesB(start + window.earliest * bar)), entry.kind == .line,
                       // (On the start of a part of B's, not a line in the middle of its verse.)
                       linesB(entry.time).map({ $0.song.midPart(at: $0.slot) != true }) ?? true {
                        let tin = entry.time
                        if let refA, loop == 0 {
                            // A's line has to end right before B's starts:
                            // cutting it bars early to fit B in is a hole,
                            // not a mashup.
                            if let exit = VocalPhrasing.cut(vocalsA, offset: aOffset, reference: refA, opening: false, target: tin,
                                                            earliest: tin - bar, latest: tin, bar: bar, lines: linesA(tin)), exit.kind == .line {
                                vocalIn = (tin - start) / bar
                                vocalOut = (exit.time - start) / bar
                                vocalOutKind = exit.kind.rawValue
                                mashup = true
                            }
                        } else {
                            vocalIn = (tin - start) / bar
                            mashup = true
                        }
                        if mashup { vocalInKind = "breath" }
                    }
                }
                /// Where B's voice really sings from once its channel opens
                /// at bar `opening` (which may be the pause before a line):
                /// looked for to the end of the blend, or four bars on.
                func sounds(from opening: Double) -> Double {
                    guard let refB = VocalPhrasing.reference(bCounted.structure) else { return opening }
                    var t = start + opening * bar
                    while t < start + max(opening + 4, n) * bar,
                          !VocalPhrasing.sounding(vocalsB, offset: offset + nudge, reference: refB, at: t, beat: beat) {
                        t += beat
                    }
                    return (t - start) / bar
                }
                /// A's voice can sing on over B's beat from the swap until
                /// bar `until`: its notes sit on B's chords there. Only over
                /// a beat it grooves with: a voice phrased against another
                /// groove sounds off time.
                func carries(until: Double) -> Bool {
                    loop == 0 && !keysClash && align.grooves && until > sw
                        && Harmony.fits([vocalsA], aOffset: aOffset,
                                        [matched.stems[.other], matched.stems[.bass]].compactMap { $0 },
                                        bOffset: offset + nudge, from: start + sw * bar, to: start + min(until, n) * bar)
                }
                if !mashup {
                    if let ref = VocalPhrasing.reference(bCounted.structure) {
                        // Before the swap B's voice sings over A's beat and
                        // bass line: only where the grooves lock and it sits
                        // on A's chords (as a mashup must). Otherwise, and
                        // on clashing keys, it waits for the swap.
                        // (Over a beat it grooves with: the two kits lock, or
                        // B's hats were heard to sit with A's kit.)
                        func overA(from first: Double) -> Bool {
                            !keysClash && (align.grooves || hats) && sw > first
                                && Harmony.fits([aStems[.other], aStems[.bass]].compactMap { $0 }, aOffset: aPlays,
                                                [vocalsB], bOffset: offset + nudge,
                                                from: start + first * bar, to: start + sw * bar)
                        }
                        // Where B takes the low end before half-way (A's own
                        // beat left early), B has the floor from there: its
                        // voice may come in on its own beat.
                        // (Over A's beat looped, with A's voice gone, as
                        // early as its melody: a quarter in.)
                        // (Or where A's part ends a quarter in and B's begins
                        // there, as placement planned it.)
                        let q = Int(n) / 4
                        func edge(_ st: TrackStructure?, _ g: Int) -> Float {
                            guard let st else { return 0 }
                            let e = AutoPlacement.phrases(st, boundary: st.boundaryStrength()).edge
                            return g >= 0 && g < e.count ? e[g] : 0
                        }
                        let partsMeet = n >= 16 && edge(a.loaded.analysis.structure, edit.entryBar + q) >= 0.7
                            && edge(bCounted.structure, cueCounted + q) >= 0.7
                        let partStarts = loop > 0 && edge(bCounted.structure, cueCounted) >= 0.7
                            && (bCounted.structure?.meanActivity(.vocals, bars: cueCounted..<(cueCounted + q)) ?? 0) > 0.3
                        let first = sw < n / 2 ? sw : partStarts && overA(from: 0) ? 0
                            : (loop > 0 || partsMeet) && n >= 16 && overA(from: n / 4) ? n / 4
                            : overA(from: n / 2) ? n / 2 : max(n / 2, sw)
                        vocalFloor = first
                        // Aim for the planned handoff while A still sings
                        // there, but never past the swap: A's voice leaves
                        // there (bar a cappella), so B's arrives there too.
                        // Where A has nothing to sing (or has had to leave on
                        // an early swap), B's next line from its floor.
                        let aSings = saPlays?.isActive(.vocals, bar: edit.entryBar + Int(first)) ?? true
                        let aim = aSings && first >= n / 2 ? min(max(v, first), max(first, sw)) : first
                        // On the breath before a line or, failing that,
                        // in the gap before a word, as near as it comes to
                        // where it's due: where its words were heard, on
                        // the start of a part, waiting for one to the end
                        // of the blend if it must (`AutoPlacement.entryLatest`);
                        // otherwise no more than a couple of bars past it.
                        // Singing straight through, it comes in on the bar
                        // (eased in below).
                        // (From half a bar before it's due where that's
                        // allowed: a line often starts with a pickup
                        // ahead of its bar.)
                        if let cut = VocalPhrasing.cut(vocalsB, offset: offset + nudge, reference: ref, opening: true,
                                                       target: start + aim * bar,
                                                       earliest: start + max(0, aim - (keysClash ? 0 : 0.5)) * bar,
                                                       latest: start + AutoPlacement.entryLatest(bCounted.structure, aim: aim, bars: edit.bars) * bar,
                                                       bar: bar, lines: linesB(start + aim * bar)) {
                            vocalIn = (cut.time - start) / bar
                            vocalInKind = cut.kind == .line ? "breath" : "word"
                        } else {
                            vocalIn = aim
                        }
                    }
                    // A's vocal sings on over B's beat until B's own arrives
                    // (an a cappella over the new song: both are heard), if
                    // its notes sit on B's chords there; otherwise it leaves
                    // as B takes the low end. Where B's own comes in is
                    // where it really does: no line found, it opens on the
                    // bar the builder gives it (never before its floor).
                    // And not where B's channel opens (a pause) but where it
                    // really sings: A's voice isn't cut into a silence that
                    // lasts until B's next line.
                    let untilB = vocalIn.map(sounds(from:)) ?? max(v, vocalFloor.rounded(.up))
                    let acappella = carries(until: untilB)
                    // Otherwise A's voice leaves as B's arrives or B takes
                    // the low end, whichever is first: not at the bar B's
                    // was planned for when B's has been held back to the
                    // swap (beats that don't lock, notes that clash), which
                    // left bars with no voice at all. Clashing keys swap
                    // melodies and voices on the swap, so A's sings until
                    // then over nothing of B's in a key. Never past the
                    // swap unless it's an a cappella (B's beat is under it
                    // there), never before B has come in.
                    // On the end of a line if one ends within a couple of
                    // bars before: further back, a whole line of A's would
                    // go unsung with nobody singing instead, so it sings
                    // up to there and blends out (decided below).
                    // On the breath or the gap between words nearest to that,
                    // between two clauses of its words if one ends in reach:
                    // up to two bars before (`AutoPlacement.exitBack`), or a
                    // little after
                    // (to the end of a word that runs over the bar line)
                    // while B's isn't singing yet.
                    // (At the end of the phrase it's in rather than a bar or two
                    // into the next: see `AutoPlacement.phraseEnd`.)
                    let target = acappella ? untilB : AutoPlacement.phraseEnd(before: min(untilB, sw))
                    if let refA, loop == 0 {
                        let after = acappella || keysClash ? 0 : target >= sw ? 0.5 : 2
                        let cut = VocalPhrasing.cut(vocalsA, offset: aOffset, reference: refA, opening: false,
                                                    target: start + target * bar,
                                                    earliest: start + (target - min(AutoPlacement.exitBack, target)) * bar,
                                                    latest: start + min(target + after, max(target, untilB), n) * bar, bar: bar, lines: linesA(start + target * bar))
                        // (No cut to be found: on the nearest downbeat.)
                        vocalOut = cut.map { ($0.time - start) / bar } ?? min(max(target.rounded(), 0), max(target, untilB), n)
                        vocalOutKind = cut?.kind.rawValue
                    }
                }
            }
            var payoff: [String] = []
            var room = 0.0
            var dropAt: Double?
            if !byHand {
                // Grooves that won't lock (a swung beat against a straight
                // one) aren't layered: A's beat plays on and B's drums come
                // in whole on the swap.
                let dropMoment = drops
                sinceDrop = dropMoment ? 0 : sinceDrop + 1
                let switchBar = TransitionBuilder.switchBar(edit.preset, bars: edit.bars, lowSwap: plan.placement.lowSwap)
                let rollBeat = dropMoment ? aStems[.drums].flatMap {
                    BeatAlign.snareBeat($0, offset: aPlays, barStart: start + (switchBar - 1) * blendBar,
                                        beat: blendBar / 4)
                } : nil
                func make(outFade: Double, inFade: Double, room: Double, start: Double? = nil,
                          barSeconds: Double? = nil) -> TransitionBuilder.Made {
                    TransitionBuilder.make(edit.preset, lanes: Lane.allLanes(), start: start ?? ga.downbeat(edit.entryBar),
                                           barSeconds: barSeconds ?? blendBar, bars: edit.bars,
                                           vocalBar: mashup ? plan.placement.vocalHandoff
                                               : max(edit.bars / 2, plan.placement.vocalHandoff, Int(vocalFloor.rounded(.up))),
                                           keysClash: keysClash, lowSwap: plan.placement.lowSwap,
                                           drumsLayer: align.grooves, drumsLinger: align.groovesAfter,
                                           vocalIn: vocalIn, vocalOut: vocalOut,
                                           mashup: mashup, dropMoment: dropMoment, rollBeat: rollBeat,
                                           vocalOutFade: outFade, vocalInFade: inFade, room: room,
                                           carry: (plan.placement.carry || loop > 0) && !keysClash && !mashup, under: under,
                                           loop: loop, loopBack: loopBack, hats: hats)
                }
                // B's melody plays under A's voice for as long as A sings,
                // from the two songs' levels there, and steps up as the
                // voice leaves.
                var under = 0.0
                if edit.preset == .stemSwap, !keysClash, !mashup, let sa = saPlays,
                   let sb = bCounted.structure,
                   let pa = AutoPlacement.powers(sa, trim: Float(MixMath.trimDB(a.loaded.analysis))),
                   let pb = AutoPlacement.powers(sb, trim: Float(MixMath.trimDB(b.analysis))) {
                    under = AutoPlacement.under(a: pa, e: edit.entryBar, b: pb, c: cueCounted, from: max(1, edit.bars / 4),
                                                to: Int((vocalOut ?? switchBar).rounded(.up)))
                }
                // Room for B: A's EQ gives way as much as B's parts need to
                // be heard, judged on the blend as it will play (B through
                // its entry filters, its drums in or not, A's voice on).
                if edit.preset == .stemSwap, let sa = saPlays, let sb = bCounted.structure,
                   let pa = AutoPlacement.powers(sa, trim: Float(MixMath.trimDB(a.loaded.analysis))),
                   let pb = AutoPlacement.powers(sb, trim: Float(MixMath.trimDB(b.analysis))) {
                    let q = max(1, edit.bars / 4)
                    let plain = TransitionShape(lanes: make(outFade: 0, inFade: 0, room: 0, start: 0, barSeconds: 1).lanes,
                                                preset: edit.preset, bars: edit.bars)
                    room = AutoPlacement.room(plain, a: pa, e: edit.entryBar, b: pb, c: cueCounted, from: q,
                                              to: max(q + 1, Int(switchBar)))
                }
                // Both voices are cut, never faded: on a breath or between
                // two words wherever they have one near (found above), and
                // otherwise on the downbeat itself, the way a DJ takes a
                // voice out on the one with its last words thrown into the
                // echo, and opens the next on the one of its phrase. A voice
                // faded down through a sentence is a crossfade; a cut on the
                // beat is a decision.
                let bar = blendBar, beat = bar / 4
                let made = make(outFade: 0, inFade: 0, room: room)
                // (The builder may have moved the exit off the cut found: then
                // it's judged where it ended up.)
                let onCut = vocalOutKind != nil && made.vocalExit.map { abs($0 - (vocalOut ?? .infinity)) < 1e-6 } ?? false
                if let exit = made.vocalExit {
                    let singing = a.stems[.vocals].flatMap { vocalsA in
                        VocalPhrasing.reference(a.loaded.analysis.structure).map { ref in
                            VocalPhrasing.sounding(vocalsA, offset: aOffset, reference: ref, at: start + exit * bar, beat: beat / 2)
                        }
                    } ?? false
                    vocalOutKind = onCut ? vocalOutKind : singing ? "bar" : "line"
                } else {
                    vocalOutKind = nil
                }
                if let entry = made.vocalEntry, let vocalsB = matched.stems[.vocals],
                   let ref = VocalPhrasing.reference(bCounted.structure) {
                    let singing = VocalPhrasing.sounding(vocalsB, offset: offset + nudge, reference: ref,
                                                         at: start + entry * bar - beat / 2, beat: beat / 2)
                    vocalInKind = vocalInKind ?? (singing ? "bar" : "grid")
                } else {
                    vocalInKind = nil
                }
                edit.lanes = made.lanes
                edit.rolls = made.rolls
                payoff = plan.placement.payoff.filter { !$0.hasPrefix("mashup") && $0 != "roll into the drop" }
                if mashup { payoff.append("mashup: B sings over A's beat") }
                if dropMoment { payoff.append("roll into the drop") }
                if dropMoment { dropAt = start + switchBar * blendBar }
                if plan.placement.carry && !keysClash && !mashup { payoff.append("A's beat carries B in") }
                if loop > 0 { payoff.append("A's beat loops under B") }
            } else {
                // A hand-shaped transition's roll counts too: the next
                // automatic one isn't a second in a row.
                sinceDrop = edit.rolls.contains { $0.seamless != true } ? 0 : sinceDrop + 1
            }
            var incoming = SetMix.Track(url: tracks[k].url, loaded: b, map: map, matched: matched, offset: offset + nudge,
                                        envelopes: [:])
            // (What it writes on the outgoing song is kept too, for the
            // next build to take over: see `Transition.made`.)
            var outgoing: [StemKind: [Envelope]] = [:], outgoingRolls: [Roll] = []
            for lane in edit.lanes {
                let shifted = lane.envelopes.map { shift($0, by: delta) }
                if lane.side == .a {
                    planned[k - 1].envelopes[lane.stem] = merge(planned[k - 1].envelopes[lane.stem], shifted)
                    outgoing[lane.stem] = shifted
                } else {
                    incoming.envelopes[lane.stem] = shifted
                }
            }
            for roll in edit.rolls {
                if roll.side == .a {
                    planned[k - 1].rolls.append(placed(roll, by: delta, on: a))
                    outgoingRolls.append(placed(roll, by: delta, on: a))
                } else {
                    incoming.rolls.append(roll.shifted(by: delta))
                }
            }
            incoming.incoming = (incoming.envelopes, incoming.rolls)
            let settled = map.hasGlide ? offset + nudge + map.rampEnd / sr : end
            planned.append(incoming)
            transitions.append(.init(from: k - 1, to: k, plan: plan, edit: edit, isEdited: isEdited, start: start,
                                     end: end, settled: settled, barSeconds: blendBar, delta: delta,
                                     entryRange: entryRange, nudge: nudge, grooveLock: align.lock, grooveLags: align.lags,
                                     drumsLayered: align.grooves, drumsLinger: align.groovesAfter, hatsLayered: hats,
                                     vocalOut: vocalOut.map { start + $0 * blendBar },
                                     vocalIn: vocalIn.map { start + $0 * blendBar }, payoff: payoff, dropAt: dropAt,
                                     vocalInKind: vocalInKind, vocalOutKind: vocalOutKind,
                                     skippedBars: skippedBars,
                                     melodiesClash: keysClash, room: room, loopBars: loop,
                                     made: .init(key: buildKey, outgoing: outgoing, outgoingRolls: outgoingRolls)))
            shifts.append(edit.semitones)
        }

        // A blend placed for B's drums building in under A's that then
        // don't (the two grooves don't sit on the audio as it plays) is a
        // blend placed for something else: both songs were to be heard
        // where now one is. Those pairs are planned again as what they
        // are, and the rest of the set is taken over as built.
        // So is one placed for two melodies layering that the audio says
        // clash (how much notes grate reads a little differently there).
        if !broken.isSubset(of: unlocked) || !clashing.isSubset(of: clashed) || !locking.isSubset(of: locked) {
            return try await build(tracks, edits: edits, reuse: renditions,
                                   previous: SetMix(tracks: planned, transitions: transitions, length: 0,
                                                    learned: .init(unlocked: unlocked, clashed: clashed, locked: locked)),
                                   exits: exits,
                                   unlocked: unlocked.union(broken), clashed: clashed.union(clashing),
                                   locked: locked.union(locking), processor: processor, progress: progress)
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
            fadeOut(&env[LaneParameter.volume.rawValue], from: fadeStart, to: end)
            planned[planned.count - 1].envelopes[stem] = env
        }
        return SetMix(tracks: planned, transitions: transitions, length: end + 1,
                      learned: .init(unlocked: unlocked, clashed: clashed, locked: locked))
    }

    /// Fades a stem's volume to nothing by `end`, from `start` or from
    /// where its own automation is done, whichever is later, and from the
    /// level it has there. A short last song is still on its way in where
    /// its final bars begin (its vocal not yet let in): a fade starting
    /// there at full level put that point before the ones holding the stem
    /// back, which opened it from the song's first bar, over the song
    /// before.
    static func fadeOut(_ volume: inout Envelope, from start: Double, to end: Double) {
        let from = max(start, (volume.points.last?.time ?? -.infinity) + 0.002)
        guard from < end else { return }
        volume.insert(AutomationPoint(time: from, value: volume.value(at: from, default: 1), curve: .logarithmic))
        volume.insert(AutomationPoint(time: end, value: 0))
    }

    /// A roll of the outgoing track's, moved from the editor's clock to the
    /// set's. Past a jump the stems sound further on than set time says;
    /// the roll's loop has to be found there too.
    private static func placed(_ roll: Roll, by delta: Double, on track: SetMix.Track) -> Roll {
        var shifted = roll.shifted(by: delta)
        if let jump = track.skip, let at = track.skipAt, shifted.start >= at { shifted.anchor += jump.to - jump.from }
        return shifted
    }

    /// `stems` (drums, bass line, melody) as they sound when they loop from
    /// master `from` on, repeating the `length` seconds that start `back`
    /// seconds before it, up to master `until`: held in memory, frame 0 at
    /// master `from - back`. For measuring what will play; the mix itself
    /// loops the stems in place (see `Roll.seamless`).
    /// - Parameter offset: master time of the stems' own frame 0.
    private static func looped(_ stems: [StemKind: StemAudio], offset: Double, from: Double, back: Double,
                               length: Double, until: Double) -> [StemKind: StemAudio] {
        let sr = AudioIO.sampleRate
        let source = Int(((from - back - offset) * sr).rounded()), lead = Int((back * sr).rounded())
        let period = max(1, Int((length * sr).rounded())), count = lead + max(0, Int((until - from) * sr))
        var out = stems
        for stem in [StemKind.drums, .bass, .other] {
            guard let audio = stems[stem] else { continue }
            func copy(_ channel: MappedChannel) -> MappedChannel {
                MappedChannel(samples: (0..<count).map { i in
                    let j = source + (i < lead ? i : (i - lead) % period)
                    return j >= 0 && j < channel.count ? channel.pointer[j] : 0
                })
            }
            out[stem] = StemAudio(left: copy(audio.left), right: copy(audio.right))
        }
        return out
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
        // (Called off with the build: a build started over this one, after
        // an edit or a song brought in now, doesn't wait behind renditions
        // nobody will hear.)
        let ticket = TrackProcessor.Ticket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                processor.match(loaded, plan: plan, ticket: ticket) { continuation.resume(with: $0) }
            }
        } onCancel: {
            ticket.cancel()
        }
    }
}
