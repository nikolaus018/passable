import Accelerate

struct TrackAnalysis: Codable, Equatable {
    var grid: BeatGrid
    var key: MusicalKey
    var duration: Double
    /// Optional so analyses cached before it existed still decode; the
    /// loader fills it in.
    var structure: TrackStructure?
    /// Analyses older than `currentVersion` are redone on load.
    var version: Int?
    /// How the song's tempo was last checked for steadiness (see
    /// `Steadiness`); analyses checked another way, or not at all, are
    /// checked on load.
    var tempoCheck: Int?
    static let tempoCheck = 5

    static let currentVersion = 6

    /// The song with its bars counted another way (see `Metre`).
    func counted(_ metre: Metre) -> TrackAnalysis {
        guard !metre.isOwn else { return self }
        var counted = self
        counted.grid = grid.counted(metre)
        counted.structure = structure?.counted(metre, grid: counted.grid)
        return counted
    }
}

enum TrackAnalyzer {
    /// Analyses a track from its stems, which beats analysing the mix: the
    /// drum stem gives a clean rhythm signal for the beat grid, and bass +
    /// melody give a key estimate that vocals and hi-hats can't skew.
    static func analyze(stems: [StemKind: StemAudio], tracker: BeatTracker? = BeatTracker.shared) -> TrackAnalysis {
        let sr = AudioIO.sampleRate
        let drums = stems[.drums].map { $0.copyStereo().mono() } ?? []
        let harmony = sum(of: [stems[.bass], stems[.other]].compactMap { $0 })
        let duration = Double(stems.values.map(\.count).max() ?? 0) / sr
        // A drumless track (ambient, a cappella intro) has no rhythm stem to
        // speak of; fall back to the harmonic content.
        let rhythm = rms(drums) > 1e-3 ? drums : sum(of: Array(stems.values))
        let layers = [StemKind.drums, .bass, .other].compactMap { stems[$0]?.copyStereo().mono() }
        // The beat as a trained tracker hears it in the whole song (the
        // stems add up to the mix it was trained on).
        let heard = try? tracker?.track(sum(of: Array(stems.values)))
        var grid = TempoEstimator.estimate(rhythm: rhythm, harmony: harmony, layers: layers, heard: heard, sampleRate: sr)
        if let heard { grid = bars(of: grid, heard: heard, duration: duration, stems: stems) }
        let key = KeyDetector.detect(samples: harmony, sampleRate: sr)
        return TrackAnalysis(grid: grid, key: key, duration: duration,
                             structure: TrackStructure.measure(stems: stems, grid: grid),
                             version: TrackAnalysis.currentVersion, tempoCheck: heard != nil ? TrackAnalysis.tempoCheck : nil)
    }

    /// `analysis` with its tempo checked for steadiness, for one made
    /// before that was looked at: a song found not to keep its grid gets
    /// its bars one by one, and its structure measured on them.
    static func checkingTempo(_ analysis: TrackAnalysis, stems: [StemKind: StemAudio]) -> TrackAnalysis {
        guard analysis.tempoCheck != TrackAnalysis.tempoCheck, let tracker = BeatTracker.shared,
              let heard = try? tracker.track(sum(of: Array(stems.values))) else { return analysis }
        var checked = analysis
        checked.tempoCheck = TrackAnalysis.tempoCheck
        var grid = analysis.grid
        (grid.downbeats, grid.wanders, grid.doubtful) = (nil, nil, nil)
        checked.grid = bars(of: grid, heard: heard, duration: analysis.duration, stems: stems)
        // (Its bars have changed: its own now, or the grid's again.)
        if checked.grid.downbeats != analysis.grid.downbeats {
            let old = analysis.structure
            checked.structure = TrackStructure.measure(stems: stems, grid: checked.grid)
            checked.structure?.setLines(old?.vocalLines, tried: old?.lyricsTried, grid: checked.grid)
        }
        return checked
    }

    /// `grid` with its bars one by one where they aren't all four beats of
    /// one tempo: a drummer's song (`Steadiness.downbeats`), or a steady
    /// one with an odd bar in it (`Steadiness.oddBars`).
    private static func bars(of grid: BeatGrid, heard: BeatTracker.Beats, duration: Double,
                             stems: [StemKind: StemAudio]) -> BeatGrid {
        var grid = grid
        if let own = Steadiness.downbeats(grid: grid, heard: heard, duration: duration,
                                          attacks: stems[.drums].flatMap(BeatAlign.attacks(of:))) {
            (grid.downbeats, grid.wanders, grid.firstDownbeat) = (own, true, own[0])
            return grid
        }
        // How much the harmony (melody and bass line) changes on a beat:
        // the two beats from it against the two before (one beat is too
        // short to tell notes apart), worked out only where asked.
        let harmony = [stems[.other], stems[.bass]].compactMap { $0 }
        let sr = AudioIO.sampleRate
        var known: [Int: [Float]?] = [:]
        func notes(_ i: Int) -> [Float]? {
            if let done = known[i] { return done }
            let from = Int(grid.beat(i) * sr), to = Int(grid.beat(i + 2) * sr)
            var found: [Float]?
            if from >= 0, let count = harmony.map(\.count).min(), to <= count, to > from {
                var mono = [Float](repeating: 0, count: to - from)
                for stem in harmony {
                    for channel in [stem.left, stem.right] {
                        vDSP_vadd(mono, 1, channel.pointer + from, 1, &mono, 1, vDSP_Length(mono.count))
                    }
                }
                if rms(mono) > 2e-3 {
                    let chroma = KeyDetector.computeChroma(samples: mono, sampleRate: sr).map(Float.init)
                    let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
                    if norm > 0 { found = chroma.map { $0 / norm } }
                }
            }
            known[i] = .some(found)
            return found
        }
        let counted = Steadiness.bars(grid: grid, heard: heard, duration: duration, turns: { i in
            guard let a = notes(i - 2), let b = notes(i) else { return nil }
            return 1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        })
        if let odd = counted.downbeats { (grid.downbeats, grid.wanders) = (odd, false) }
        grid.doubtful = counted.doubtful.isEmpty ? nil : counted.doubtful
        return grid
    }

    private static func sum(of stems: [StemAudio]) -> [Float] {
        let n = stems.map(\.count).max() ?? 0
        var out = [Float](repeating: 0, count: n)
        for stem in stems {
            let m = stem.count
            vDSP_vadd(out, 1, stem.left.pointer, 1, &out, 1, vDSP_Length(m))
            vDSP_vadd(out, 1, stem.right.pointer, 1, &out, 1, vDSP_Length(m))
        }
        var half: Float = 0.5
        vDSP_vsmul(out, 1, &half, &out, 1, vDSP_Length(n))
        return out
    }

    private static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(x, 1, &r, vDSP_Length(x.count))
        return r
    }
}
